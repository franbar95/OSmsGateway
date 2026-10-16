import 'dart:convert';
import 'dart:io';

abstract class SimpleHttpServer {
  static const GET = 'GET';
  static const POST = 'POST';
  static const PUT = 'PUT';
  static const DELETE = 'DELETE';
  static const DEFAULT = '*';

  late HttpServer httpServer;
  InternetAddress internetAddress = InternetAddress.anyIPv4;
  int port = 18080;
  String _baseDir = '/';

  Map<String, Map<String, Function(HttpRequest)>> handlersMap = {
    DEFAULT: <String, Function(HttpRequest)>{},
    GET: <String, Function(HttpRequest)>{},
    POST: <String, Function(HttpRequest)>{},
    PUT: <String, Function(HttpRequest)>{},
    DELETE: <String, Function(HttpRequest)>{},
  };
  SimpleHttpServer({int? port, InternetAddress? internetAddress}) {
    this.port = port ?? this.port;
    this.internetAddress = internetAddress ?? this.internetAddress;
    _defaultHandlers();
    addHanderls();
  }

  /// Abre el puerto y empieza a atender peticiones en segundo plano.
  /// Completa cuando el puerto ya está abierto. Si no se puede abrir (puerto
  /// ocupado, certificado inválido...) lanza la excepción al llamador.
  Future<void> start(
      {InternetAddress? internetAddress,
      int? port,
      required bool secure,
      dynamic args}) async {
    this.port = port ?? this.port;
    this.internetAddress = internetAddress ?? this.internetAddress;
    if (secure) {
      SecurityContext context = SecurityContext();
      var chain = Platform.script.resolve(args['serverChain']).toFilePath();
      var key = Platform.script.resolve(args['serverKey']).toFilePath();
      context.useCertificateChain(chain);
      context.usePrivateKey(key);
      httpServer = await HttpServer.bindSecure(
          this.internetAddress, this.port, context);
    } else {
      httpServer = await HttpServer.bind(this.internetAddress, this.port);
    }
    print('Server started at port ${httpServer.port}');
    httpServer.listen(_handleRequest, onError: (e) => print('error $e'));
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      await _processRequest(request);
      await request.response.close();
    } catch (e) {
      print(e);
    }
  }

  Future<void> stop() async {
    try {
      await httpServer.close();
      print('Server stopped');
    } catch (e) {
      print('Error stopping $e');
    }
  }

  Future<void> _processRequest(HttpRequest request) async {
    var type = request.method;
    var route = request.uri.path;
    try {
      await execute(type, route, request);
    } catch (e) {
      print('Error calling processResquest $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // La respuesta ya había empezado a enviarse.
      }
    }
  }

  void add(String type, String route, Function(HttpRequest) function) {
    switch (type) {
      case GET:
        handlersMap[GET]![route] = function;
        break;
      case POST:
        handlersMap[POST]![route] = function;
        break;
      case PUT:
        handlersMap[PUT]![route] = function;
        break;
      case DELETE:
        handlersMap[DELETE]![route] = function;
        break;
      case DEFAULT:
        handlersMap[DEFAULT]![route] = function;
        break;
      default:
        handlersMap[DEFAULT]![route] = function;
        break;
    }
  }

  static const List<String> _methods = [GET, POST, PUT, DELETE];

  /// Métodos con un handler registrado para [route].
  List<String> allowedMethods(String route) =>
      _methods.where((m) => handlersMap[m]!.containsKey(route)).toList();

  Future<void> execute(String type, String route, HttpRequest request) async {
    if (type == 'OPTIONS') {
      await onOptions(request);
      return;
    }
    // Se tolera la ruta sin la barra final (/v1/sms equivale a /v1/sms/).
    final withSlash = route.endsWith('/') ? route : '$route/';
    for (final candidate in [route, withSlash]) {
      if (handlersMap.containsKey(type) &&
          handlersMap[type]!.containsKey(candidate)) {
        await handlersMap[type]![candidate]!.call(request);
        return;
      }
    }
    final allowed = allowedMethods(route).isNotEmpty
        ? allowedMethods(route)
        : allowedMethods(withSlash);
    if (allowed.isNotEmpty) {
      await onMethodNotAllowed(request, allowed);
    } else {
      await onNotFound(request);
    }
  }

  /// Ruta inexistente. Por defecto usa el handler comodín registrado.
  Future<void> onNotFound(HttpRequest request) async {
    await handlersMap['*']!['*']!.call(request);
  }

  /// La ruta existe pero no para este método.
  Future<void> onMethodNotAllowed(
      HttpRequest request, List<String> allowed) async {
    request.response.statusCode = HttpStatus.methodNotAllowed;
    request.response.headers.set(HttpHeaders.allowHeader, allowed.join(', '));
  }

  /// Preflight de CORS.
  Future<void> onOptions(HttpRequest request) async {
    request.response.statusCode = HttpStatus.noContent;
  }

  Future<String> readFile(String path) async {
    try {
      var file = File(path).readAsStringSync(encoding: utf8);
      return file;
    } catch (e) {
      print('Error reading file $path, $e');
    }
    return '';
  }

  Future<void> loadStaticFilesFromDirectory(String dir) async {
    _baseDir = dir;
    var dirLength = dir.length;
    var systemTempDir = Directory.fromUri(Uri.parse(_baseDir));
    var htmlFiles = systemTempDir
        .list(recursive: true, followLinks: false)
        //.where((path) => path.path.endsWith('html'))
        .map((path) => path.path);
    await for (String file in htmlFiles) {
      print('adding ${file.substring(dirLength)}');
      add(GET, '/${file.substring(dirLength)}', (req) async {
        await _readStaticFile(req);
      });
    }
  }

  Future<void> _readStaticFile(HttpRequest request) async {
    var path = '$_baseDir${request.uri.path}';
    var res = await readFile(path);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(res);
    await request.response.close();
  }

  void addHanderls();

  void _defaultHandlers() {
    var defaultRoutes = <String>['/', ''];
    defaultRoutes.forEach((route) {
      add(GET, route, (request) {
        request.response.write('Hello Word');
      });
    });
    add(DEFAULT, '*', (request) {
      request.response.write('Not Found');
    });
  }
}
