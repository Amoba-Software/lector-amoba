import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'docx_converter.dart';

/// File name without its extension, as shown to the reader.
String displayName(String name) => name
    .replaceFirst(
      RegExp(r'\.(md|markdown|txt|docx)$', caseSensitive: false),
      '',
    )
    .replaceAll('_', ' ');

class ReadingDocument {
  const ReadingDocument({
    required this.name,
    required this.hash,
    required this.markdown,
  });
  final String name;
  final String hash;
  final String markdown;
  Map<String, Object> toJson() => {'name': name, 'hash': hash};
}

class DocumentService {
  DocumentService(this.directory);
  final Directory directory;
  static const maxBytes = 2 * 1024 * 1024;
  // Word files carry images and styles; the extracted text is still capped
  // at [maxBytes].
  static const maxWordBytes = 30 * 1024 * 1024;
  static const extensions = ['.md', '.markdown', '.txt', '.docx'];

  static bool isWord(String name) => name.toLowerCase().endsWith('.docx');

  /// Text to read for an imported file: Word is converted to Markdown.
  static Future<String> importText(String name, List<int> bytes) async {
    if (!isWord(name)) return decode(bytes);
    final text = await compute(docxToMarkdown, bytes);
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('El texto del documento supera 2 MB.');
    }
    return text;
  }

  static String decode(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('El documento supera el límite de 2 MB.');
    }
    try {
      final text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
      if (text.trim().isEmpty) {
        throw const FormatException('El archivo está vacío.');
      }
      return text;
    } on FormatException catch (error) {
      if (error.message == 'El archivo está vacío.') rethrow;
      throw const FormatException('El archivo debe estar codificado en UTF-8.');
    }
  }

  static void _checkName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.doc')) {
      throw const FormatException(
        'Los .doc antiguos no se pueden leer. Guárdalo como .docx.',
      );
    }
    if (!extensions.any(lower.endsWith)) {
      throw const FormatException(
        'Solo se pueden abrir archivos .md, .txt o .docx.',
      );
    }
  }

  static int _limit(String name) => isWord(name) ? maxWordBytes : maxBytes;
  static const _tooLarge = FormatException('El documento es demasiado grande.');

  Future<ReadingDocument?> pick() async {
    final selected = await FilePicker.pickFile(type: FileType.any);
    if (selected == null) return null;
    _checkName(selected.name);
    final limit = _limit(selected.name);
    if ((selected.lengthSync() ?? 0) > limit) throw _tooLarge;
    final bytes = <int>[];
    await for (final block in selected.readAsByteStream()) {
      bytes.addAll(block);
      if (bytes.length > limit) throw _tooLarge;
    }
    return importBytes(selected.name, bytes);
  }

  /// Stores a private copy of the text to read; used by the picker and by
  /// files opened or shared from other apps.
  Future<ReadingDocument> importBytes(String name, List<int> bytes) async {
    _checkName(name);
    if (bytes.length > _limit(name)) throw _tooLarge;
    final text = await importText(name, bytes);
    final hash = sha256.convert(utf8.encode(text)).toString();
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/$hash.md.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename('${directory.path}/$hash.md');
    return ReadingDocument(name: name, hash: hash, markdown: text);
  }
}
