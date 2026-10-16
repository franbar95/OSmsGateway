// To parse this JSON data, do
//
//     final smsReturn = smsReturnFromJson(jsonString);

import 'dart:convert';

/// Representación de un SMS leído del teléfono. La lectura (`_readSMS`) está
/// desactivada, pero se conserva este modelo sin depender de ningún plugin.
class SmsReturn {
  int? id;
  String? address;
  String? body;
  int? date;
  int? dateSent;
  bool? read;
  bool? seen;
  String? subject;
  int? subscriptionId;
  int? threadId;
  SmsReturn({
    this.id,
    this.address,
    this.body,
    this.date,
    this.dateSent,
    this.read,
    this.seen,
    this.subject,
    this.subscriptionId,
    this.threadId,
  });

  String toRawJson() => json.encode(toJson());

  Map<String, dynamic> toJson() => {
        "id": id == null ? null : id,
        "address": address == null ? null : address,
        "body": body == null ? null : body,
        "date": date == null ? null : date,
        "dateSent": dateSent == null ? null : dateSent,
        "read": read == null ? null : read,
        "seen": seen == null ? null : seen,
        "subject": subject == null ? null : subject,
        "subscriptionId": subscriptionId == null ? null : subscriptionId,
        "threadId": threadId == null ? null : threadId,
      };
}
