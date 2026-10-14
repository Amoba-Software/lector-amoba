import 'dart:convert';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:lector_amoba/engine_config.dart';
import 'package:lector_amoba/markdown_speech_service.dart';

void main(List<String> args) {
  sherpa.initBindings();
  final clock = Stopwatch()..start();
  final tts = sherpa.OfflineTts(engineConfig(args.first));
  final loadMs = clock.elapsedMilliseconds;
  final results = <Map<String, Object>>[];
  Directory('samples').createSync();
  try {
    for (final voice in readerVoices.keys) {
      final english = voiceLanguage(voice) == ReadingLanguage.en;
      for (final entry in {
        'fijo': english
            ? 'Hello there. How is the kid doing? The trip costs 25 dollars. We leave tomorrow at eight.'
            : 'Hola a todos. ¿Cómo está el niño? El viaje a Guayaquil cuesta 25 dólares. Amoba utiliza IA. Mañana salimos a las ocho.',
        if (!english)
          'markdown': MarkdownSpeechService()
              .parse(File('samples/prueba.md').readAsStringSync())
              .take(3)
              .map((chunk) => chunk.text)
              .join(' '),
      }.entries) {
        clock.reset();
        final audio = tts.generateWithConfig(
          text: entry.value,
          config: generationConfig(voice, 1.0),
        );
        final elapsed = clock.elapsedMilliseconds;
        if (audio.samples.isEmpty ||
            audio.sampleRate != 24000 ||
            audio.samples.any((sample) => !sample.isFinite) ||
            !audio.samples.any((sample) => sample.abs() > 0.01)) {
          throw StateError('Audio inválido para la voz $voice');
        }
        final filename =
            'samples/${readerVoices[voice]!.name.toLowerCase()}-${entry.key}.wav';
        if (!sherpa.writeWave(
          filename: filename,
          samples: audio.samples,
          sampleRate: audio.sampleRate,
        )) {
          throw StateError('No se pudo guardar $filename');
        }
        final seconds = audio.samples.length / audio.sampleRate;
        results.add({
          'voice': voice,
          'file': filename,
          'generationMs': elapsed,
          'audioSeconds': seconds,
          'rtf': elapsed / 1000 / seconds,
        });
      }
    }
    final report = {
      'platform': Platform.operatingSystem,
      'scope': 'Prueba local; no valida calidad ni rendimiento Android',
      'model': modelVersion,
      'numSpeakers': tts.numSpeakers,
      'loadMs': loadMs,
      'rssBytes': ProcessInfo.currentRss,
      'peakRssBytes': ProcessInfo.maxRss,
      'samples': results,
    };
    Directory('docs').createSync();
    File('docs/probe.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    tts.free();
  }
}
