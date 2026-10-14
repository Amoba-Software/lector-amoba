import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/markdown_speech_service.dart';
import 'package:lector_amoba/speech_batch.dart';

void main() {
  test('Los bloques conservan todo el texto en orden y respetan títulos', () {
    final chunks = MarkdownSpeechService().parse(
      '# Inicio\n\n${List.filled(70, 'Una frase clara y completa.').join(' ')}\n\n# Final\n\nÚltima frase.',
    );
    final batches = <SpeechBatch>[];
    var next = 0;
    while (next < chunks.length) {
      final batch = speechBatch(chunks, next);
      batches.add(batch);
      expect(batch.end - batch.start, lessThanOrEqualTo(4));
      expect(batch.text.length, lessThanOrEqualTo(480));
      if (batch.heading) expect(batch.end, batch.start + 1);
      expect(
        chunks.sublist(batch.start + 1, batch.end).any((c) => c.heading),
        isFalse,
      );
      next = batch.end;
    }
    expect(
      batches.map((b) => b.text).join(' '),
      chunks.map((c) => c.text).join(' '),
    );
    expect(batches.length, lessThan(chunks.length));
  });
}
