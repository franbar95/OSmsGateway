import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osmsgateway/src/sms/gateway_foreground.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('py.osmsgateway/sms');
  final calls = <MethodCall>[];
  var hasPermission = false;
  var grantsPermission = true;

  setUp(() {
    calls.clear();
    hasPermission = false;
    grantsPermission = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'hasNotificationPermission':
          return hasPermission;
        case 'requestNotificationPermission':
          return grantsPermission;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start envía el texto de la notificación', () async {
    await NativeGatewayForeground().start('Servidor activo en el puerto 8080');
    expect(calls.single.method, 'startForeground');
    expect(calls.single.arguments, {'text': 'Servidor activo en el puerto 8080'});
  });

  test('stop llama a stopForeground', () async {
    await NativeGatewayForeground().stop();
    expect(calls.single.method, 'stopForeground');
  });

  test('si ya tiene el permiso de notificaciones no lo vuelve a pedir',
      () async {
    hasPermission = true;
    expect(await NativeGatewayForeground().ensureNotificationPermission(),
        isTrue);
    expect(calls.map((c) => c.method), ['hasNotificationPermission']);
  });

  test('si no lo tiene lo pide y devuelve la respuesta del usuario', () async {
    grantsPermission = false;
    expect(await NativeGatewayForeground().ensureNotificationPermission(),
        isFalse);
    expect(calls.map((c) => c.method),
        ['hasNotificationPermission', 'requestNotificationPermission']);
  });
}
