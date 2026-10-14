import 'engine_config.dart';

// Frequent function words that are unambiguous between both languages.
const _english = {
  'the',
  'and',
  'of',
  'to',
  'is',
  'in',
  'that',
  'it',
  'for',
  'with',
  'you',
  'this',
  'are',
  'on',
  'be',
  'as',
  'was',
  'have',
  'from',
  'or',
  'by',
  'at',
  'which',
  'will',
  'can',
  'not',
  'your',
  'we',
  'they',
  'if',
};
const _spanish = {
  'el',
  'la',
  'de',
  'que',
  'y',
  'los',
  'las',
  'en',
  'un',
  'una',
  'es',
  'por',
  'para',
  'con',
  'del',
  'se',
  'lo',
  'al',
  'como',
  'más',
  'pero',
  'sus',
  'su',
  'está',
  'son',
  'este',
  'esta',
  'cuando',
  'también',
  'si',
};

/// Guesses the reading language from the first words of a document. Spanish
/// wins ties, so short or mixed documents keep the default voices.
ReadingLanguage detectReadingLanguage(Iterable<String> texts) {
  var english = 0;
  var spanish = 0;
  var words = 0;
  final pattern = RegExp(r'[\p{L}]+', unicode: true);
  for (final text in texts) {
    for (final match in pattern.allMatches(text.toLowerCase())) {
      final word = match.group(0)!;
      if (_english.contains(word)) english++;
      if (_spanish.contains(word)) spanish++;
      if (++words >= 3000) break;
    }
    if (words >= 3000) break;
  }
  return english >= 5 && english > spanish * 1.5
      ? ReadingLanguage.en
      : ReadingLanguage.es;
}
