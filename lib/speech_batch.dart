import 'markdown_speech_service.dart';

class SpeechBatch {
  const SpeechBatch(this.start, this.end, this.text, this.heading);
  final int start;
  final int end;
  final String text;
  final bool heading;
}

SpeechBatch speechBatch(
  List<SpeechChunk> chunks,
  int start, {
  int maxChunks = 4,
  int maxCharacters = 480,
}) {
  var end = start + 1;
  var text = chunks[start].text;
  final heading = chunks[start].heading;
  if (!heading) {
    while (end < chunks.length && end - start < maxChunks) {
      final next = chunks[end];
      if (next.heading || text.length + next.text.length + 1 > maxCharacters) {
        break;
      }
      // Prefer a sentence boundary once there is enough audio to buffer ahead.
      if (text.length >= 280 && RegExp(r'[.!?;]$').hasMatch(text)) break;
      text = '$text ${next.text}';
      end++;
    }
  }
  return SpeechBatch(start, end, text, heading);
}
