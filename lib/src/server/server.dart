import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:osmsgateway/src/classes/sms_return.dart';
import 'package:osmsgateway/src/providers/log_provider.dart';
import 'package:osmsgateway/src/queue/sms_message.dart';
import 'package:osmsgateway/src/queue/sms_queue.dart';
import 'package:osmsgateway/src/server/auth.dart';
import 'package:osmsgateway/src/server/simple_http_server.dart';
import 'package:osmsgateway/src/sms/phone.dart';
import 'package:flutter/services.dart' show rootBundle;

class Server extends SimpleHttpServer {
  LogProvider? _log;
  bool iniciado = false;
  final SmsQueue queue;

  /// Número de intervalos de 50 ms que se espera la confirmación de salida
  /// cuando la petición pide `wait=true` (misma semántica que el ajuste
  /// "Timeout" original).
  int timeCounter = 200;

  /// Si es true, las peticiones esperan por defecto la confirmación de salida
  /// (comportamiento síncrono de versiones anteriores). Por defecto la
  /// petición solo encola y responde 202; con `wait=true` espera.
  bool waitByDefault = false;

  /// Longitud máxima del mensaje (caracteres) y del cuerpo de la petición.
  static const int maxMessageLength = 1000;
  static const int maxBodyBytes = 16 * 1024;

  /// Si [requireToken] es true, todo `/v1/*` exige el token (Bearer o
  /// X-API-Key). Por defecto está desactivado para no romper integraciones
  /// existentes; la aplicación avisa en el log cuando arranca sin token.
  bool requireToken = false;
  String apiToken = '';

  Server({required this.queue});

  Future<void> iniciar(
      {required int port,
      InternetAddress? internetAddress,
      required bool secure,
      dynamic args}) async {
    timeCounter = args['timeout'];
    requireToken = args['tokenRequired'] == true;
    apiToken = (args['token'] as String?) ?? '';
    if (requireToken && apiToken.isEmpty) {
      iniciado = false;
      _log?.escribirLog('No se inicia: se exige token pero no hay ninguno '
          'configurado (Configuración > Token de acceso)');
      return;
    }
    Map<String, String> mapIps = new Map();
    await NetworkInterface.list(
            includeLoopback: false, type: InternetAddressType.any)
        .then((List<NetworkInterface> interfaces) {
      interfaces.forEach((interface) {
        interface.addresses.forEach((address) {
          if (interface.name.contains('wlan')) {
            mapIps[interface.name] = address.address;
          }
        });
      });
    });
    try {
      await start(
          port: port,
          internetAddress: internetAddress,
          secure: secure,
          args: args);
      iniciado = true;
      mapIps.entries.forEach((element) {
        _log?.escribirLog(
            'Escuchando en ${element.key}: ${element.value}:$port');
      });
      if (!requireToken) {
        _log?.escribirLog('ADVERTENCIA: el servidor NO exige token; cualquier '
            'equipo de la red puede enviar SMS');
      }
    } catch (e) {
      iniciado = false;
      _log?.escribirLog(
          'No se ha podido iniciar el servidor en el puerto $port: $e');
    }
  }

  parar() async {
    _log?.escribirLog('Apagando el servidor');
    await super.stop();
    iniciado = false;
  }

  void _setCors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'POST,GET,OPTIONS')
      ..set('Access-Control-Allow-Headers',
          'Origin, X-Requested-With, Content-Type, Accept, Authorization, X-API-Key')
      ..set('Access-Control-Max-Age', '600');
  }

  void _writeJson(HttpRequest request, int status, Map<String, dynamic> body) {
    _setCors(request.response);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  /// Respuesta de error uniforme: {"status":400,"error":"CODE","message":"..."}.
  void _writeError(HttpRequest request, int status, String code, String message) {
    _writeJson(request, status,
        {'status': status, 'error': code, 'message': message});
  }

  /// true si la petición puede continuar; si no, ya respondió 401.
  bool _authorize(HttpRequest request) {
    if (!requireToken) return true;
    if (TokenAuth.isAuthorized(request, apiToken)) return true;
    _log?.escribirLog('Petición rechazada: token ausente o incorrecto '
        '(${request.connectionInfo?.remoteAddress.address})');
    request.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
    _writeError(request, HttpStatus.unauthorized, 'UNAUTHORIZED',
        'Se requiere un token válido (Authorization: Bearer <token>)');
    return false;
  }

  /// Lee phone/message de la query y, en POST, del cuerpo JSON o de formulario
  /// (el cuerpo tiene prioridad). Lanza [_BadRequest] si el cuerpo es inválido.
  Future<Map<String, String>> _readParameters(HttpRequest request) async {
    final params = Map<String, String>.from(request.uri.queryParameters);
    if (request.method != 'POST') return params;
    final type = request.headers.contentType?.mimeType;
    final isJson = type == 'application/json';
    final isForm = type == 'application/x-www-form-urlencoded';
    if (!isJson && !isForm) return params;
    if (request.contentLength > maxBodyBytes) {
      throw _BadRequest(HttpStatus.requestEntityTooLarge, 'BODY_TOO_LARGE',
          'El cuerpo supera $maxBodyBytes bytes');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        throw _BadRequest(HttpStatus.requestEntityTooLarge, 'BODY_TOO_LARGE',
            'El cuerpo supera $maxBodyBytes bytes');
      }
    }
    try {
      final text = utf8.decode(bytes);
      if (text.trim().isEmpty) return params;
      if (isJson) {
        final decoded = jsonDecode(text);
        if (decoded is! Map) throw FormatException('no es un objeto');
        for (final key in ['phone', 'message', 'idempotency_key']) {
          final v = decoded[key];
          if (v is String) params[key] = v;
          if (v != null && v is! String) {
            throw FormatException('$key debe ser texto');
          }
        }
        final w = decoded['wait'];
        if (w is bool) {
          params['wait'] = w.toString();
        } else if (w is String) {
          params['wait'] = w;
        } else if (w != null) {
          throw FormatException('wait debe ser booleano');
        }
      } else {
        params.addAll(Uri.splitQueryString(text));
      }
    } on FormatException catch (e) {
      throw _BadRequest(HttpStatus.badRequest, 'INVALID_BODY',
          'Cuerpo inválido: ${e.message}');
    }
    return params;
  }

  static bool _parseBool(String? v, bool fallback) {
    switch (v?.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
      default:
        return fallback;
    }
  }

  /// Código HTTP según el estado del mensaje:
  /// 200 = salió del teléfono (no implica entrega), 500 = falló,
  /// 202 = todavía sin confirmar (en cola, en curso o desconocido).
  static int _httpStatusFor(SmsState state) {
    switch (state) {
      case SmsState.sent:
      case SmsState.delivered:
      case SmsState.deliveryFailed:
        return HttpStatus.ok;
      case SmsState.failed:
        return HttpStatus.internalServerError;
      default:
        return HttpStatus.accepted;
    }
  }

  Map<String, dynamic> _messageJson(SmsMessage m, int status,
      {bool? duplicate}) {
    String? iso(DateTime? d) => d?.toUtc().toIso8601String();
    return {
      'status': status,
      'id': m.id,
      'state': m.state.wire,
      'phone': m.maskedPhone,
      'parts': m.parts,
      'attempts': m.attempts,
      if (duplicate != null) 'duplicate': duplicate,
      'createdAt': iso(m.createdAt),
      'acceptedAt': iso(m.acceptedAt),
      'sentAt': iso(m.sentAt),
      'deliveredAt': iso(m.deliveredAt),
      'error': m.error,
      'detail': m.detail,
    };
  }

  Future<void> _sendSMS(HttpRequest request) async {
    if (!_authorize(request)) return;
    final Map<String, String> parameters;
    try {
      parameters = await _readParameters(request);
    } on _BadRequest catch (e) {
      _writeError(request, e.status, e.code, e.message);
      return;
    }
    final number = PhoneNumber.normalize(parameters['phone']);
    if (number == null) {
      _writeError(request, HttpStatus.badRequest, 'INVALID_PHONE',
          'Teléfono inválido; use formato internacional (+595981123456) '
          'o nacional (0981123456)');
      return;
    }
    final message = parameters['message'] ?? '';
    if (message.trim().isEmpty) {
      _writeError(request, HttpStatus.badRequest, 'EMPTY_MESSAGE',
          'El mensaje no puede estar vacío');
      return;
    }
    if (message.length > maxMessageLength) {
      _writeError(request, HttpStatus.badRequest, 'MESSAGE_TOO_LONG',
          'El mensaje supera $maxMessageLength caracteres');
      return;
    }
    final key = request.headers.value('idempotency-key') ??
        parameters['idempotency_key'];
    if (key != null && !RegExp(r'^[\x21-\x7E]{1,128}$').hasMatch(key)) {
      _writeError(request, HttpStatus.badRequest, 'INVALID_IDEMPOTENCY_KEY',
          'La Idempotency-Key debe tener 1-128 caracteres imprimibles sin '
          'espacios');
      return;
    }
    final wait = _parseBool(parameters['wait'], waitByDefault);

    if (!await queue.sender.isCapable) {
      _log?.escribirLog('Este dispositivo no puede enviar SMS');
      _writeError(request, HttpStatus.internalServerError, 'SMS_NOT_SUPPORTED',
          'Este dispositivo no puede enviar SMS');
      return;
    }

    final EnqueueResult result;
    try {
      result = await queue.enqueue(
          phone: number, message: message, idempotencyKey: key);
    } on QueueRejected catch (e) {
      _log?.escribirLog('Mensaje rechazado: ${e.message}');
      _writeError(request, e.httpStatus, e.code, e.message);
      return;
    }
    var m = result.message;
    if (result.duplicate) {
      _log?.escribirLog('[${m.id}] Petición duplicada: se devuelve el '
          'mensaje existente, no se envía otro');
    }

    bool settled(SmsMessage x) => x.state.hasLeftPhone || x.state.isFinal;
    if (wait && !settled(m)) {
      m = await queue.waitUntil(
              m.id, Duration(milliseconds: timeCounter * 50), settled) ??
          m;
      if (!settled(m)) {
        // Sin confirmación a tiempo: se responde 202 (no 500) para que el
        // cliente no reintente a ciegas y duplique el mensaje.
        _log?.escribirLog('[${m.id}] Sin confirmación de salida a tiempo');
      }
    }
    _writeJson(request, _httpStatusFor(m.state),
        _messageJson(m, _httpStatusFor(m.state), duplicate: result.duplicate));
  }

  Future<void> _messageStatus(HttpRequest request, String id) async {
    if (!_authorize(request)) return;
    final m = queue.get(id);
    if (m == null) {
      _writeError(request, HttpStatus.notFound, 'MESSAGE_NOT_FOUND',
          'No existe un mensaje con id $id');
      return;
    }
    _writeJson(request, HttpStatus.ok, _messageJson(m, HttpStatus.ok));
  }

  Future<void> _queueSummary(HttpRequest request) async {
    if (!_authorize(request)) return;
    final all = queue.store.all();
    final counts = <String, int>{};
    for (final m in all) {
      counts[m.state.wire] = (counts[m.state.wire] ?? 0) + 1;
    }
    _writeJson(request, HttpStatus.ok, {
      'status': HttpStatus.ok,
      'pending': queue.pendingCount,
      'states': counts,
      'monthUsed': queue.countThisMonth(queue.clock()),
      'monthlyLimit': queue.monthlyLimit,
    });
  }

  /// Lectura de SMS enviados. Desactivada (sin ruta): requiere READ_SMS.
  Future<void> _readSMS(HttpRequest request) async {
    // var route = request.uri.path;
    int desde = 0;
    int coje = 100;
    List<SmsReturn> listSms = await queue.sender.getSentSms();
    List<SmsReturn> listReturn = listSms.skip(desde).take(coje).toList();
    _writeJson(request, HttpStatus.accepted, {'data': listReturn});
  }

  @override
  Future<void> onNotFound(HttpRequest request) async {
    final match = RegExp(r'^/v1/sms/([A-Za-z0-9_-]{1,64})/?$')
        .firstMatch(request.uri.path);
    if (match != null && request.method == 'GET') {
      await _messageStatus(request, match.group(1)!);
      return;
    }
    if (request.uri.path.startsWith('/v1/')) {
      _writeError(request, HttpStatus.notFound, 'NOT_FOUND',
          'Ruta inexistente: ${request.uri.path}');
      return;
    }
    String body = await _readStaticFile('error');
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.html
      ..write(body);
  }

  @override
  Future<void> onMethodNotAllowed(
      HttpRequest request, List<String> allowed) async {
    request.response.headers.set(HttpHeaders.allowHeader, allowed.join(', '));
    _writeError(request, HttpStatus.methodNotAllowed, 'METHOD_NOT_ALLOWED',
        'Método ${request.method} no permitido; use: ${allowed.join(', ')}');
  }

  @override
  Future<void> onOptions(HttpRequest request) async {
    _setCors(request.response);
    request.response.statusCode = HttpStatus.noContent;
  }

  void addLogger(LogProvider log) {
    _log = log;
    queue.log = log.escribirLog;
  }

  Future<String> _readStaticFile(String route) async {
    return await rootBundle.loadString('lib/src/static/$route.html');
  }

  @override
  void addHanderls() {
    add('GET', '/', (HttpRequest request) async {
      String body = await _readStaticFile('index');
      request.response
        ..headers.contentType = ContentType.html
        ..write(body);
    });
    add('*', '*', (HttpRequest request) async {
      String body = await _readStaticFile('error');
      request.response
        ..headers.contentType = ContentType.html
        ..write(body);
    });
    add('GET', '/v1/sms/send/', (HttpRequest request) async {
      await _sendSMS(request);
    });
    add('POST', '/v1/sms/', (HttpRequest request) async {
      await _sendSMS(request);
    });
    add('GET', '/v1/queue/', (HttpRequest request) async {
      await _queueSummary(request);
    });
    // add('GET', '/v1/sms/', (HttpRequest request) async {
    //   await _readSMS(request);
    // });
    // add('GET', '/v1/sms/:inicio', (HttpRequest request) async {
    //   await _readSMS(request);
    // });
    // add('GET', '/v1/sms/:inicio/:fin', (HttpRequest request) async {
    //   await _readSMS(request);
    // });
  }
}

class _BadRequest implements Exception {
  final int status;
  final String code;
  final String message;
  _BadRequest(this.status, this.code, this.message);
}
