import 'dart:convert';
import 'dart:io';

import 'engine_config.dart';

/// A user rule: whenever [written] appears as a whole word, say [spoken].
class Pronunciation {
  const Pronunciation(this.written, this.spoken);
  final String written;
  final String spoken;
  Map<String, String> toJson() => {'written': written, 'spoken': spoken};
}

final _symbolsToPause = RegExp(r'\s*(?:->|=>|[→⇒·•|—–])\s*');
final _range = RegExp(r'(\d)\s*[–—]\s*(\d)');
final _hash = RegExp(r'(^|[\s(])#+(?=\S)|(^|\s)#+(?=\s|$)');
final _wordSlash = RegExp(
  r'(?<=[\p{L}\p{N}])/(?=\p{L})|(?<=\p{L})/(?=\p{N})',
  unicode: true,
);
final _underscore = RegExp(r'_+');
final _noise = RegExp(r'[*`~^\\{}\[\]<>«»“”"=]');
final _emoji = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]',
  unicode: true,
);

/// Text sent to the voice: the screen keeps the original, but Markdown and
/// code leftovers (#, *, _, /, arrows...) would be spelled out by espeak.
String speakable(
  String text,
  ReadingLanguage language, [
  List<Pronunciation> dictionary = const [],
]) {
  for (final rule in dictionary) {
    if (rule.written.trim().isEmpty) continue;
    text = text.replaceAll(
      RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(rule.written.trim())}(?![\\p{L}\\p{N}])',
        unicode: true,
        caseSensitive: false,
      ),
      rule.spoken,
    );
  }
  final to = language == ReadingLanguage.en ? 'to' : 'a';
  return text
      .replaceAll(_emoji, '')
      .replaceAll(RegExp(r'^\s*[-+]\s+'), '')
      .replaceAllMapped(_range, (m) => '${m[1]} $to ${m[2]}')
      .replaceAllMapped(_hash, (m) => m[1] ?? m[2] ?? '')
      .replaceAll(_symbolsToPause, ', ')
      .replaceAll(_wordSlash, ' ')
      .replaceAll(_underscore, ' ')
      .replaceAll(_noise, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s+([,.;:!?])(?=\s|$)'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'([,;:])(?:\s*[,;:])+'), (m) => m[1]!)
      .replaceAll(RegExp(r'^[,;:\s]+'), '')
      .trim();
}

class PronunciationRepository {
  PronunciationRepository(this.directory);
  final Directory directory;
  File get _file => File('${directory.path}/pronunciation.json');

  Future<List<Pronunciation>> load() async {
    try {
      final data = jsonDecode(await _file.readAsString()) as List<dynamic>;
      return [
        for (final item in data.cast<Map<String, dynamic>>())
          Pronunciation(item['written'] as String, item['spoken'] as String),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Pronunciation> rules) async {
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode([for (final rule in rules) rule.toJson()]),
      flush: true,
    );
    await temporary.rename(_file.path);
  }
}
