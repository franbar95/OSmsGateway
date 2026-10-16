import 'dart:async';

import 'package:flutter/services.dart';
import 'package:osmsgateway/src/sms/sms_sender.dart';

/// Implementación de [SmsSender] sobre el canal nativo Kotlin (SmsManager).
class NativeSmsSender extends SmsSender {
  static const MethodChannel _channel = MethodChannel('py.osmsgateway/sms');

  final StreamController<SmsEvent> _events = StreamController.broadcast();

  NativeSmsSender() {
    _channel.setMethodCallHandler(_onCall);
  }

  @override
  Stream<SmsEvent> get events => _events.stream;

  @override
  Future<bool> get isCapable async =>
      await _channel.invokeMethod<bool>('isSmsCapable') ?? false;

  /// Carpeta privada de la app, donde se guarda la cola de mensajes.
  Future<String> filesDir() async =>
      (await _channel.invokeMethod<String>('filesDir'))!;

  @override
  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<int> send(
      {required String id, required String to, required String message}) async {
    try {
      final parts = await _channel.invokeMethod<int>(
          'send', {'id': id, 'to': to, 'message': message});
      _events.add(SmsEvent(id, SmsEventType.accepted));
      return parts ?? 1;
    } on PlatformException catch (e) {
      throw SmsSendException(e.code, e.message ?? 'Error desconocido');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'onSmsEvent') return null;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    _events.add(SmsEvent(
      args['id'] as String,
      _parseType(args['event'] as String),
      code: args['code'] as int?,
      detail: args['detail'] as String?,
    ));
    return null;
  }

  static SmsEventType _parseType(String name) {
    switch (name) {
      case 'SENT':
        return SmsEventType.sent;
      case 'DELIVERED':
        return SmsEventType.delivered;
      case 'FAILED':
        return SmsEventType.failed;
      case 'DELIVERY_FAILED':
        return SmsEventType.deliveryFailed;
      default:
        return SmsEventType.deliveryUnknown;
    }
  }
}
