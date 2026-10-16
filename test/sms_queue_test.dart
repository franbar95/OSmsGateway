import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osmsgateway/src/queue/message_store.dart';
import 'package:osmsgateway/src/queue/sms_message.dart';
import 'package:osmsgateway/src/queue/sms_queue.dart';
import 'package:osmsgateway/src/sms/sms_sender.dart';

import 'fake_sms_sender.dart';

class Clock {
  DateTime now = DateTime(2026, 3, 15, 12);
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late Clock clock;
  late FakeSmsSender sender;
  late Directory dir;
  late List<String> logs;

  SmsQueue makeQueue(
      {FakeSmsSender? s, MessageStore? store, Duration? interval}) {
    final q = SmsQueue(
        sender: s ?? sender,
        store: store ?? MessageStore.memory(),
        clock: () => clock.now,
        log: logs.add);
    q.sendInterval = interval ?? Duration.zero;
    q.autoKick = false;
    return q;
  }

  MessageStore fileStore() =>
      MessageStore.file(() async => '${dir.path}/queue.json');

  setUp(() async {
    clock = Clock();
    sender = FakeSmsSender()..script = []; // los eventos se emiten a mano
    logs = [];
    dir = await Directory.systemTemp.createTemp('osms_queue_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  const phone = '+595981123456';

  /// Emite un evento y deja que el stream lo entregue antes de seguir.
  Future<void> emit(String id, SmsEventType type,
      {int? code, String? detail}) async {
    sender.emit(id, type, code: code, detail: detail);
    await Future<void>.delayed(Duration.zero);
  }

  Future<SmsMessage> enqueueAndSend(SmsQueue q, [String text = 'hola']) async {
    final r = await q.enqueue(phone: phone, message: text);
    await q.processOnce();
    return q.get(r.message.id)!;
  }

  group('estados', () {
    test('camino feliz: cada estado solo con su evidencia', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      expect(m.state, SmsState.accepted);
      expect(m.state, isNot(SmsState.sent));
      expect(m.parts, 1);

      await emit(m.id, SmsEventType.sent);
      m = q.get(m.id)!;
      expect(m.state, SmsState.sent);
      expect(m.sentAt, isNotNull);
      expect(m.deliveredAt, isNull, reason: 'sin informe no hay entrega');

      await emit(m.id, SmsEventType.delivered);
      m = q.get(m.id)!;
      expect(m.state, SmsState.delivered);
      expect(m.deliveredAt, isNotNull);
    });

    test('los estados no retroceden', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.delivered);
      await emit(m.id, SmsEventType.sent); // tardío
      await emit(m.id, SmsEventType.failed); // tardío
      expect(q.get(m.id)!.state, SmsState.delivered);
    });

    test('SENT sin informe de entrega nunca pasa a DELIVERED', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.sent);
      clock.advance(const Duration(days: 3));
      await q.processOnce();
      m = q.get(m.id)!;
      expect(m.state, SmsState.sent);
      expect(m.deliveredAt, isNull);
    });

    test('fallo tras aceptar: FAILED y no se reintenta solo', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.failed, code: 4, detail: 'sin servicio');
      m = q.get(m.id)!;
      expect(m.state, SmsState.failed);
      clock.advance(const Duration(minutes: 10));
      await q.processOnce();
      expect(sender.sent, hasLength(1), reason: 'no debe reenviarse');
    });

    test('la operadora informa que no entregó: DELIVERY_FAILED', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.sent);
      await emit(m.id, SmsEventType.deliveryFailed, code: 0x40);
      expect(q.get(m.id)!.state, SmsState.deliveryFailed);
    });

    test('informe de entrega ilegible no confirma ni niega la entrega',
        () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.sent);
      await emit(m.id, SmsEventType.deliveryUnknown);
      m = q.get(m.id)!;
      expect(m.state, SmsState.sent);
      expect(m.detail, contains('no interpretable'));
    });

    test('aceptado sin confirmación de salida: UNKNOWN; evidencia tardía lo '
        'resuelve', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q);
      clock.advance(const Duration(minutes: 6));
      await q.processOnce();
      expect(q.get(m.id)!.state, SmsState.unknown);
      expect(sender.sent, hasLength(1), reason: 'UNKNOWN no se reenvía');
      await emit(m.id, SmsEventType.sent);
      expect(q.get(m.id)!.state, SmsState.sent);
    });
  });

  group('persistencia y recuperación', () {
    test('el mensaje está en disco antes de confirmar el encolado', () async {
      final q = makeQueue(store: fileStore());
      final r = await q.enqueue(phone: phone, message: 'hola');
      final reloaded = fileStore();
      await reloaded.load();
      expect(reloaded.get(r.message.id)?.state, SmsState.queued);
      expect(reloaded.get(r.message.id)?.message, 'hola');
    });

    test('tras un reinicio los mensajes en cola se envían', () async {
      final q1 = makeQueue(store: fileStore());
      final a = await q1.enqueue(phone: phone, message: 'uno');
      final b = await q1.enqueue(phone: phone, message: 'dos');
      // "Reinicio": nueva cola y nuevo almacén sobre el mismo archivo.
      final sender2 = FakeSmsSender()..script = [];
      final q2 = makeQueue(s: sender2, store: fileStore());
      await q2.store.load();
      await q2.recover();
      await q2.processOnce();
      await q2.processOnce();
      expect(sender2.sent.map((e) => e['id']), [a.message.id, b.message.id]);
    });

    test('caída mientras se entregaba a Android: UNKNOWN y no se reenvía',
        () async {
      final hang = Completer<void>(); // send() nunca termina: la app "muere"
      sender.hold = hang.future;
      final q1 = makeQueue(store: fileStore());
      final r = await q1.enqueue(phone: phone, message: 'hola');
      final other = await q1.enqueue(phone: phone, message: 'otro');
      unawaited(q1.processOnce());
      // Esperar a que SENDING esté en memoria y luego dar tiempo a que se
      // escriba en disco (no se lee el archivo mientras se escribe).
      for (var i = 0; i < 200; i++) {
        if (q1.get(r.message.id)?.state == SmsState.sending) break;
        await Future.delayed(const Duration(milliseconds: 5));
      }
      await Future.delayed(const Duration(milliseconds: 150));
      // "Reinicio" del teléfono.
      final sender2 = FakeSmsSender()..script = [];
      final q2 = makeQueue(s: sender2, store: fileStore());
      await q2.store.load();
      await q2.recover();
      expect(q2.get(r.message.id)!.state, SmsState.unknown);
      expect(q2.get(r.message.id)!.error, 'INTERRUPTED');
      await q2.processOnce();
      expect(sender2.sent.map((e) => e['id']), [other.message.id],
          reason: 'solo se envía el que seguía en cola, nunca el UNKNOWN');
    });

    test('aceptado y luego reinicio sin evento: UNKNOWN', () async {
      final q1 = makeQueue(store: fileStore());
      final m = await enqueueAndSend(q1);
      expect(m.state, SmsState.accepted);
      final sender2 = FakeSmsSender()..script = [];
      final q2 = makeQueue(s: sender2, store: fileStore());
      await q2.store.load();
      await q2.recover();
      expect(q2.get(m.id)!.state, SmsState.unknown);
      await q2.processOnce();
      expect(sender2.sent, isEmpty);
    });

    test('archivo dañado: se aparta y la cola arranca vacía', () async {
      await File('${dir.path}/queue.json').writeAsString('{no es json');
      final store = MessageStore.file(() async => '${dir.path}/queue.json',
          log: logs.add);
      await store.load();
      expect(store.all(), isEmpty);
      expect(logs.join(), contains('dañado'));
      final aside = dir
          .listSync()
          .where((e) => e.path.contains('queue.json.corrupt-'))
          .toList();
      expect(aside, hasLength(1), reason: 'el original se conserva');
    });

    test('el seq sigue creciendo tras reiniciar (orden FIFO estable)',
        () async {
      final q1 = makeQueue(store: fileStore());
      final a = await q1.enqueue(phone: phone, message: 'uno');
      final q2 = makeQueue(store: fileStore());
      await q2.store.load();
      final b = await q2.enqueue(phone: phone, message: 'dos');
      expect(b.message.seq, greaterThan(a.message.seq));
    });
  });

  group('duplicados', () {
    test('misma Idempotency-Key: un solo mensaje y un solo envío', () async {
      final q = makeQueue();
      final a = await q.enqueue(
          phone: phone, message: 'hola', idempotencyKey: 'k1');
      final b = await q.enqueue(
          phone: phone, message: 'hola', idempotencyKey: 'k1');
      expect(a.duplicate, isFalse);
      expect(b.duplicate, isTrue);
      expect(b.message.id, a.message.id);
      await q.processOnce();
      await q.processOnce();
      expect(sender.sent, hasLength(1));
    });

    test('misma key con otro texto o teléfono: 409', () async {
      final q = makeQueue();
      await q.enqueue(phone: phone, message: 'hola', idempotencyKey: 'k1');
      await expectLater(
          q.enqueue(phone: phone, message: 'distinto', idempotencyKey: 'k1'),
          throwsA(isA<QueueRejected>()
              .having((e) => e.httpStatus, 'status', 409)));
      await expectLater(
          q.enqueue(
              phone: '+595982000000', message: 'hola', idempotencyKey: 'k1'),
          throwsA(isA<QueueRejected>()
              .having((e) => e.code, 'code', 'IDEMPOTENCY_CONFLICT')));
    });

    test('peticiones simultáneas con la misma key crean un solo mensaje',
        () async {
      final q = makeQueue();
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          q.enqueue(phone: phone, message: 'hola', idempotencyKey: 'carrera')
      ]);
      expect(results.map((r) => r.message.id).toSet(), hasLength(1));
      expect(results.where((r) => !r.duplicate), hasLength(1));
      expect(q.store.all(), hasLength(1));
    });

    test('sin key: mismo teléfono+texto dentro de la ventana es duplicado',
        () async {
      final q = makeQueue();
      final a = await q.enqueue(phone: phone, message: 'hola');
      clock.advance(const Duration(seconds: 30));
      final b = await q.enqueue(phone: phone, message: 'hola');
      expect(b.duplicate, isTrue);
      expect(b.message.id, a.message.id);
    });

    test('fuera de la ventana o con otro texto no es duplicado', () async {
      final q = makeQueue();
      final a = await q.enqueue(phone: phone, message: 'hola');
      clock.advance(const Duration(minutes: 3));
      final b = await q.enqueue(phone: phone, message: 'hola');
      expect(b.duplicate, isFalse);
      expect(b.message.id, isNot(a.message.id));
      final c = await q.enqueue(phone: phone, message: 'otro texto');
      expect(c.duplicate, isFalse);
    });

    test('un mensaje FAILED no bloquea un reenvío igual', () async {
      sender.rejectWith =
          const SmsSendException('INVALID_ARGUMENT', 'destino inválido');
      final q = makeQueue();
      final a = await enqueueAndSend(q);
      expect(a.state, SmsState.failed);
      sender.rejectWith = null;
      final b = await q.enqueue(phone: phone, message: 'hola');
      expect(b.duplicate, isFalse);
    });
  });

  group('ritmo y límites', () {
    test('un único consumidor, en orden y respetando la pausa', () async {
      final q = makeQueue(interval: const Duration(seconds: 3));
      final a = await q.enqueue(phone: phone, message: 'uno');
      final b = await q.enqueue(phone: phone, message: 'dos');
      final c = await q.enqueue(phone: phone, message: 'tres');
      await q.processOnce();
      expect(sender.sent.map((e) => e['id']), [a.message.id]);
      clock.advance(const Duration(seconds: 1));
      await q.processOnce();
      expect(sender.sent, hasLength(1), reason: 'aún dentro de la pausa');
      clock.advance(const Duration(seconds: 2));
      await q.processOnce();
      expect(sender.sent.map((e) => e['id']), [a.message.id, b.message.id]);
      clock.advance(const Duration(seconds: 3));
      await q.processOnce();
      expect(sender.sent.last['id'], c.message.id);
    });

    test('llamadas simultáneas a processOnce no envían en paralelo', () async {
      final q = makeQueue();
      await q.enqueue(phone: phone, message: 'uno');
      await q.enqueue(phone: phone, message: 'dos');
      await Future.wait([for (var i = 0; i < 6; i++) q.processOnce()]);
      expect(sender.sent, hasLength(1));
    });

    test('tras un reinicio se respeta la pausa desde el último envío',
        () async {
      final q1 = makeQueue(store: fileStore(), interval: const Duration(seconds: 3));
      await enqueueAndSend(q1, 'uno');
      await q1.enqueue(phone: phone, message: 'dos');
      final sender2 = FakeSmsSender()..script = [];
      final q2 = makeQueue(
          s: sender2, store: fileStore(), interval: const Duration(seconds: 3));
      await q2.store.load();
      clock.advance(const Duration(seconds: 1));
      await q2.processOnce();
      expect(sender2.sent, isEmpty);
      clock.advance(const Duration(seconds: 3));
      await q2.processOnce();
      expect(sender2.sent, hasLength(1));
    });

    test('cola llena: 503 QUEUE_FULL', () async {
      final q = makeQueue()..maxQueued = 3;
      for (var i = 0; i < 3; i++) {
        await q.enqueue(phone: phone, message: 'm$i');
      }
      await expectLater(
          q.enqueue(phone: phone, message: 'm3'),
          throwsA(isA<QueueRejected>()
              .having((e) => e.httpStatus, 'status', 503)));
    });

    test('límite mensual: 429 y se reinicia al mes siguiente', () async {
      final q = makeQueue()..monthlyLimit = 2;
      await q.enqueue(phone: phone, message: 'a');
      await q.enqueue(phone: phone, message: 'b');
      await expectLater(
          q.enqueue(phone: phone, message: 'c'),
          throwsA(isA<QueueRejected>()
              .having((e) => e.code, 'code', 'MONTHLY_LIMIT')
              .having((e) => e.httpStatus, 'status', 429)));
      clock.now = DateTime(2026, 4, 2, 9);
      final next = await q.enqueue(phone: phone, message: 'c');
      expect(next.duplicate, isFalse);
    });

    test('lo que falló sin llegar a Android no gasta el límite mensual',
        () async {
      sender.rejectWith = const SmsSendException('INVALID_ARGUMENT', 'x');
      final q = makeQueue()..monthlyLimit = 1;
      final m = await enqueueAndSend(q);
      expect(m.state, SmsState.failed);
      sender.rejectWith = null;
      final again = await q.enqueue(phone: phone, message: 'otra vez');
      expect(again.duplicate, isFalse);
    });

    test('un mensaje que vence en cola no se envía', () async {
      final q = makeQueue();
      final r = await q.enqueue(phone: phone, message: 'viejo');
      clock.advance(const Duration(hours: 25));
      await q.processOnce();
      final m = q.get(r.message.id)!;
      expect(m.state, SmsState.failed);
      expect(m.error, 'EXPIRED');
      expect(sender.sent, isEmpty);
    });
  });

  group('rechazos de Android (nada salió del teléfono)', () {
    test('SEND_FAILED se reintenta con espera y termina en FAILED', () async {
      sender.rejectWith = const SmsSendException('SEND_FAILED', 'radio apagada');
      final q = makeQueue();
      final r = await q.enqueue(phone: phone, message: 'hola');
      await q.processOnce();
      expect(q.get(r.message.id)!.state, SmsState.queued);
      expect(q.get(r.message.id)!.attempts, 1);
      await q.processOnce();
      expect(q.get(r.message.id)!.attempts, 1, reason: 'en pausa');
      clock.advance(const Duration(seconds: 31));
      await q.processOnce();
      expect(q.get(r.message.id)!.attempts, 2);
      clock.advance(const Duration(minutes: 2));
      await q.processOnce();
      final m = q.get(r.message.id)!;
      expect(m.state, SmsState.failed);
      expect(m.attempts, 3);
      expect(m.error, 'SEND_FAILED');
    });

    test('el reintento tiene éxito si el problema se resuelve', () async {
      sender.rejections.add(const SmsSendException('SEND_FAILED', 'temporal'));
      final q = makeQueue();
      final r = await q.enqueue(phone: phone, message: 'hola');
      await q.processOnce();
      clock.advance(const Duration(seconds: 31));
      await q.processOnce();
      expect(q.get(r.message.id)!.state, SmsState.accepted);
      expect(sender.sent, hasLength(1), reason: 'se envió una sola vez');
    });

    test('sin permiso: sigue en cola y no consume intentos', () async {
      sender.rejectWith = const SmsSendException('NO_PERMISSION', 'sin permiso');
      final q = makeQueue();
      final r = await q.enqueue(phone: phone, message: 'hola');
      for (var i = 0; i < 5; i++) {
        await q.processOnce();
        clock.advance(const Duration(seconds: 31));
      }
      final m = q.get(r.message.id)!;
      expect(m.state, SmsState.queued);
      expect(m.attempts, 0);
      sender.rejectWith = null;
      await q.processOnce();
      expect(q.get(r.message.id)!.state, SmsState.accepted);
    });

    test('argumento inválido: FAILED de inmediato, sin reintentos', () async {
      sender.rejectWith = const SmsSendException('INVALID_ARGUMENT', 'x');
      final q = makeQueue();
      final m = await enqueueAndSend(q);
      expect(m.state, SmsState.failed);
      expect(m.attempts, 1);
    });

    test('dispositivo sin SMS: FAILED', () async {
      sender.capable = false;
      final q = makeQueue();
      final m = await enqueueAndSend(q);
      expect(m.state, SmsState.failed);
      expect(m.error, 'SMS_NOT_SUPPORTED');
    });
  });

  group('privacidad y retención', () {
    test('el texto se borra tiempo después de terminar', () async {
      final q = makeQueue();
      var m = await enqueueAndSend(q, 'código 123456');
      await emit(m.id, SmsEventType.sent);
      await emit(m.id, SmsEventType.delivered);
      expect(q.get(m.id)!.message, 'código 123456');
      clock.advance(const Duration(hours: 25));
      await q.processOnce();
      m = q.get(m.id)!;
      expect(m.message, isEmpty);
      expect(m.scrubbed, isTrue);
      expect(m.state, SmsState.delivered);
    });

    test('registros terminados se eliminan pasada la retención', () async {
      final q = makeQueue();
      final m = await enqueueAndSend(q);
      await emit(m.id, SmsEventType.sent);
      await emit(m.id, SmsEventType.delivered);
      clock.advance(const Duration(days: 91));
      await q.processOnce();
      expect(q.get(m.id), isNull);
    });

    test('el teléfono se enmascara en la salida', () {
      expect(SmsMessage.maskPhone('+595981123456'), '+5959****3456');
    });
  });

  group('espera de estado', () {
    test('waitUntil devuelve al cumplirse la condición', () async {
      final q = makeQueue();
      final m = await enqueueAndSend(q);
      final waiting = q.waitUntil(
          m.id, const Duration(seconds: 2), (x) => x.state.hasLeftPhone);
      scheduleMicrotask(() => sender.emit(m.id, SmsEventType.sent));
      expect((await waiting)!.state, SmsState.sent);
    });

    test('waitUntil devuelve el estado actual si vence el plazo', () async {
      final q = makeQueue();
      final m = await enqueueAndSend(q);
      final r = await q.waitUntil(m.id, const Duration(milliseconds: 50),
          (x) => x.state.hasLeftPhone);
      expect(r!.state, SmsState.accepted);
    });
  });
}
