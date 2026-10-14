import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/document_service.dart';
import 'package:lector_amoba/markdown_speech_service.dart';
import 'package:lector_amoba/reading_repository.dart';
import 'package:lector_amoba/engine_config.dart';

void main() {
  final parser = MarkdownSpeechService();
  test('Markdown estructural: etiquetas, imágenes, tablas y numeración', () {
    final chunks = parser.parse('''---
title: secreto
---
# Hola, niño

Lee **esto** y [la guía](https://example.com).

3. Primer paso
4. Segundo paso

![Autobús azul](imagen.png)

| Ciudad | Plazas |
| --- | --- |
| Quito | 18 |

`inline`

```dart
no decir esto
```
''');
    final text = chunks.map((chunk) => chunk.text).join('\n');
    expect(chunks.first.heading, isTrue);
    expect(text, contains('Hola, niño'));
    expect(text, contains('Lee esto y la guía.'));
    expect(text, contains('3. Primer paso'));
    expect(text, contains('4. Segundo paso'));
    expect(text, contains('Autobús azul'));
    expect(text, contains('Ciudad: Quito. Plazas: 18'));
    expect(text, contains('inline'));
    for (final omitted in [
      'https://',
      'imagen.png',
      'no decir esto',
      'secreto',
      '**',
    ]) {
      expect(text, isNot(contains(omitted)));
    }
  });
  test('HTML no ejecutable excluye script, style y contenido oculto', () {
    final text = parser
        .parse(
          '<div>Hola <b>Ana</b><script>alert(1)</script><span hidden>oculto</span></div>',
        )
        .map((chunk) => chunk.text)
        .join(' ');
    expect(text, contains('Hola Ana'));
    expect(text, isNot(contains('alert')));
    expect(text, isNot(contains('oculto')));
  });
  test('Fragmentos acotados conservan el contenido y palabras', () {
    final source = List.filled(100, 'Guayaquil, niño y café.').join(' ');
    final chunks = parser.parse(source);
    expect(chunks.length, greaterThan(1));
    expect(
      chunks.every(
        (chunk) => chunk.text.length <= MarkdownSpeechService.maxCharacters,
      ),
      isTrue,
    );
    expect(chunks.map((chunk) => chunk.text).join(' '), source);
  });
  test('Código, separadores y comentarios no producen lectura', () {
    expect(parser.parse('```\ncódigo\n```\n\n---\n\n<!-- oculto -->'), isEmpty);
  });
  test('UTF8 estricto, BOM, vacío y límite antes de decodificar', () {
    expect(
      DocumentService.decode([239, 187, 191, ...utf8.encode('niño')]),
      'niño',
    );
    expect(() => DocumentService.decode([255, 254]), throwsFormatException);
    expect(() => DocumentService.decode([]), throwsFormatException);
    expect(
      () =>
          DocumentService.decode(List.filled(DocumentService.maxBytes + 1, 65)),
      throwsFormatException,
    );
  });
  test('Persistencia atómica y restauración del último fragmento', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lector-repository',
    );
    try {
      final hash = List.filled(64, 'a').join();
      await Directory('${directory.path}/documents').create();
      await File('${directory.path}/documents/$hash.md').writeAsString('Hola');
      final repository = ReadingRepository(directory);
      final document = ReadingDocument(
        name: 'prueba.md',
        hash: hash,
        markdown: 'Hola',
      );
      await Future.wait([
        repository.save(ReadingSnapshot(document, 1, 28, 1)),
        repository.save(ReadingSnapshot(document, 7, 29, 1.2)),
      ]);
      final snapshot = await repository.restore();
      expect(snapshot!.index, 7);
      expect(snapshot.voice, readerVoices.containsKey(29) ? 29 : 28);
      expect(snapshot.speed, 1.2);
      expect(snapshot.document.markdown, 'Hola');
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('La biblioteca recuerda la posición de cada documento', () async {
    final directory = await Directory.systemTemp.createTemp('lector-library');
    addTearDown(() => directory.delete(recursive: true));
    final repository = ReadingRepository(directory);
    final a = List.filled(64, 'a').join();
    final b = List.filled(64, 'b').join();
    await Directory('${directory.path}/documents').create();
    for (final hash in [a, b]) {
      await File('${directory.path}/documents/$hash.md')
          .writeAsString('Hola $hash');
    }
    await repository.save(
      ReadingSnapshot(
        ReadingDocument(name: 'a.md', hash: a, markdown: ''),
        40,
        28,
        1,
        total: 100,
      ),
    );
    await repository.save(
      ReadingSnapshot(
        ReadingDocument(name: 'b.docx', hash: b, markdown: ''),
        3,
        28,
        1,
        total: 10,
      ),
    );
    await repository.save(
      ReadingSnapshot(
        ReadingDocument(name: 'a.md', hash: a, markdown: ''),
        41,
        28,
        1,
      ),
    );
    final entries = await repository.library();
    expect(entries.map((entry) => entry.name), ['a.md', 'b.docx']);
    expect(entries.first.index, 41);
    expect(entries.first.total, 100);
    expect((await repository.load(entries.last)).markdown, 'Hola $b');
    await repository.forget(b);
    expect((await repository.library()).single.hash, a);
    expect(await File('${directory.path}/documents/$b.md').exists(), isFalse);
    expect(displayName('Mi_informe.docx'), 'Mi informe');
  });
}
