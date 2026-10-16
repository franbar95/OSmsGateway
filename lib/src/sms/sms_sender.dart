import 'package:osmsgateway/src/classes/sms_return.dart';

/// Etapas por las que pasa un SMS. Son hechos distintos y no se deben mezclar:
///
/// * [accepted]: Android aceptó la solicitud de envío. No implica que haya salido.
/// * [sent]: el módem/pila de radio informa que el SMS salió hacia la red.
///   No implica que el destinatario lo haya recibido.
/// * [delivered]: la operadora envió un informe de entrega que dice que el
///   destinatario lo recibió. Es la única confirmación de entrega verificable.
/// * [failed]: el envío falló (Android o el módem lo rechazaron).
/// * [deliveryFailed]: la operadora informó que no pudo entregarlo.
/// * [deliveryUnknown]: llegó un informe de entrega que no pudo interpretarse.
enum SmsEventType {
  accepted,
  sent,
  delivered,
  failed,
  deliveryFailed,
  deliveryUnknown,
}

class SmsEvent {
  final String id;
  final SmsEventType type;
  final int? code;
  final String? detail;

  const SmsEvent(this.id, this.type, {this.code, this.detail});

  @override
  String toString() => 'SmsEvent($id, $type, code: $code, detail: $detail)';
}

/// Error al pedirle a Android que envíe el SMS (la solicitud no fue aceptada).
class SmsSendException implements Exception {
  final String code;
  final String message;

  const SmsSendException(this.code, this.message);

  @override
  String toString() => 'SmsSendException($code): $message';
}

/// Abstracción del envío de SMS. Permite probar el servidor sin enviar SMS reales.
abstract class SmsSender {
  /// Eventos de todos los SMS enviados, identificados por el `id` de [send].
  Stream<SmsEvent> get events;

  Future<bool> get isCapable;

  Future<bool> hasPermission();

  Future<bool> requestPermission();

  /// Pide a Android enviar [message] a [to]. Devuelve el número de partes si
  /// Android aceptó la solicitud; lanza [SmsSendException] si no la aceptó.
  /// El resto del ciclo de vida llega por [events].
  Future<int> send(
      {required String id, required String to, required String message});

  /// Lectura de SMS enviados. Está desactivada: requiere el permiso READ_SMS,
  /// que la aplicación no solicita. Se conserva para una futura reactivación.
  Future<List<SmsReturn>> getSentSms() async {
    throw UnsupportedError('Lectura de SMS desactivada (requiere READ_SMS)');
  }
}
