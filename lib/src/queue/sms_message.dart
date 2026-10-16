/// Estados de un SMS. Cada uno es un hecho distinto y verificable:
///
/// * [queued]: guardado en la cola, todavía no se pidió a Android que lo envíe.
/// * [sending]: se está entregando a Android; si la app muere en este estado
///   no se sabe si Android llegó a aceptarlo.
/// * [accepted]: Android aceptó la solicitud. No implica que haya salido.
/// * [sent]: el módem informó que el SMS salió. No implica entrega.
/// * [delivered]: la operadora confirmó la entrega (informe de entrega).
/// * [failed]: no salió (rechazado por Android o fallo de envío), o expiró.
/// * [deliveryFailed]: salió, pero la operadora informó que no se entregó.
/// * [unknown]: no se puede saber si salió (p. ej. la app se cerró a mitad).
///   Nunca se reenvía automáticamente, para no duplicar.
enum SmsState {
  queued('QUEUED', 0),
  sending('SENDING', 1),
  accepted('ACCEPTED_BY_ANDROID', 2),
  sent('SENT_BY_MODEM', 3),
  delivered('DELIVERED_CONFIRMED', 4),
  failed('FAILED', 9),
  deliveryFailed('DELIVERY_FAILED', 9),
  unknown('UNKNOWN', 9);

  final String wire;
  final int rank;
  const SmsState(this.wire, this.rank);

  static SmsState fromWire(String s) =>
      SmsState.values.firstWhere((e) => e.wire == s, orElse: () => unknown);

  /// El mensaje ya no cambiará por el flujo normal de envío.
  bool get isFinal =>
      this == delivered || this == failed || this == deliveryFailed ||
      this == unknown;

  /// El SMS salió del teléfono (aunque no haya confirmación de entrega).
  bool get hasLeftPhone =>
      this == sent || this == delivered || this == deliveryFailed;
}

class SmsMessage {
  final String id;
  final int seq;
  final String phone;

  /// Texto del SMS. Se borra (queda vacío) tiempo después de terminar.
  final String message;
  final String? idempotencyKey;
  final SmsState state;
  final int? parts;
  final int attempts;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? sendingAt;
  final DateTime? acceptedAt;
  final DateTime? sentAt;
  final DateTime? deliveredAt;
  final DateTime? finishedAt;
  final String? error;
  final String? detail;
  final bool scrubbed;

  const SmsMessage({
    required this.id,
    required this.seq,
    required this.phone,
    required this.message,
    this.idempotencyKey,
    required this.state,
    this.parts,
    this.attempts = 0,
    required this.createdAt,
    required this.updatedAt,
    this.sendingAt,
    this.acceptedAt,
    this.sentAt,
    this.deliveredAt,
    this.finishedAt,
    this.error,
    this.detail,
    this.scrubbed = false,
  });

  SmsMessage copyWith({
    String? message,
    SmsState? state,
    int? parts,
    int? attempts,
    DateTime? updatedAt,
    DateTime? sendingAt,
    DateTime? acceptedAt,
    DateTime? sentAt,
    DateTime? deliveredAt,
    DateTime? finishedAt,
    String? error,
    String? detail,
    bool? scrubbed,
  }) =>
      SmsMessage(
        id: id,
        seq: seq,
        phone: phone,
        message: message ?? this.message,
        idempotencyKey: idempotencyKey,
        state: state ?? this.state,
        parts: parts ?? this.parts,
        attempts: attempts ?? this.attempts,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        sendingAt: sendingAt ?? this.sendingAt,
        acceptedAt: acceptedAt ?? this.acceptedAt,
        sentAt: sentAt ?? this.sentAt,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        finishedAt: finishedAt ?? this.finishedAt,
        error: error ?? this.error,
        detail: detail ?? this.detail,
        scrubbed: scrubbed ?? this.scrubbed,
      );

  /// Número parcialmente oculto para respuestas y logs: +5959****3456.
  static String maskPhone(String phone) {
    if (phone.length <= 8) return '****';
    return '${phone.substring(0, 5)}****${phone.substring(phone.length - 4)}';
  }

  String get maskedPhone => maskPhone(phone);

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        'phone': phone,
        'message': message,
        'idempotencyKey': idempotencyKey,
        'state': state.wire,
        'parts': parts,
        'attempts': attempts,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'sendingAt': sendingAt?.toUtc().toIso8601String(),
        'acceptedAt': acceptedAt?.toUtc().toIso8601String(),
        'sentAt': sentAt?.toUtc().toIso8601String(),
        'deliveredAt': deliveredAt?.toUtc().toIso8601String(),
        'finishedAt': finishedAt?.toUtc().toIso8601String(),
        'error': error,
        'detail': detail,
        'scrubbed': scrubbed,
      };

  static DateTime? _date(dynamic v) =>
      v == null ? null : DateTime.parse(v as String);

  factory SmsMessage.fromJson(Map<String, dynamic> j) => SmsMessage(
        id: j['id'] as String,
        seq: j['seq'] as int,
        phone: j['phone'] as String,
        message: j['message'] as String,
        idempotencyKey: j['idempotencyKey'] as String?,
        state: SmsState.fromWire(j['state'] as String),
        parts: j['parts'] as int?,
        attempts: (j['attempts'] as int?) ?? 0,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        sendingAt: _date(j['sendingAt']),
        acceptedAt: _date(j['acceptedAt']),
        sentAt: _date(j['sentAt']),
        deliveredAt: _date(j['deliveredAt']),
        finishedAt: _date(j['finishedAt']),
        error: j['error'] as String?,
        detail: j['detail'] as String?,
        scrubbed: (j['scrubbed'] as bool?) ?? false,
      );
}
