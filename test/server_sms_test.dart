import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osmsgateway/src/classes/sms_return.dart';
import 'package:osmsgateway/src/providers/log_provider.dart';
import 'package:osmsgateway/src/queue/message_store.dart';
import 'package:osmsgateway/src/queue/sms_queue.dart';
import 'package:osmsgateway/src/server/server.dart';
import 'package:osmsgateway/src/sms/sms_sender.dart';

import 'fake_sms_sender.dart';

class Response {
  final int status;
  final Map<String, dynamic> json;
  Response(this.status, this.json);
}

void main() {
  late FakeSmsSender sender;
  late SmsQueue queue;
  late Server server;
  late LogProvider log;
  late HttpClient client;

  setUp(() async {
    sender = FakeSmsSender();
    queue = SmsQueue(sender: sender, store: MessageStore.memory())
      ..sendInterval = Duration.zero;
    log = LogProvider();
    server = Server(queue: queue)..addLogger(log);
    server.timeCounter = 8; // 400 ms
    server.waitByDefault = true; // estas pruebas ejercitan el modo con espera
    await server.start(
        port: 0, internetAddress: InternetAddress.loopbackIPv4, secure: false);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await queue.dispose();
  });

  Future<Response> request(String method, String path,
      [Map<String, String> query = const {}]) async {
    final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.httpServer.port,
        path: path,
        queryParameters: query.isEmpty ? null : query);
    final req = await client.openUrl(method, uri);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return Response(res.statusCode, jsonDecode(body) as Map<String, dynamic>);
  }

  const query = {'phone': '+595981000000', 'message': 'hola'};

  test('SENT sin informe de entrega responde 200/SENT_BY_MODEM, no entregado',
      () async {
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 200);
    expect(r.json['status'], 200);
    expect(r.json['state'], 'SENT_BY_MODEM');
    expect(r.json['state'], isNot('DELIVERED_CONFIRMED'));
    expect(r.json['deliveredAt'], isNull);
    expect(sender.sent.single['to'], '+595981000000');
    expect(sender.sent.single['message'], 'hola');
    expect(log.getLog(), isNot(contains('Entrega confirmada')));
  });

  test('la respuesta incluye cabeceras CORS y JSON, sin errores internos',
      () async {
    final uri = Uri.parse(
        'http://127.0.0.1:${server.httpServer.port}/v1/sms/send/?phone=%2B595981000000&message=a');
    final res = await (await client.getUrl(uri)).close();
    await res.drain();
    expect(res.headers.value('access-control-allow-origin'), '*');
    expect(res.headers.contentType?.mimeType, 'application/json');
  });

  test('POST /v1/sms/ se comporta igual que el GET', () async {
    final r = await request('POST', '/v1/sms/', query);
    expect(r.status, 200);
    expect(r.json['state'], 'SENT_BY_MODEM');
  });

  test('la entrega confirmada tardía solo se registra en el log', () async {
    sender.late = [SmsEventType.delivered];
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.json['state'], 'SENT_BY_MODEM');
    expect(log.getLog(), isNot(contains('Entrega confirmada')));
    await Future.delayed(const Duration(milliseconds: 500));
    expect(log.getLog(), contains('Entrega confirmada por la operadora'));
    final st = await request('GET', '/v1/sms/${r.json['id']}');
    expect(st.json['state'], 'DELIVERED_CONFIRMED');
    expect(st.json['deliveredAt'], isNotNull);
  });

  test('si llega DELIVERED antes que nada, se informa DELIVERED_CONFIRMED',
      () async {
    sender.script = [SmsEventType.accepted, SmsEventType.delivered];
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 200);
    expect(r.json['state'], 'DELIVERED_CONFIRMED');
  });

  test('fallo de envío responde 500/FAILED', () async {
    sender.script = [SmsEventType.accepted, SmsEventType.failed];
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 500);
    expect(r.json['state'], 'FAILED');
  });

  test('sin confirmación a tiempo responde 202/ACCEPTED_BY_ANDROID, no 500',
      () async {
    sender.script = [SmsEventType.accepted];
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 202);
    expect(r.json['state'], 'ACCEPTED_BY_ANDROID');
    expect(log.getLog(), contains('Sin confirmación'));
  });

  test('si Android rechaza la solicitud responde 500 con el código', () async {
    sender.rejectWith = const SmsSendException('INVALID_ARGUMENT', 'inválido');
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 500);
    expect(r.json['state'], 'FAILED');
    expect(r.json['error'], 'INVALID_ARGUMENT');
  });

  test('dispositivo sin capacidad de SMS responde 500 y no envía', () async {
    sender.capable = false;
    final r = await request('GET', '/v1/sms/send/', query);
    expect(r.status, 500);
    expect(r.json['error'], 'SMS_NOT_SUPPORTED');
    expect(sender.sent, isEmpty);
  });

  test('cada envío distinto recibe un id distinto', () async {
    final a = await request('GET', '/v1/sms/send/', query);
    final b = await request(
        'GET', '/v1/sms/send/', {...query, 'message': 'otro texto'});
    expect(a.json['id'], isNot(b.json['id']));
  });

  test('puerto ocupado: start lanza el error y no cierra el proceso',
      () async {
    final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final other = Server(queue: queue);
    await expectLater(
        other.start(
            port: busy.port,
            internetAddress: InternetAddress.loopbackIPv4,
            secure: false),
        throwsA(isA<SocketException>()));
    await busy.close();
  });

  test('SmsReturn serializa a JSON sin depender de ningún plugin', () {
    final sms = SmsReturn(id: 1, address: '+595981000000', body: 'hola');
    final map = jsonDecode(sms.toRawJson()) as Map<String, dynamic>;
    expect(map['id'], 1);
    expect(map['address'], '+595981000000');
    expect(map['body'], 'hola');
    expect(map['threadId'], isNull);
  });
}
