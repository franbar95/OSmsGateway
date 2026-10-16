import 'package:flutter_test/flutter_test.dart';
import 'package:osmsgateway/src/sms/phone.dart';

void main() {
  const expected = '+595981123456';

  group('PhoneNumber.normalize (Paraguay)', () {
    test('acepta los formatos habituales de un móvil', () {
      for (final input in [
        '+595981123456',
        '+595 981 123 456',
        '00595981123456',
        '595981123456',
        '0981123456',
        '0981 123 456',
        '(0981) 123-456',
        '981123456',
        '  0981123456  ',
      ]) {
        expect(PhoneNumber.normalize(input), expected, reason: input);
      }
    });

    test('un + sin codificar (llega como espacio) se recupera', () {
      expect(PhoneNumber.normalize(' 595981123456'), expected);
      expect(PhoneNumber.normalize(' 595 981 123 456'), expected);
    });

    test('rechaza entradas inválidas', () {
      for (final input in [
        null,
        '',
        '   ',
        'abc',
        '0981abc456',
        '98112345', // corto
        '09811234567', // largo
        '+59521123456', // fijo paraguayo
        '+5958123456789', // 595 pero no móvil
        '++595981123456',
        '+0123456789',
        '12345',
      ]) {
        expect(PhoneNumber.normalize(input), isNull, reason: '$input');
      }
    });

    test('acepta otros países en formato internacional', () {
      expect(PhoneNumber.normalize('+5491155556666'), '+5491155556666');
      expect(PhoneNumber.normalize('+14155552671'), '+14155552671');
      expect(PhoneNumber.normalize('0014155552671'), '+14155552671');
    });

    test('el código de país por defecto es configurable', () {
      expect(PhoneNumber.normalize('0991234567', countryCode: '598'),
          '+598991234567');
    });
  });
}
