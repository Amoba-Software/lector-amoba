import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lector_amoba/audio_validation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Audits the real app's cached 16-bit mono WAVs through the new DSP pipeline.
void main(List<String> args) {
  sherpa.initBindings();
  final output = Directory(args[1])..createSync(recursive: true);
  final report = <Map<String, Object?>>[];
  for (final file in Directory(args[0]).listSync().whereType<File>()) {
    if (!file.path.endsWith('.wav')) continue;
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(36, 40)) != 'data' ||
        data.getUint16(20, Endian.little) != 1 ||
        data.getUint16(22, Endian.little) != 1 ||
        data.getUint16(34, Endian.little) != 16) {
      throw FormatException(
        'Se requiere WAV PCM mono con cabecera de 44 bytes',
        file.path,
      );
    }
    final rate = data.getUint32(24, Endian.little);
    final samples = Float32List((bytes.length - 44) ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(44 + 2 * i, Endian.little) / 32768;
    }
    final clock = Stopwatch()..start();
    validateSpeechAudio(samples, rate);
    final cleaned = prepareSpeechAudio(samples, rate);
    validateSpeechAudio(cleaned, rate);
    final processingUs = clock.elapsedMicroseconds;
    final name = file.uri.pathSegments.last;
    if (!sherpa.writeWave(
      filename: '${output.path}/$name',
      samples: cleaned,
      sampleRate: rate,
    )) {
      throw StateError('No se pudo guardar $name');
    }
    double mean(Float32List values) =>
        values.fold(0.0, (a, b) => a + b) / values.length;
    report.add({
      'file': name,
      'samples': samples.length,
      'dcBefore': mean(samples),
      'dcAfter': mean(cleaned),
      'processingUs': processingUs,
    });
  }
  Directory('docs').createSync();
  File('docs/audio-cleaning.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'pipeline': audioPipelineVersion,
      'scope': 'Cached emulator WAVs; PCM checks are not perceptual approval',
      'files': report,
    }),
  );
  stdout.writeln('Validated and cleaned ${report.length} WAVs.');
}
