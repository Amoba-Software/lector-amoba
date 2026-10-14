import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/document_service.dart';
import 'package:lector_amoba/docx_converter.dart';
import 'package:lector_amoba/markdown_speech_service.dart';

const _ns =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

List<int> docx(String body, {String styles = '', String numbering = ''}) {
  final archive = Archive();
  void add(String path, String xml) {
    final data = utf8.encode(xml);
    archive.addFile(ArchiveFile(path, data.length, data));
  }

  add(
    'word/document.xml',
    '<w:document $_ns><w:body>$body</w:body></w:document>',
  );
  if (styles.isNotEmpty) {
    add('word/styles.xml', '<w:styles $_ns>$styles</w:styles>');
  }
  if (numbering.isNotEmpty) {
    add('word/numbering.xml', '<w:numbering $_ns>$numbering</w:numbering>');
  }
  return ZipEncoder().encode(archive);
}

String p(String text, {String properties = ''}) =>
    '<w:p><w:pPr>$properties</w:pPr><w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';

void main() {
  test('Convierte títulos en español, listas y tablas de Word', () {
    final markdown = docxToMarkdown(
      docx(
        [
          p('Informe', properties: '<w:pStyle w:val="Ttulo1"/>'),
          p('Primer párrafo con 25 € y *asteriscos*.'),
          p(
            'Paso uno',
            properties:
                '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>',
          ),
          p(
            'Paso dos',
            properties:
                '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>',
          ),
          p(
            'Viñeta',
            properties:
                '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>',
          ),
          '<w:tbl><w:tr><w:tc>${p('Ruta')}</w:tc><w:tc>${p('Hora')}</w:tc></w:tr>'
              '<w:tr><w:tc>${p('Norte')}</w:tc><w:tc>${p('8:00')}</w:tc></w:tr></w:tbl>',
          '<w:p><w:r><w:t>Texto </w:t></w:r><w:del><w:r><w:delText>borrado</w:delText></w:r></w:del>'
              '<w:hyperlink><w:r><w:t>enlazado</w:t></w:r></w:hyperlink></w:p>',
          p('1. No es una lista'),
        ].join(),
        styles:
            '<w:style w:styleId="Ttulo1"><w:name w:val="heading 1"/></w:style>',
        numbering:
            '<w:abstractNum w:abstractNumId="10"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
            '<w:abstractNum w:abstractNumId="11"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>'
            '<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>'
            '<w:num w:numId="2"><w:abstractNumId w:val="11"/></w:num>',
      ),
    );
    expect(markdown, startsWith('# Informe\n\n'));
    expect(markdown, contains('1. Paso uno\n2. Paso dos\n- Viñeta'));
    expect(markdown, contains('| Ruta | Hora |'));
    expect(markdown, isNot(contains('borrado')));
    final chunks = MarkdownSpeechService().parse(markdown);
    final texts = chunks.map((chunk) => chunk.text).toList();
    expect(chunks.first.heading, isTrue);
    expect(texts, contains('Primer párrafo con 25 € y *asteriscos*.'));
    expect(texts, containsAll(['1. Paso uno', '2. Paso dos', 'Viñeta']));
    expect(texts, contains('Ruta: Norte. Hora: 8:00'));
    expect(texts, contains('Texto enlazado'));
    expect(texts, contains('1. No es una lista'));
  });

  test('Rechaza archivos que no son Word o no tienen texto', () async {
    expect(() => docxToMarkdown([1, 2, 3]), throwsFormatException);
    expect(() => docxToMarkdown(docx('<w:p/>')), throwsFormatException);
    expect(
      await DocumentService.importText('notas.docx', docx(p('Hola'))),
      'Hola\n',
    );
    expect(
      await DocumentService.importText('notas.md', utf8.encode('# Hola')),
      '# Hola',
    );
  });
}
