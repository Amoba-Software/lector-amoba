import 'dart:convert';
import 'dart:io';

import 'document_service.dart';
import 'engine_config.dart';

class ReadingSnapshot {
  const ReadingSnapshot(
    this.document,
    this.index,
    this.voice,
    this.speed, {
    this.total = 0,
  });
  final ReadingDocument document;
  final int index;
  final int voice;
  final double speed;
  final int total;
}

/// A document read before, with the fragment where it was left.
class LibraryEntry {
  const LibraryEntry(this.name, this.hash, this.index, this.total);
  final String name;
  final String hash;
  final int index;
  final int total;
  Map<String, Object> toJson() => {
    'name': name,
    'hash': hash,
    'index': index,
    'total': total,
  };
}

final _validHash = RegExp(r'^[a-f0-9]{64}$');

class ReadingRepository {
  ReadingRepository(this.directory);
  final Directory directory;
  Future<void> _writes = Future.value();

  File get _library => File('${directory.path}/library.json');

  Future<List<LibraryEntry>> _readLibrary() async {
    try {
      final data = jsonDecode(await _library.readAsString()) as List<dynamic>;
      return [
        for (final item in data.cast<Map<String, dynamic>>())
          LibraryEntry(
            item['name'] as String,
            item['hash'] as String,
            item['index'] as int,
            item['total'] as int,
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeLibrary(List<LibraryEntry> entries) async {
    final file = File('${_library.path}.tmp');
    await file.writeAsString(
      jsonEncode([for (final entry in entries) entry.toJson()]),
      flush: true,
    );
    await file.rename(_library.path);
  }

  /// Most recent first; waits for pending saves.
  Future<List<LibraryEntry>> library() => _writes.then((_) => _readLibrary());

  Future<ReadingDocument> load(LibraryEntry entry) async {
    if (!_validHash.hasMatch(entry.hash)) {
      throw const FormatException('Documento guardado inválido.');
    }
    final source = await File('${directory.path}/documents/${entry.hash}.md')
        .readAsString();
    return ReadingDocument(
      name: entry.name,
      hash: entry.hash,
      markdown: source,
    );
  }

  Future<void> forget(String hash) {
    final work = _writes.then((_) async {
      final entries = await _readLibrary();
      await _writeLibrary(
        entries.where((entry) => entry.hash != hash).toList(),
      );
      final file = File('${directory.path}/documents/$hash.md');
      if (_validHash.hasMatch(hash) && await file.exists()) await file.delete();
    });
    _writes = work.catchError((Object _) {});
    return work;
  }

  Future<void> save(ReadingSnapshot snapshot) {
    final json = jsonEncode({
      'document': snapshot.document.toJson(),
      'index': snapshot.index,
      'voice': snapshot.voice,
      'speed': snapshot.speed,
    });
    final write = _writes.then((_) async {
      await directory.create(recursive: true);
      final file = File('${directory.path}/reading.json.tmp');
      await file.writeAsString(json, flush: true);
      await file.rename('${directory.path}/reading.json');
      final document = snapshot.document;
      final entries = await _readLibrary();
      final previous = entries.where((entry) => entry.hash == document.hash);
      await _writeLibrary([
        LibraryEntry(
          document.name,
          document.hash,
          snapshot.index,
          snapshot.total > 0
              ? snapshot.total
              : previous.isEmpty
              ? 0
              : previous.first.total,
        ),
        ...entries.where((entry) => entry.hash != document.hash).take(49),
      ]);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<ReadingSnapshot?> restore() async {
    final file = File('${directory.path}/reading.json');
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final meta = json['document'] as Map<String, dynamic>;
    final hash = meta['hash'] as String;
    if (!_validHash.hasMatch(hash)) {
      throw const FormatException('Posición guardada inválida.');
    }
    final source = await File('${directory.path}/documents/$hash.md')
        .readAsString();
    final voice = json['voice'] as int;
    final speed = (json['speed'] as num).toDouble();
    return ReadingSnapshot(
      ReadingDocument(
        name: meta['name'] as String,
        hash: hash,
        markdown: source,
      ),
      json['index'] as int,
      readerVoices.containsKey(voice) ? voice : readerVoices.keys.first,
      [0.8, 1.0, 1.2, 1.5].contains(speed) ? speed : 1.0,
    );
  }
}
