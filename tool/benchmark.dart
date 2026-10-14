import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:lector_amoba/audio_validation.dart';
import 'package:lector_amoba/engine_config.dart';
import 'package:lector_amoba/markdown_speech_service.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main(List<String> args) {
  final directory = args[0];
  final label = args[1];
  final threads = args.length > 3 ? int.parse(args[3]) : 2;
  final caseCount = args.length > 4 ? int.parse(args[4]) : 8;
  final profileFile = File('$directory/profile.json');
  final profile = profileFile.existsSync()
      ? jsonDecode(profileFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  final output = Directory('samples/benchmark/$label')
    ..createSync(recursive: true);
  final chunks = MarkdownSpeechService().parse(
    File(args[2]).readAsStringSync(),
  );
  final cases = <String>[
    'Hola a todos. ¿Cómo está el niño? El viaje cuesta 25 dólares.',
    '¿Quién está ahí? Él dijo: mañana salimos a las ocho.',
    ...chunks.take(6).map((chunk) => chunk.text),
  ];
  sherpa.initBindings();
  final clock = Stopwatch()..start();
  final engine = sherpa.OfflineTts(engineConfig(directory, threads: threads));
  final loadMs = clock.elapsedMilliseconds;
  final results = <Map<String, Object?>>[];
  try {
    for (final voice in voicesFor(ReadingLanguage.es)) {
      final sid = profile.isEmpty
          ? voice
          : (profile['voices'] as Map)['$voice'] as int;
      for (var i = 0; i < math.min(caseCount, cases.length); i++) {
        final speed = [1.0, 0.8, 1.2][i % 3];
        clock.reset();
        final audio = engine.generateWithConfig(
          text: cases[i],
          config: sherpa.OfflineTtsGenerationConfig(
            sid: sid,
            speed: speed,
            silenceScale: engineSilenceScale,
            extra: {'lang': voiceLanguage(voice).espeak},
          ),
        );
        final elapsed = clock.elapsedMilliseconds;
        String? error;
        try {
          validateSpeechAudio(audio.samples, audio.sampleRate);
        } catch (failure) {
          error = failure.toString();
        }
        final filename = '${output.path}/$voice-$i.wav';
        if (!sherpa.writeWave(
          filename: filename,
          samples: audio.samples,
          sampleRate: audio.sampleRate,
        )) {
          throw StateError('No se pudo guardar $filename');
        }
        final seconds = audio.samples.length / audio.sampleRate;
        final energy = audio.samples.fold(0.0, (sum, x) => sum + x * x);
        final item = <String, Object?>{
          'voice': voice,
          'nativeVoice': sid,
          'text': cases[i],
          'speed': speed,
          'file': filename,
          'generationMs': elapsed,
          'audioSeconds': seconds,
          'rtf': elapsed / 1000 / seconds,
          'rms': math.sqrt(energy / audio.samples.length),
          'error': error,
        };
        results.add(item);
        stdout.writeln(
          '$label $voice/$i: ${elapsed}ms RTF=${item['rtf']} ${error ?? 'OK'}',
        );
      }
    }
    final report = {
      'platform': Platform.operatingSystem,
      'label': label,
      'profile': profile,
      'scope': 'Mac ARM64; validity checks do not certify perceptual quality or physical Android performance',
      'loadMs': loadMs,
      'threads': threads,
      'numSpeakers': engine.numSpeakers,
      'rssBytes': ProcessInfo.currentRss,
      'peakRssBytes': ProcessInfo.maxRss,
      'samples': results,
    };
    Directory('docs').createSync();
    File('docs/benchmark-$label.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  } finally {
    engine.free();
  }
}
