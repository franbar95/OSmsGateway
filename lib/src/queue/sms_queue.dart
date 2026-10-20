import 'dart:async';
import 'dart:math';

import 'package:osmsgateway/src/queue/message_store.dart';
import 'package:osmsgateway/src/queue/sms_message.dart';
import 'package:osmsgateway/src/sms/sms_sender.dart';

/// La cola rechazó el mensaje (no se encoló).
class QueueRejected implements Exception {
  final int httpStatus;
  final String code;
  final String message;
  const QueueRejected(this.httpStatus, this.code, this.message);

  @override
  String toString() => 'QueueRejected($code): $message';
}

class EnqueueResult {
  final SmsMessage message;

  /// true si no se creó un mensaje nuevo: ya existía uno equivalente.
  final bool duplicate;
  const EnqueueResult(this.message, this.duplicate);
}

/// Cola persistente de SMS con un único consumidor.
///
/// Garantías:
/// * Un mensaje se guarda en disco antes de confirmar que se aceptó.
/// * El estado `SENDING` se guarda en disco **antes** de pedir el envío a
///   Android. Si la app muere a partir de ahí, al reiniciar el mensaje queda
///   `UNKNOWN` y no se reenvía: preferimos no enviar a enviar dos veces.
/// * Solo se reintenta automáticamente cuando Android rechazó la solicitud
///   de forma síncrona (nada salió del teléfono).
/// * Un SMS nunca pasa a `DELIVERED_CONFIRMED` sin un informe de la operadora.
class SmsQueue {
  final SmsSender sender;
  final MessageStore store;
  DateTime Function() clock;
  void Function(String)? log;

  /// Pausa mínima entre el inicio de un envío y el siguiente.
  Duration sendInterval = const Duration(seconds: 3);

  /// Máximo de SMS por mes calendario (0 = sin límite).
  int monthlyLimit = 2000;

  /// Máximo de mensajes esperando (en cola o entregándose).
  int maxQueued = 200;

  /// Un mismo teléfono+texto sin `Idempotency-Key` se toma por duplicado
  /// dentro de esta ventana.
  Duration duplicateWindow = const Duration(minutes: 2);

  /// Un mensaje que lleva más tiempo que esto en cola vence sin enviarse.
  Duration queuedMaxAge = const Duration(hours: 24);

  /// Sin evento de salida tras aceptar la solicitud: pasa a `UNKNOWN`.
  Duration acceptedTimeout = const Duration(minutes: 5);

  Duration permissionRetry = const Duration(seconds: 30);
  Duration retryBaseDelay = const Duration(seconds: 30);
  int maxAttempts = 3;

  /// El texto y el número completo se borran pasado este tiempo.
  Duration scrubAfter = const Duration(hours: 24);

  /// Los registros terminados se eliminan pasado este tiempo.
  Duration retention = const Duration(days: 90);

  final StreamController<SmsMessage> _changes = StreamController.broadcast();
  StreamSubscription<SmsEvent>? _eventSub;
  Timer? _timer;
  bool _busy = false;
  bool _recovered = false;
  DateTime? _lastSendAt;
  DateTime? _pausedUntil;
  final Random _random = Random();

  SmsQueue({
    required this.sender,
    required this.store,
    DateTime Function()? clock,
    this.log,
  }) : clock = clock ?? DateTime.now {
    _eventSub = sender.events.listen(_onEvent);
  }

  /// Cambios de estado de cualquier mensaje.
  Stream<SmsMessage> get changes => _changes.stream;

  /// Carga la cola, recupera lo que quedó a medias y empieza a procesar.
  Future<void> start() async {
    await store.load();
    await recover();
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => processOnce());
    kick();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    await stop();
    await _eventSub?.cancel();
    await _changes.close();
  }

  /// Si es false, `enqueue` no dispara el procesamiento (útil para avanzar
  /// paso a paso en pruebas con `processOnce`).
  bool autoKick = true;

  void kick() {
    if (autoKick) processOnce();
  }

  void _say(String text) => log?.call(text);

  /// Tras un reinicio: lo que estaba entregándose o aceptado sin confirmación
  /// de salida pasa a UNKNOWN. No se sabe si salió, y no se reenvía.
  Future<void> recover() async {
    await store.load();
    if (_recovered) return;
    _recovered = true;
    final now = clock();
    final saves = <Future<void>>[];
    for (final m in store.all()) {
      if (m.state == SmsState.sending || m.state == SmsState.accepted) {
        final r = store.mutate(
            m.id,
            (c) => c.copyWith(
                  state: SmsState.unknown,
                  updatedAt: now,
                  finishedAt: now,
                  error: 'INTERRUPTED',
                  detail: 'La aplicación se cerró antes de confirmarse la '
                      'salida; no se sabe si el SMS salió. No se reenvía.',
                ));
        saves.add(r.saved);
        _say('[${m.id}] Estado desconocido tras el reinicio (no se reenvía)');
        if (r.message != null) _changes.add(r.message!);
      }
      final started = m.sendingAt;
      if (started != null &&
          (_lastSendAt == null || started.isAfter(_lastSendAt!))) {
        _lastSendAt = started;
      }
    }
    await Future.wait(saves);
  }

  String _newId() {
    final micros = clock().microsecondsSinceEpoch.toRadixString(36);
    final suffix = _random.nextInt(0x100000).toRadixString(36).padLeft(4, '0');
    return '$micros-$suffix';
  }

  int countThisMonth(DateTime now) {
    final local = now.toLocal();
    return store.all().where((m) {
      final c = m.createdAt.toLocal();
      if (c.year != local.year || c.month != local.month) return false;
      // Lo que falló antes de que Android lo aceptara no gastó SMS.
      return !(m.state == SmsState.failed && m.acceptedAt == null);
    }).length;
  }

  int get pendingCount => store
      .all()
      .where((m) => m.state == SmsState.queued || m.state == SmsState.sending)
      .length;

  /// Guarda el mensaje en la cola (en disco) y devuelve el registro.
  /// Si ya existe uno equivalente devuelve ese, marcado como duplicado.
  Future<EnqueueResult> enqueue({
    required String phone,
    required String message,
    String? idempotencyKey,
  }) async {
    await store.load();
    final now = clock();

    if (idempotencyKey != null) {
      final existing = store.findByKey(idempotencyKey);
      if (existing != null) {
        final sameText = existing.scrubbed || existing.message == message;
        if (existing.phone != phone || !sameText) {
          throw const QueueRejected(
              409,
              'IDEMPOTENCY_CONFLICT',
              'Esa Idempotency-Key ya se usó con otro teléfono o mensaje');
        }
        return EnqueueResult(existing, true);
      }
    } else {
      for (final m in store.all().reversed) {
        if (now.difference(m.createdAt) > duplicateWindow) break;
        if (m.phone == phone &&
            !m.scrubbed &&
            m.message == message &&
            m.state != SmsState.failed) {
          return EnqueueResult(m, true);
        }
      }
    }

    if (pendingCount >= maxQueued) {
      throw QueueRejected(
          503, 'QUEUE_FULL', 'La cola está llena ($maxQueued mensajes)');
    }
    if (monthlyLimit > 0 && countThisMonth(now) >= monthlyLimit) {
      throw QueueRejected(429, 'MONTHLY_LIMIT',
          'Se alcanzó el límite mensual de $monthlyLimit SMS');
    }

    final msg = SmsMessage(
      id: _newId(),
      seq: store.nextSeq(),
      phone: phone,
      message: message,
      idempotencyKey: idempotencyKey,
      state: SmsState.queued,
      createdAt: now,
      updatedAt: now,
    );
    await store.add(msg); // en disco antes de confirmar
    _say('[${msg.id}] En cola para ${msg.maskedPhone}');
    _changes.add(msg);
    kick();
    return EnqueueResult(msg, false);
  }

  SmsMessage? get(String id) => store.get(id);

  /// Espera a que el mensaje cumpla [done] o venza [timeout]. Devuelve el
  /// estado actual (puede no cumplir [done] si venció el plazo).
  Future<SmsMessage?> waitUntil(
      String id, Duration timeout, bool Function(SmsMessage) done) async {
    final current = store.get(id);
    if (current == null || done(current)) return current;
    final completer = Completer<SmsMessage>();
    final sub = changes.where((m) => m.id == id).listen((m) {
      if (!completer.isCompleted && done(m)) completer.complete(m);
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return store.get(id);
    } finally {
      await sub.cancel();
    }
  }

  /// Un paso del consumidor: mantenimiento y, si toca, un envío.
  Future<void> processOnce() async {
    if (_busy) return;
    _busy = true;
    try {
      await store.load();
      await recover();
      final now = clock();
      await _sweep(now);

      final pausedUntil = _pausedUntil;
      if (pausedUntil != null && now.isBefore(pausedUntil)) return;
      final last = _lastSendAt;
      if (last != null && now.difference(last) < sendInterval) return;

      SmsMessage? next;
      for (final m in store.all()) {
        if (m.state == SmsState.queued) {
          next = m;
          break;
        }
      }
      if (next == null) return;

      if (!await sender.isCapable) {
        await _finish(next.id, SmsState.failed,
            error: 'SMS_NOT_SUPPORTED',
            detail: 'Este dispositivo no puede enviar SMS');
        return;
      }
      await _deliverToAndroid(next, now);
    } catch (e) {
      _say('Error interno de la cola: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _deliverToAndroid(SmsMessage m, DateTime now) async {
    // Se guarda SENDING en disco ANTES de pedir el envío a Android.
    final marked = store.mutate(
        m.id,
        (c) => c.copyWith(
            state: SmsState.sending,
            attempts: c.attempts + 1,
            sendingAt: now,
            updatedAt: now));
    await marked.saved;
    _lastSendAt = now;
    if (marked.message != null) _changes.add(marked.message!);

    try {
      final parts =
          await sender.send(id: m.id, to: m.phone, message: m.message);
      final done = store.mutate(m.id, (c) {
        final t = clock();
        if (c.state == SmsState.queued || c.state == SmsState.sending) {
          return c.copyWith(
              state: SmsState.accepted, acceptedAt: t, parts: parts, updatedAt: t);
        }
        // Un evento posterior (p. ej. SENT) llegó antes de este registro:
        // no se retrocede el estado; solo se completan los datos.
        return c.copyWith(
            acceptedAt: c.acceptedAt ?? t, parts: parts, updatedAt: t);
      });
      await done.saved;
      _say('[${m.id}] Android aceptó la solicitud de envío');
      if (done.message != null) _changes.add(done.message!);
    } on SmsSendException catch (e) {
      await _onRejected(m.id, e.code, e.message);
    } catch (e) {
      await _onRejected(m.id, 'SEND_FAILED', '$e');
    }
  }

  /// Android no aceptó la solicitud: nada salió del teléfono.
  Future<void> _onRejected(String id, String code, String detail) async {
    final now = clock();
    final current = store.get(id);
    if (current == null) return;
    if (code == 'NO_PERMISSION') {
      // No cuenta como intento: se espera a que se conceda el permiso.
      _pausedUntil = now.add(permissionRetry);
      await _back(id, attemptsDelta: -1);
      _say('Falta el permiso para enviar SMS; se reintenta más tarde');
      return;
    }
    if (code == 'DUPLICATE_ID') {
      await _finish(id, SmsState.unknown, error: code, detail: detail);
      return;
    }
    if (code == 'SEND_FAILED' && current.attempts < maxAttempts) {
      _pausedUntil = now.add(retryBaseDelay * current.attempts);
      await _back(id);
      _say('[$id] Android rechazó la solicitud ($detail); se reintenta '
          '(intento ${current.attempts}/$maxAttempts)');
      return;
    }
    await _finish(id, SmsState.failed, error: code, detail: detail);
    _say('[$id] Android rechazó la solicitud: $detail');
  }

  Future<void> _back(String id, {int attemptsDelta = 0}) async {
    final r = store.mutate(
        id,
        (c) => c.copyWith(
            state: SmsState.queued,
            attempts: c.attempts + attemptsDelta,
            updatedAt: clock()));
    await r.saved;
    if (r.message != null) _changes.add(r.message!);
  }

  Future<void> _finish(String id, SmsState state,
      {String? error, String? detail}) async {
    final now = clock();
    final r = store.mutate(
        id,
        (c) => c.copyWith(
            state: state,
            updatedAt: now,
            finishedAt: now,
            error: error,
            detail: detail));
    await r.saved;
    if (r.message != null) _changes.add(r.message!);
  }

  Future<void> _sweep(DateTime now) async {
    final saves = <Future<void>>[];
    for (final m in store.all()) {
      if (m.state == SmsState.queued &&
          now.difference(m.createdAt) > queuedMaxAge) {
        final r = store.mutate(
            m.id,
            (c) => c.copyWith(
                state: SmsState.failed,
                updatedAt: now,
                finishedAt: now,
                error: 'EXPIRED',
                detail: 'Venció en la cola sin enviarse'));
        saves.add(r.saved);
        _say('[${m.id}] Venció en la cola sin enviarse');
        if (r.message != null) _changes.add(r.message!);
      } else if (m.state == SmsState.accepted &&
          m.acceptedAt != null &&
          now.difference(m.acceptedAt!) > acceptedTimeout) {
        final r = store.mutate(
            m.id,
            (c) => c.copyWith(
                state: SmsState.unknown,
                updatedAt: now,
                finishedAt: now,
                error: 'NO_SENT_CONFIRMATION',
                detail: 'Android aceptó la solicitud pero no hubo '
                    'confirmación de salida'));
        saves.add(r.saved);
        _say('[${m.id}] Sin confirmación de salida: estado desconocido');
        if (r.message != null) _changes.add(r.message!);
      } else if (!m.scrubbed) {
        final ref = m.state.isFinal
            ? m.finishedAt
            : (m.state == SmsState.sent ? m.sentAt : null);
        if (ref != null && now.difference(ref) > scrubAfter) {
          saves.add(store
              .mutate(
                  m.id,
                  (c) => c.copyWith(
                      message: '', scrubbed: true, updatedAt: c.updatedAt))
              .saved);
        }
      }
    }
    final cutoff = now.subtract(retention);
    // SENT_BY_MODEM no es final (puede llegar un informe de entrega), pero sin
    // informe nunca terminaría: se retiene contando desde que salió.
    saves.add(store.removeWhere((m) {
      final ref = m.state.isFinal
          ? m.finishedAt
          : (m.state == SmsState.sent ? m.sentAt : null);
      return ref != null && ref.isBefore(cutoff);
    }));
    await Future.wait(saves);
  }

  /// Eventos del módem y de la operadora, por id de mensaje.
  void _onEvent(SmsEvent e) {
    switch (e.type) {
      case SmsEventType.accepted:
        return; // lo registra la cola cuando send() termina
      case SmsEventType.sent:
        _transition(e.id, SmsState.sent, 'Enviado por el módem '
            '(sin confirmación de entrega)');
        break;
      case SmsEventType.delivered:
        _transition(e.id, SmsState.delivered,
            'Entrega confirmada por la operadora');
        break;
      case SmsEventType.failed:
        _transition(e.id, SmsState.failed, 'Fallo de envío: '
            '${e.detail ?? e.code}',
            error: 'SEND_FAILED', detail: e.detail);
        break;
      case SmsEventType.deliveryFailed:
        _transition(e.id, SmsState.deliveryFailed,
            'La operadora informó que NO se entregó',
            error: 'DELIVERY_FAILED', detail: 'TP-Status ${e.code}');
        break;
      case SmsEventType.deliveryUnknown:
        final r = store.mutate(e.id, (c) {
          if (c.state.isFinal) return null;
          return c.copyWith(
              detail: 'Informe de entrega no interpretable', updatedAt: clock());
        });
        if (r.message != null) {
          _say('[${e.id}] Informe de entrega no interpretable');
          _changes.add(r.message!);
        }
        break;
    }
  }

  void _transition(String id, SmsState target, String logLine,
      {String? error, String? detail}) {
    final now = clock();
    final r = store.mutate(id, (c) {
      if (!_allowed(c.state, target)) return null;
      return c.copyWith(
        state: target,
        updatedAt: now,
        sentAt: target == SmsState.sent ? now : (target == SmsState.delivered ? c.sentAt ?? now : null),
        deliveredAt: target == SmsState.delivered ? now : null,
        finishedAt: target.isFinal ? now : null,
        error: error,
        detail: detail,
      );
    });
    final updated = r.message;
    if (updated != null && updated.state == target) {
      _say('[$id] $logLine');
      _changes.add(updated);
    }
  }

  /// Los estados solo avanzan. Un estado final no cambia, salvo `UNKNOWN`,
  /// que sí puede resolverse si llega evidencia real (un evento tardío).
  static bool _allowed(SmsState from, SmsState to) {
    if (from == to) return false;
    if (from == SmsState.unknown) {
      return to == SmsState.sent ||
          to == SmsState.delivered ||
          to == SmsState.failed;
    }
    if (from.isFinal) return false;
    if (to == SmsState.deliveryFailed) {
      return from == SmsState.accepted || from == SmsState.sent;
    }
    if (to == SmsState.failed) return true;
    return to.rank > from.rank;
  }
}
