import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osmsgateway/src/queue/message_store.dart';
import 'package:osmsgateway/src/queue/sms_queue.dart';
import 'package:osmsgateway/src/server/auth.dart';
import 'package:osmsgateway/src/server/server.dart';

import 'fake_sms_sender.dart';

class Res {
  final int status;
  final HttpHeaders headers;
  final Map<String, dynamic>? json;
  Res(this.status, this.headers, this.json);
}

void main() {
  late FakeSmsSender sender;
  late SmsQueue queue;
  late Server server;
  late HttpClient client;
  const token = 'secret-token-123';

  setUp(() async {
    sender = FakeSmsSender();
    queue = SmsQueue(sender: sender, store: MessageStore.memory())
      ..sendInterval = Duration.zero;
    server = Server(queue: queue);
    server.timeCounter = 8;
    server.waitByDefault = true;
    await server.start(
        port: 0, internetAddress: InternetAddress.loopbackIPv4, secure: false);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await queue.dispose();
  });

  Future<Res> call(String method, String pathAndQuery,
      {Map<String, String> headers = const {},
      String? body,
      String? contentType}) async {
    final uri =
        Uri.parse('http://127.0.0.1:${server.httpServer.port}$pathAndQuery');
    final req = await client.openUrl(method, uri);
    headers.forEach(req.headers.set);
    if (contentType != null) {
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {}
    return Res(res.statusCode, res.headers, json);
  }

  group('validación', () {
    test('teléfono inválido: 400 INVALID_PHONE y no se envía', () async {
      final r = await call('GET', '/v1/sms/send/?phone=abc&message=hola');
      expect(r.status, 400);
      expect(r.json!['error'], 'INVALID_PHONE');
      expect(sender.sent, isEmpty);
    });

    test('sin teléfono: 400', () async {
      final r = await call('GET', '/v1/sms/send/?message=hola');
      expect(r.status, 400);
      expect(r.json!['error'], 'INVALID_PHONE');
    });

    test('mensaje vacío o solo espacios: 400 EMPTY_MESSAGE', () async {
      for (final m in ['', '%20%20']) {
        final r =
            await call('GET', '/v1/sms/send/?phone=0981123456&message=$m');
        expect(r.status, 400);
        expect(r.json!['error'], 'EMPTY_MESSAGE');
      }
      expect(sender.sent, isEmpty);
    });

    test('mensaje demasiado largo: 400 MESSAGE_TOO_LONG', () async {
      final long = 'a' * (Server.maxMessageLength + 1);
      final r =
          await call('GET', '/v1/sms/send/?phone=0981123456&message=$long');
      expect(r.status, 400);
      expect(r.json!['error'], 'MESSAGE_TOO_LONG');
    });

    test('el teléfono nacional se normaliza antes de enviarse', () async {
      final r =
          await call('GET', '/v1/sms/send/?phone=0981123456&message=hola');
      expect(r.status, 200);
      expect(sender.sent.single['to'], '+595981123456');
    });

    test('un + sin codificar en la query no se corrompe', () async {
      final r =
          await call('GET', '/v1/sms/send/?phone=+595981123456&message=hola');
      expect(r.status, 200);
      expect(sender.sent.single['to'], '+595981123456');
    });

    test('el mensaje conserva tildes, ñ, & y # codificados', () async {
      final msg = Uri.encodeQueryComponent('Cañón & más #1 ñandú');
      await call('GET', '/v1/sms/send/?phone=0981123456&message=$msg');
      expect(sender.sent.single['message'], 'Cañón & más #1 ñandú');
    });
  });

  group('POST con cuerpo', () {
    test('JSON', () async {
      final r = await call('POST', '/v1/sms/',
          contentType: 'application/json; charset=utf-8',
          body: jsonEncode({'phone': '0981123456', 'message': 'Hola ñandú'}));
      expect(r.status, 200);
      expect(sender.sent.single['to'], '+595981123456');
      expect(sender.sent.single['message'], 'Hola ñandú');
    });

    test('formulario, con el + codificado', () async {
      final r = await call('POST', '/v1/sms/',
          contentType: 'application/x-www-form-urlencoded',
          body: 'phone=%2B595981123456&message=hola+mundo');
      expect(r.status, 200);
      expect(sender.sent.single['to'], '+595981123456');
      expect(sender.sent.single['message'], 'hola mundo');
    });

    test('JSON inválido: 400 INVALID_BODY', () async {
      final r = await call('POST', '/v1/sms/',
          contentType: 'application/json', body: '{no es json');
      expect(r.status, 400);
      expect(r.json!['error'], 'INVALID_BODY');
    });

    test('JSON con tipos incorrectos: 400 INVALID_BODY', () async {
      final r = await call('POST', '/v1/sms/',
          contentType: 'application/json',
          body: jsonEncode({'phone': 981123456, 'message': 'x'}));
      expect(r.status, 400);
      expect(r.json!['error'], 'INVALID_BODY');
    });

    test('cuerpo demasiado grande: 413 (o corte de conexión) y no se envía',
        () async {
      // El servidor responde sin leer todo el cuerpo y cierra la conexión, así
      // que según el momento el cliente ve el 413 o un corte de conexión.
      try {
        final r = await call('POST', '/v1/sms/',
            contentType: 'application/json',
            body: jsonEncode({
              'phone': '0981123456',
              'message': 'a' * (Server.maxBodyBytes + 10)
            }));
        expect(r.status, 413);
      } on HttpException {
        // aceptable
      } on SocketException {
        // aceptable
      }
      expect(sender.sent, isEmpty);
    });

    test('sin cuerpo sigue funcionando con la query (compatibilidad)',
        () async {
      final r = await call('POST', '/v1/sms/?phone=0981123456&message=hola');
      expect(r.status, 200);
    });
  });

  group('rutas y métodos', () {
    test('/v1/sms sin barra final equivale a /v1/sms/', () async {
      final r = await call('POST', '/v1/sms?phone=0981123456&message=hola');
      expect(r.status, 200);
    });

    test('ruta /v1 inexistente: 404 JSON', () async {
      final r = await call('GET', '/v1/otra/');
      expect(r.status, 404);
      expect(r.json!['error'], 'NOT_FOUND');
    });

    test('método no permitido: 405 con Allow', () async {
      final r = await call('GET', '/v1/sms/?phone=0981123456&message=hola');
      expect(r.status, 405);
      expect(r.headers.value('allow'), 'POST');
      expect(sender.sent, isEmpty);
    });

    test('OPTIONS responde 204 con CORS (preflight)', () async {
      final r = await call('OPTIONS', '/v1/sms/');
      expect(r.status, 204);
      expect(r.headers.value('access-control-allow-headers'),
          contains('Authorization'));
    });
  });

  group('token', () {
    setUp(() {
      server.requireToken = true;
      server.apiToken = token;
    });
    const path = '/v1/sms/send/?phone=0981123456&message=hola';

    test('sin token: 401 y no se envía', () async {
      final r = await call('GET', path);
      expect(r.status, 401);
      expect(r.json!['error'], 'UNAUTHORIZED');
      expect(r.headers.value('www-authenticate'), 'Bearer');
      expect(sender.sent, isEmpty);
    });

    test('token incorrecto: 401', () async {
      final r = await call('GET', path,
          headers: {'Authorization': 'Bearer otro-token'});
      expect(r.status, 401);
      expect(sender.sent, isEmpty);
    });

    test('esquema distinto de Bearer: 401', () async {
      final r =
          await call('GET', path, headers: {'Authorization': 'Basic $token'});
      expect(r.status, 401);
    });

    test('token en la query NO se acepta', () async {
      final r = await call('GET', '$path&token=$token');
      expect(r.status, 401);
    });

    test('Bearer correcto: 200', () async {
      final r =
          await call('GET', path, headers: {'Authorization': 'Bearer $token'});
      expect(r.status, 200);
      expect(sender.sent, hasLength(1));
    });

    test('X-API-Key correcta: 200 en POST', () async {
      final r = await call('POST', '/v1/sms/',
          headers: {'X-API-Key': token},
          contentType: 'application/json',
          body: jsonEncode({'phone': '0981123456', 'message': 'hola'}));
      expect(r.status, 200);
    });

    test('el preflight OPTIONS no exige token', () async {
      final r = await call('OPTIONS', '/v1/sms/');
      expect(r.status, 204);
    });

    test('token vacío en el servidor nunca autoriza', () async {
      server.apiToken = '';
      final r = await call('GET', path, headers: {'X-API-Key': ''});
      expect(r.status, 401);
    });

    test('sin requireToken el servidor acepta sin token (compatibilidad)',
        () async {
      server.requireToken = false;
      final r = await call('GET', path);
      expect(r.status, 200);
    });
  });

  group('cola: modo asíncrono, estado por id e idempotencia', () {
    const send = '/v1/sms/?phone=0981123456&message=hola';

    test('por defecto solo encola: 202 QUEUED con id', () async {
      server.waitByDefault = false;
      final r = await call('POST', send);
      expect(r.status, 202);
      expect(r.json!['state'], 'QUEUED');
      expect(r.json!['id'], isNotEmpty);
      expect(r.json!['duplicate'], false);
      expect(r.json!.containsKey('message'), isFalse,
          reason: 'la respuesta no devuelve el texto');
    });

    test('wait=true en la query espera la salida del SMS', () async {
      server.waitByDefault = false;
      final r = await call('POST', '$send&wait=true');
      expect(r.status, 200);
      expect(r.json!['state'], 'SENT_BY_MODEM');
    });

    test('"wait": true en el JSON espera la salida del SMS', () async {
      server.waitByDefault = false;
      final r = await call('POST', '/v1/sms/',
          contentType: 'application/json',
          body: jsonEncode(
              {'phone': '0981123456', 'message': 'hola', 'wait': true}));
      expect(r.status, 200);
    });

    test('GET /v1/sms/{id} consulta el estado y enmascara el teléfono',
        () async {
      final sent = await call('POST', send);
      final r = await call('GET', '/v1/sms/${sent.json!['id']}');
      expect(r.status, 200);
      expect(r.json!['state'], 'SENT_BY_MODEM');
      expect(r.json!['phone'], '+5959****3456');
      expect(r.json!['phone'], isNot(contains('981123')));
    });

    test('GET /v1/sms/{id} inexistente: 404 MESSAGE_NOT_FOUND', () async {
      final r = await call('GET', '/v1/sms/no-existe');
      expect(r.status, 404);
      expect(r.json!['error'], 'MESSAGE_NOT_FOUND');
    });

    test('Idempotency-Key repetida no envía otro SMS', () async {
      final a = await call('POST', send,
          headers: {'Idempotency-Key': 'pedido-1'});
      final b = await call('POST', send,
          headers: {'Idempotency-Key': 'pedido-1'});
      expect(a.json!['duplicate'], false);
      expect(b.json!['duplicate'], true);
      expect(b.json!['id'], a.json!['id']);
      expect(sender.sent, hasLength(1));
    });

    test('misma Idempotency-Key con otro mensaje: 409', () async {
      await call('POST', send, headers: {'Idempotency-Key': 'pedido-2'});
      final r = await call(
          'POST', '/v1/sms/?phone=0981123456&message=distinto',
          headers: {'Idempotency-Key': 'pedido-2'});
      expect(r.status, 409);
      expect(r.json!['error'], 'IDEMPOTENCY_CONFLICT');
    });

    test('Idempotency-Key inválida: 400', () async {
      final r =
          await call('POST', send, headers: {'Idempotency-Key': 'con espacio'});
      expect(r.status, 400);
      expect(r.json!['error'], 'INVALID_IDEMPOTENCY_KEY');
    });

    test('mismo teléfono y texto repetido sin key: duplicado, un solo SMS',
        () async {
      final a = await call('POST', send);
      final b = await call('POST', send);
      expect(b.json!['duplicate'], true);
      expect(b.json!['id'], a.json!['id']);
      expect(sender.sent, hasLength(1));
    });

    test('límite mensual: 429 MONTHLY_LIMIT y no se envía', () async {
      queue.monthlyLimit = 1;
      await call('POST', send);
      final r = await call(
          'POST', '/v1/sms/?phone=0981123456&message=segundo');
      expect(r.status, 429);
      expect(r.json!['error'], 'MONTHLY_LIMIT');
      expect(sender.sent, hasLength(1));
    });

    test('cola llena: 503 QUEUE_FULL', () async {
      server.waitByDefault = false;
      queue.autoKick = false; // nada se envía, la cola se llena
      queue.maxQueued = 2;
      await call('POST', '/v1/sms/?phone=0981123456&message=a');
      await call('POST', '/v1/sms/?phone=0981123456&message=b');
      final r = await call('POST', '/v1/sms/?phone=0981123456&message=c');
      expect(r.status, 503);
      expect(r.json!['error'], 'QUEUE_FULL');
    });

    test('GET /v1/queue resume el estado de la cola', () async {
      await call('POST', send);
      final r = await call('GET', '/v1/queue/');
      expect(r.status, 200);
      expect(r.json!['monthUsed'], 1);
      expect(r.json!['states'], {'SENT_BY_MODEM': 1});
    });

    test('estado y resumen exigen token cuando está activado', () async {
      final sent = await call('POST', send);
      server.requireToken = true;
      server.apiToken = token;
      expect((await call('GET', '/v1/sms/${sent.json!['id']}')).status, 401);
      expect((await call('GET', '/v1/queue/')).status, 401);
      final ok = await call('GET', '/v1/sms/${sent.json!['id']}',
          headers: {'Authorization': 'Bearer $token'});
      expect(ok.status, 200);
    });
  });

  group('TokenAuth', () {
    test('constantTimeEquals', () {
      expect(TokenAuth.constantTimeEquals('abc', 'abc'), isTrue);
      expect(TokenAuth.constantTimeEquals('abc', 'abd'), isFalse);
      expect(TokenAuth.constantTimeEquals('abc', 'abcd'), isFalse);
      expect(TokenAuth.constantTimeEquals('', ''), isTrue);
    });

    test('generateToken: largo suficiente, único y url-safe', () {
      final a = TokenAuth.generateToken();
      final b = TokenAuth.generateToken();
      expect(a, isNot(b));
      expect(a.length, greaterThanOrEqualTo(43));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    });
  });
}
