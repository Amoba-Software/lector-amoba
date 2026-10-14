import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/audio_validation.dart';

void main() {
  test('Quita un desplazamiento DC conservando voz, longitud y frecuencia', () {
    final source = Float32List.fromList(
      List<double>.generate(
        24000,
        (i) => 0.025 + 0.2 * sin(2 * pi * 1000 * i / 24000),
      ),
    );
    final cleaned = prepareSpeechAudio(source, 24000);
    expect(cleaned.length, source.length);
    expect(cleaned.first, 0);
    expect(cleaned.last, 0);
    final middle = cleaned.sublist(1200, 22800);
    final mean = middle.reduce((a, b) => a + b) / middle.length;
    final rms = sqrt(middle.fold(0.0, (sum, x) => sum + x * x) / middle.length);
    expect(mean.abs(), lessThan(0.0001));
    expect(rms, closeTo(0.2 / sqrt(2), 0.001));
    expect(source.first, closeTo(0.025, 1e-6));
    expect(() => validateSpeechAudio(cleaned, 24000), returnsNormally);
  });
  test('Suaviza 5 ms en los bordes, conservando el centro y el original', () {
    final source = Float32List.fromList(List<double>.filled(24000, 0.4));
    final smooth = smoothSpeechEdges(source, 24000);
    expect(smooth.first, 0);
    expect(smooth.last, 0);
    expect(smooth[120], source[120]);
    expect(smooth[12000], source[12000]);
    expect(source.first, closeTo(0.4, 1e-6));
    expect(smooth.every((x) => x.isFinite), isTrue);
    expect(smoothSpeechEdges(Float32List(1), 24000).length, 1);
  });
  test('Permite pausas y una señal de voz sin saturación', () {
    final audio = List<double>.generate(
      24000,
      (i) => i < 6000 ? 0 : 0.4 * sin(i * 0.1),
    );
    expect(() => validateSpeechAudio(audio, 24000), returnsNormally);
  });
  test('Rechaza audio vacío, frecuencia incorrecta y valores no finitos', () {
    for (final values in [
      <double>[],
      [double.nan],
      [double.infinity],
    ]) {
      expect(() => validateSpeechAudio(values, 24000), throwsStateError);
    }
    expect(() => validateSpeechAudio([0.1], 0), throwsStateError);
  });
  test('Detecta una frase saturada dentro de audio normal', () {
    final audio = List<double>.filled(240000, 0.1);
    audio.fillRange(10000, 11000, 1.0);
    expect(() => validateSpeechAudio(audio, 24000), throwsStateError);
  });
  test('Detecta saturación dispersa y tolera un pico aislado', () {
    final audio = List<double>.generate(24000, (i) => i % 10 == 0 ? -1.0 : 0.1);
    expect(() => validateSpeechAudio(audio, 24000), throwsStateError);
    audio.fillRange(0, audio.length, 0.1);
    audio[100] = 1.0;
    expect(() => validateSpeechAudio(audio, 24000), returnsNormally);
  });
}
