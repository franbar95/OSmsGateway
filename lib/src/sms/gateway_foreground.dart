import 'package:flutter/services.dart';

/// Servicio en primer plano de Android que mantiene vivo el proceso (y con él
/// el servidor y la cola) cuando la pantalla se cierra.
abstract class GatewayForeground {
  /// Inicia el servicio, o actualiza el texto de su notificación.
  Future<void> start(String text);

  Future<void> stop();

  /// Pide el permiso de notificaciones (Android 13+). Sin él el servicio
  /// funciona igual, pero la notificación no se muestra en la barra.
  Future<bool> ensureNotificationPermission();
}

class NativeGatewayForeground implements GatewayForeground {
  static const MethodChannel _channel = MethodChannel('py.osmsgateway/sms');

  @override
  Future<void> start(String text) =>
      _channel.invokeMethod<void>('startForeground', {'text': text});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stopForeground');

  @override
  Future<bool> ensureNotificationPermission() async {
    if (await _channel.invokeMethod<bool>('hasNotificationPermission') ??
        false) {
      return true;
    }
    return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
        false;
  }
}
