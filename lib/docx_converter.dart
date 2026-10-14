import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _maxXmlBytes = 30 * 1024 * 1024;

/// Converts the body of a Word (.docx) file into Markdown so it goes through
/// the same speech parser and preview as a .md file. Keeps headings, lists,
/// tables and paragraphs; drops images, deleted text and field codes.
String docxToMarkdown(List<int> bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException('El archivo Word está dañado o no es .docx.');
  }
  final body = _xml(archive, 'word/document.xml');
  if (body == null) {
    throw const FormatException('El archivo Word está dañado o no es .docx.');
  }
  final converter = _Converter(
    _headingStyles(_xml(archive, 'word/styles.xml')),
    _numberedLists(_xml(archive, 'word/numbering.xml')),
  );
  final root = body.rootElement.getElement('body', namespaceUri: _w);
  if (root != null) converter.block(root);
  final markdown = converter.output.toString().trim();
  if (markdown.isEmpty) {
    throw const FormatException('El documento Word no contiene texto.');
  }
  return '$markdown\n';
}

XmlDocument? _xml(Archive archive, String path) {
  final file = archive.findFile(path);
  if (file == null) return null;
  if (file.size > _maxXmlBytes) {
    throw const FormatException('El documento Word es demasiado grande.');
  }
  final data = file.readBytes();
  if (data == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(data).replaceFirst('\uFEFF', ''));
  } catch (_) {
    throw const FormatException('El archivo Word está dañado o no es .docx.');
  }
}

String? _val(XmlElement? element) =>
    element?.getAttribute('val', namespaceUri: _w);

/// Style id → heading level. Localized Word names styles by id ("Ttulo1"),
/// so the level comes from the style name ("heading 1") or its outline level.
Map<String, int> _headingStyles(XmlDocument? styles) {
  final result = <String, int>{};
  if (styles == null) return result;
  for (final style in styles.findAllElements('style', namespaceUri: _w)) {
    final id = style.getAttribute('styleId', namespaceUri: _w);
    if (id == null) continue;
    final name = (_val(style.getElement('name', namespaceUri: _w)) ?? '')
        .toLowerCase();
    final heading = RegExp(r'^heading (\d)$').firstMatch(name);
    final outline = int.tryParse(
      _val(
            style
                .getElement('pPr', namespaceUri: _w)
                ?.getElement('outlineLvl', namespaceUri: _w),
          ) ??
          '',
    );
    if (name == 'title') {
      result[id] = 1;
    } else if (heading != null) {
      result[id] = int.parse(heading.group(1)!).clamp(1, 6);
    } else if (outline != null && outline < 9) {
      result[id] = (outline + 1).clamp(1, 6);
    }
  }
  return result;
}

/// (numId, level) pairs whose list format is a number rather than a bullet.
Set<String> _numberedLists(XmlDocument? numbering) {
  final result = <String>{};
  if (numbering == null) return result;
  final abstract = <String, Map<String, String>>{};
  for (final definition in numbering.findAllElements(
    'abstractNum',
    namespaceUri: _w,
  )) {
    final id = definition.getAttribute('abstractNumId', namespaceUri: _w);
    if (id == null) continue;
    abstract[id] = {
      for (final level in definition.findElements('lvl', namespaceUri: _w))
        level.getAttribute('ilvl', namespaceUri: _w) ?? '0':
            _val(level.getElement('numFmt', namespaceUri: _w)) ?? 'bullet',
    };
  }
  for (final number in numbering.findAllElements('num', namespaceUri: _w)) {
    final id = number.getAttribute('numId', namespaceUri: _w);
    final formats =
        abstract[_val(number.getElement('abstractNumId', namespaceUri: _w))];
    if (id == null || formats == null) continue;
    formats.forEach((level, format) {
      if (format != 'bullet' && format != 'none') result.add('$id:$level');
    });
  }
  return result;
}

class _Converter {
  _Converter(this.headings, this.numbered);
  final Map<String, int> headings;
  final Set<String> numbered;
  final output = StringBuffer();
  final _counters = <String, int>{};
  bool _inList = false;

  void block(XmlElement parent) {
    for (final child in parent.childElements) {
      if (child.namespaceUri != _w) continue;
      switch (child.localName) {
        case 'p':
          paragraph(child);
        case 'tbl':
          table(child);
        case 'sdt':
          final content = child.getElement('sdtContent', namespaceUri: _w);
          if (content != null) block(content);
      }
    }
  }

  void _emit(String line, {bool listItem = false}) {
    if (output.isNotEmpty) output.write(listItem && _inList ? '\n' : '\n\n');
    output.write(line);
    _inList = listItem;
  }

  void paragraph(XmlElement element) {
    final text = inline(element);
    if (text.isEmpty) return;
    final properties = element.getElement('pPr', namespaceUri: _w);
    final style = _val(properties?.getElement('pStyle', namespaceUri: _w));
    final outline = int.tryParse(
      _val(properties?.getElement('outlineLvl', namespaceUri: _w)) ?? '',
    );
    final level = outline != null && outline < 9
        ? (outline + 1).clamp(1, 6)
        : headings[style];
    if (level != null) {
      _emit('${'#' * level} $text');
      return;
    }
    final list = properties?.getElement('numPr', namespaceUri: _w);
    final numId = _val(list?.getElement('numId', namespaceUri: _w));
    if (numId != null && numId != '0') {
      final depth = _val(list?.getElement('ilvl', namespaceUri: _w)) ?? '0';
      final key = '$numId:$depth';
      if (numbered.contains(key)) {
        final number = (_counters[key] ?? 0) + 1;
        _counters[key] = number;
        _emit('$number. $text', listItem: true);
      } else {
        _emit('- $text', listItem: true);
      }
      return;
    }
    _emit(_escapeStart(text));
  }

  void table(XmlElement element) {
    final rows = [
      for (final row in element.findElements('tr', namespaceUri: _w))
        [
          for (final cell in row.findElements('tc', namespaceUri: _w))
            cell
                .findAllElements('p', namespaceUri: _w)
                .map(inline)
                .where((text) => text.isNotEmpty)
                .join(' ')
                .replaceAll('|', r'\|'),
        ],
    ].where((cells) => cells.any((cell) => cell.isNotEmpty)).toList();
    if (rows.isEmpty) return;
    final width = rows
        .map((cells) => cells.length)
        .reduce((a, b) => a > b ? a : b);
    String line(List<String> cells) =>
        '| ${[...cells, for (var i = cells.length; i < width; i++) ''].join(' | ')} |';
    _emit(
      [
        line(rows.first),
        '|${List.filled(width, ' --- ').join('|')}|',
        ...rows.skip(1).map(line),
      ].join('\n'),
    );
  }

  String inline(XmlElement paragraph) {
    final text = StringBuffer();
    void visit(XmlElement element) {
      for (final child in element.childElements) {
        if (child.namespaceUri != _w) continue;
        switch (child.localName) {
          case 't':
            text.write(_escape(child.innerText));
          case 'tab' || 'br' || 'cr':
            text.write(' ');
          // Deleted revisions, field codes and embedded drawings are not
          // part of the visible text.
          case 'del' || 'instrText' || 'drawing' || 'pict' || 'object':
            break;
          default:
            visit(child);
        }
      }
    }

    visit(paragraph);
    return text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[\\`*_\[\]<>|]'), (m) => '\\${m[0]}');

// A Word paragraph that starts like Markdown syntax ("# ", "- ", "1. ")
// must stay a paragraph.
String _escapeStart(String text) => text
    .replaceFirstMapped(RegExp(r'^(\d+)([.)])'), (m) => '${m[1]}\\${m[2]}')
    .replaceFirstMapped(RegExp(r'^[#>+\-=]'), (m) => '\\${m[0]}');
