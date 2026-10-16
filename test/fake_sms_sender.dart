import 'dart:async';

import 'package:osmsgateway/src/sms/sms_sender.dart';

/// Sender falso: nunca toca la red celular. Cada prueba decide qué eventos emite.
class FakeSmsSender extends SmsSender {
  final StreamController<SmsEvent> _controller = StreamController.broadcast();
  bool capable = true;

  /// Si no es null, `send` siempre lanza esto.
  SmsSendException? rejectWith;

  /// Rechazos de un solo uso: cada llamada a `send` consume el primero.
  final List<SmsSendException> rejections = [];

  /// Si no es null, `send` se queda esperando (simula un cuelgue/cierre).
  Future<void>? hold;

  int parts = 1;
  final List<Map<String, String>> sent = [];

  /// Eventos que se emiten tras aceptar la solicitud (en este orden).
  List<SmsEventType> script = [SmsEventType.accepted, SmsEventType.sent];

  /// Emite estos eventos con retraso, después de responder (p. ej. entrega).
  List<SmsEventType> late = [];

  @override
  Stream<SmsEvent> get events => _controller.stream;

  /// Emite un evento a mano (para pruebas paso a paso).
  void emit(String id, SmsEventType type, {int? code, String? detail}) =>
      _controller.add(SmsEvent(id, type, code: code, detail: detail));

  @override
  Future<bool> get isCapable async => capable;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<int> send(
      {required String id, required String to, required String message}) async {
    if (rejectWith != null) throw rejectWith!;
    if (rejections.isNotEmpty) throw rejections.removeAt(0);
    sent.add({'id': id, 'to': to, 'message': message});
    if (hold != null) await hold;
    scheduleMicrotask(() {
      for (final type in script) {
        _controller.add(SmsEvent(id, type));
      }
    });
    if (late.isNotEmpty) {
      Timer(const Duration(milliseconds: 300), () {
        for (final type in late) {
          _controller.add(SmsEvent(id, type));
        }
      });
    }
    return parts;
  }
}
