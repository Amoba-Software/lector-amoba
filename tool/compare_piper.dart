import 'dart:convert';
import 'dart:io';

import 'package:lector_amoba/audio_validation.dart';
import 'package:lector_amoba/markdown_speech_service.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Benchmark only: does not change the app's selected model or voice.
void main(List<String> args) {
  final directory = args[0];
  final label = args[1];
  final output = Directory('samples/benchmark/$label')
    ..createSync(recursive: true);
  final clock = Stopwatch()..start();
  sherpa.initBindings();
  final engine = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: '$directory/es_MX-ald-medium.onnx',
          tokens: '$directory/tokens.txt',
          dataDir: '$directory/espeak-ng-data',
        ),
        numThreads: 2,
      ),
      maxNumSenetences: 1,
      silenceScale: 0.6,
    ),
  );
  final loadMs = clock.elapsedMilliseconds;
  final texts = [
    'Hola a todos. ¿Cómo está el niño? El viaje cuesta 25 dólares.',
    '¿Quién está ahí? Él dijo: mañana salimos a las ocho.',
    ...MarkdownSpeechService()
        .parse(File('samples/prueba.md').readAsStringSync())
        .take(6)
        .map((x) => x.text),
  ];
  final results = <Map<String, Object?>>[];
  try {
    for (var i = 0; i < texts.length; i++) {
      clock.reset();
      final speed = [1.0, 0.8, 1.2][i % 3];
      final audio = engine.generate(text: texts[i], sid: 0, speed: speed);
      final generationMs = clock.elapsedMilliseconds;
      validateSpeechAudio(
        audio.samples,
        audio.sampleRate,
        expectedSampleRate: 22050,
      );
      final samples = smoothSpeechEdges(audio.samples, audio.sampleRate);
      final filename = '${output.path}/$i.wav';
      if (!sherpa.writeWave(
        filename: filename,
        samples: samples,
        sampleRate: audio.sampleRate,
      )) {
        throw StateError('No se pudo guardar $filename');
      }
      final seconds = samples.length / audio.sampleRate;
      final row = <String, Object?>{
        'text': texts[i],
        'speed': speed,
        'file': filename,
        'generationMs': generationMs,
        'audioSeconds': seconds,
        'rtf': generationMs / 1000 / seconds,
      };
      results.add(row);
      stdout.writeln('$label $i: ${generationMs}ms RTF=${row['rtf']}');
    }
    Directory('docs').createSync();
    File('docs/benchmark-$label.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'label': label,
        'modelBytes': File('$directory/es_MX-ald-medium.onnx').lengthSync(),
        'loadMs': loadMs,
        'rssBytes': ProcessInfo.currentRss,
        'peakRssBytes': ProcessInfo.maxRss,
        'scope': 'Mac CPU, 2 threads; different voice/model, quality requires listening; not installed in app',
        'samples': results,
      }),
    );
  } finally {
    engine.free();
  }
}
