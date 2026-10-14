import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

List<SpeechChunk> parseMarkdown(String source) =>
    MarkdownSpeechService().parse(source);

class SpeechChunk {
  const SpeechChunk(this.text, {this.heading = false});
  final String text;
  final bool heading;
}

class MarkdownSpeechService {
  static const maxCharacters = 160;

  List<SpeechChunk> parse(String source) {
    final lines = source.replaceFirst('\uFEFF', '').split('\n');
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final end = lines.indexWhere(
        (line) => ['---', '...'].contains(line.trim()),
        1,
      );
      if (end > 0) lines.removeRange(0, end + 1);
    }
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final nodes = document.parseLines(lines);
    final chunks = <SpeechChunk>[];
    void emit(String text, {bool heading = false}) {
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text)) return;
      for (final part in split(text)) {
        chunks.add(SpeechChunk(part, heading: heading));
      }
    }

    void visit(md.Node node) {
      if (node is md.Text) {
        emit(visibleHtml(node.text));
        return;
      }
      final element = node as md.Element;
      switch (element.tag) {
        case 'pre':
        case 'hr':
          return;
        case 'table':
          final rows = <md.Element>[];
          void collect(md.Node child) {
            if (child is! md.Element) return;
            if (child.tag == 'tr') {
              rows.add(child);
            } else {
              child.children?.forEach(collect);
            }
          }
          element.children?.forEach(collect);
          List<String>? headers;
          for (final row in rows) {
            final cells = row.children?.whereType<md.Element>().toList() ?? [];
            if (cells.any((cell) => cell.tag == 'th')) {
              headers = cells.map(inline).toList();
            } else {
              emit(
                List.generate(cells.length, (i) {
                  final value = inline(cells[i]);
                  return headers != null && i < headers.length
                      ? '${headers[i]}: $value'
                      : value;
                }).join('. '),
              );
            }
          }
          return;
        case 'ol':
        case 'ul':
          var number = int.tryParse(element.attributes['start'] ?? '') ?? 1;
          for (final item in element.children ?? <md.Node>[]) {
            if (item is! md.Element || item.tag != 'li') continue;
            final children = item.children ?? <md.Node>[];
            emit(
              '${element.tag == 'ol' ? '${number++}. ' : ''}${children.where((child) => child is! md.Element || !['ol', 'ul'].contains(child.tag)).map(inline).join(' ')}',
            );
            for (final child in children.whereType<md.Element>()) {
              if (['ol', 'ul'].contains(child.tag)) visit(child);
            }
          }
          return;
        case 'blockquote':
          element.children?.forEach(visit);
          return;
        default:
          emit(
            inline(element),
            heading: RegExp(r'^h[1-6]$').hasMatch(element.tag),
          );
      }
    }

    nodes.forEach(visit);
    return chunks;
  }

  String inline(md.Node node) {
    if (node is md.Text) return visibleHtml(node.text);
    final element = node as md.Element;
    if (element.tag == 'img') return element.attributes['alt'] ?? '';
    if (['pre', 'script', 'style'].contains(element.tag)) return '';
    if (element.tag == 'br') return ' ';
    if (element.tag == 'a') {
      final label = (element.children ?? []).map(inline).join();
      if (label == element.attributes['href'] ||
          RegExp(r'^https?://').hasMatch(label)) {
        return '';
      }
      return label;
    }
    return (element.children ?? [])
        .map(inline)
        .join(element.tag == 'li' ? ' ' : '');
  }

  String visibleHtml(String source) {
    final fragment = html.parseFragment(source);
    fragment
        .querySelectorAll('script, style, template, [hidden]')
        .forEach((node) => node.remove());
    return fragment.text ?? '';
  }

  List<String> split(String text) {
    final result = <String>[];
    final sentences = text.split(RegExp(r'(?<=[.!?;])\s+'));
    var current = '';
    for (var sentence in sentences) {
      while (sentence.length > maxCharacters) {
        if (current.isNotEmpty) {
          result.add(current);
          current = '';
        }
        var cut = sentence.lastIndexOf(' ', maxCharacters);
        if (cut < 1) cut = maxCharacters;
        result.add(sentence.substring(0, cut).trim());
        sentence = sentence.substring(cut).trim();
      }
      if ('$current $sentence'.trim().length > maxCharacters) {
        result.add(current);
        current = sentence;
      } else {
        current = '$current $sentence'.trim();
      }
    }
    if (current.isNotEmpty) result.add(current);
    return result;
  }
}
