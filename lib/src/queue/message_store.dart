import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:osmsgateway/src/queue/sms_message.dart';

/// Almacén de mensajes en memoria con persistencia opcional en un archivo JSON.
///
/// Todas las lecturas y modificaciones son síncronas sobre la memoria, así que
/// "buscar y añadir" es atómico respecto al bucle de eventos. Cada modificación
/// devuelve un `Future` que completa cuando el cambio ya está escrito en disco
/// (escritura a archivo temporal + renombrado, para no dejar el archivo a medias).
class MessageStore {
  final Future<String> Function()? _pathProvider;
  final void Function(String)? _log;
  final List<SmsMessage> _messages = [];
  int _nextSeq = 1;
  File? _file;
  Future<void> _writeChain = Future.value();
  Future<void>? _loading;

  /// Almacén solo en memoria (pruebas).
  MessageStore.memory()
      : _pathProvider = null,
        _log = null;

  /// Almacén persistente. [pathProvider] resuelve la ruta del archivo.
  MessageStore.file(Future<String> Function() pathProvider,
      {void Function(String)? log})
      : _pathProvider = pathProvider,
        _log = log;

  /// Carga el archivo (una sola vez). Debe esperarse antes de usar el almacén.
  Future<void> load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    final provider = _pathProvider;
    if (provider == null) return;
    final file = File(await provider());
    _file = file;
    await file.parent.create(recursive: true);
    if (!await file.exists()) return;
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (e) {
      // Error de lectura (no de contenido): no se toca el archivo.
      throw StateError('No se pudo leer la cola de mensajes: $e');
    }
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      for (final j in (data['messages'] as List)) {
        _messages.add(SmsMessage.fromJson(Map<String, dynamic>.from(j as Map)));
      }
      _nextSeq = (data['nextSeq'] as int?) ?? (_maxSeq() + 1);
    } catch (e) {
      // Contenido inválido: se aparta para no perderlo y se sigue con cola vacía.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final aside = File('${file.path}.corrupt-$stamp');
      try {
        await file.rename(aside.path);
      } catch (_) {}
      _messages.clear();
      _nextSeq = 1;
      _log?.call('El archivo de la cola estaba dañado y se apartó en '
          '${aside.path}: $e');
    }
  }

  int _maxSeq() =>
      _messages.fold<int>(0, (m, e) => e.seq > m ? e.seq : m);

  /// Copia de todos los mensajes, del más viejo al más nuevo.
  List<SmsMessage> all() {
    final list = List<SmsMessage>.from(_messages);
    list.sort((a, b) => a.seq.compareTo(b.seq));
    return list;
  }

  SmsMessage? get(String id) {
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  SmsMessage? findByKey(String key) {
    for (final m in _messages) {
      if (m.idempotencyKey == key) return m;
    }
    return null;
  }

  int nextSeq() => _nextSeq++;

  /// Añade un mensaje; completa cuando está guardado en disco.
  Future<void> add(SmsMessage m) {
    _messages.add(m);
    return _save();
  }

  /// Aplica [fn] al mensaje [id]. Si devuelve `null` no hay cambios.
  /// Devuelve el mensaje resultante y, en [saved], el momento en que quedó en disco.
  ({SmsMessage? message, Future<void> saved}) mutate(
      String id, SmsMessage? Function(SmsMessage current) fn) {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return (message: null, saved: Future.value());
    final updated = fn(_messages[i]);
    if (updated == null) return (message: _messages[i], saved: Future.value());
    _messages[i] = updated;
    return (message: updated, saved: _save());
  }

  /// Elimina los mensajes que cumplan [test].
  Future<int> removeWhere(bool Function(SmsMessage) test) {
    final before = _messages.length;
    _messages.removeWhere(test);
    final removed = before - _messages.length;
    return removed == 0 ? Future.value(0) : _save().then((_) => removed);
  }

  Future<void> _save() {
    final file = _file;
    if (file == null) return Future.value();
    // Se serializa en el momento del cambio y se escribe en orden.
    final payload = jsonEncode({
      'version': 1,
      'nextSeq': _nextSeq,
      'messages': _messages.map((m) => m.toJson()).toList(),
    });
    _writeChain = _writeChain.catchError((_) {}).then((_) async {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    });
    return _writeChain;
  }
}
