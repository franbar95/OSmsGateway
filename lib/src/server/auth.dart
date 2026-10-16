import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Autenticación por token. El token se envía en `Authorization: Bearer <t>`
/// o en la cabecera `X-API-Key`. No se acepta por query string para que no
/// quede en logs ni en el historial del navegador.
class TokenAuth {
  /// Genera un token aleatorio de 256 bits (base64url, sin relleno).
  static String generateToken([Random? random]) {
    final rnd = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Extrae el token presentado por la petición, o `null` si no hay.
  static String? extractToken(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth != null) {
      final match = RegExp(r'^Bearer\s+(\S+)\s*$', caseSensitive: false)
          .firstMatch(auth);
      if (match != null) return match.group(1);
    }
    return request.headers.value('x-api-key');
  }

  /// Compara sin cortocircuitar en el primer byte distinto.
  static bool constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    final n = x.length < y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static bool isAuthorized(HttpRequest request, String expected) {
    if (expected.isEmpty) return false;
    final presented = extractToken(request);
    if (presented == null) return false;
    return constantTimeEquals(presented, expected);
  }
}
