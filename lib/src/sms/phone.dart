/// Normalización de números de teléfono a formato E.164 (+<país><número>).
class PhoneNumber {
  static const String defaultCountryCode = '595'; // Paraguay

  static final RegExp _e164 = RegExp(r'^\+[1-9]\d{7,14}$');
  // Móviles paraguayos: +595 9XX XXXXXX (9 dígitos tras el código de país).
  static final RegExp _paraguayMobile = RegExp(r'^\+5959\d{8}$');
  static final RegExp _digits = RegExp(r'^\d+$');

  /// Devuelve el número en E.164 o `null` si no es válido.
  ///
  /// Acepta, por ejemplo para Paraguay: `+595981123456`, `00595981123456`,
  /// `595981123456`, `0981123456`, `0981 123 456`, `981123456`.
  ///
  /// Un `+` sin codificar en una URL llega al servidor como espacio; por eso un
  /// valor que empieza con espacio seguido de dígitos (que no empiecen con 0)
  /// se interpreta como si empezara con `+`.
  static String? normalize(String? raw,
      {String countryCode = defaultCountryCode}) {
    if (raw == null) return null;
    final hadLeadingSpace = raw.startsWith(' ');
    final s = raw.trim().replaceAll(RegExp(r'[\s\-\.\(\)]'), '');
    if (s.isEmpty) return null;

    String candidate;
    if (s.startsWith('+')) {
      candidate = s;
    } else if (s.startsWith('00')) {
      candidate = '+' + s.substring(2);
    } else if (!_digits.hasMatch(s)) {
      return null;
    } else if (hadLeadingSpace && !s.startsWith('0')) {
      candidate = '+' + s;
    } else if (s.startsWith('0')) {
      candidate = '+$countryCode${s.substring(1)}';
    } else if (s.startsWith(countryCode)) {
      candidate = '+$s';
    } else {
      candidate = '+$countryCode$s';
    }

    if (!_e164.hasMatch(candidate)) return null;
    if (candidate.startsWith('+595') && !_paraguayMobile.hasMatch(candidate)) {
      return null;
    }
    return candidate;
  }
}
