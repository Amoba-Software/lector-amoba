import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'engine_config.dart';
import 'audio_validation.dart';

abstract class SpeechEngine {
  Future<void> prepare();
  Future<String> synthesize(
    String text,
    int voice,
    double speed,
    bool heading,
    bool Function() valid,
  );
  Future<void> dispose();
}

class TtsService implements SpeechEngine {
  TtsService(this.cache);
  final Directory cache;
  final _responses = ReceivePort();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _ready = Completer<SendPort>();
  final _inFlight = <String, Future<String>>{};
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  int _id = 0;
  bool _disposed = false;

  @override
  Future<void> prepare() => initialize();

  Future<void> initialize() => _initialization ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) {
    _initialization = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    if (_commands != null) {
      await _request({'type': 'load'}).timeout(const Duration(minutes: 2));
      return;
    }
    await cache.create(recursive: true);
    final directory = await const MethodChannel('ec.amoba.lector/model')
        .invokeMethod<String>('prepareModel');
    if (directory == null) {
      throw StateError('No se encontraron los recursos de Kokoro.');
    }
    _responses.listen((message) {
      if (message is SendPort) {
        _ready.complete(message);
      } else {
        final result = Map<String, dynamic>.from(message as Map);
        final completer = _pending.remove(result['id']);
        if (result['error'] != null) {
          completer?.completeError(StateError(result['error'] as String));
        } else {
          completer?.complete(result);
        }
      }
    });
    _isolate = await Isolate.spawn(_worker, [_responses.sendPort, directory]);
    _commands = await _ready.future.timeout(const Duration(seconds: 30));
    await _request({'type': 'load'}).timeout(const Duration(minutes: 2));
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> message) {
    final id = _id++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _commands!.send({...message, 'id': id});
    return completer.future;
  }

  @override
  Future<String> synthesize(
    String text,
    int voice,
    double speed,
    bool heading,
    bool Function() valid,
  ) async {
    if (_disposed || !valid()) throw StateError('Lectura cancelada.');
    final key = sha256
        .convert(
          utf8.encode(
            '$modelVersion|$audioPipelineVersion|$voice|$speed|$heading|$text',
          ),
        )
        .toString();
    final path = '${cache.path}/$key.wav';
    final cached = File(path);
    if (await cached.exists()) {
      await cached.setLastModified(DateTime.now());
      return path;
    }
    final existing = _inFlight[key];
    if (existing != null) {
      try {
        return await existing;
      } catch (_) {
        if (_disposed || !valid()) rethrow;
        return synthesize(text, voice, speed, heading, valid);
      }
    }
    final completer = Completer<String>();
    _inFlight[key] = completer.future;
    final work = _tail.then((_) async {
      try {
        if (_disposed || !valid()) throw StateError('Lectura cancelada.');
        await initialize();
        if (_disposed || !valid()) throw StateError('Lectura cancelada.');
        final result = await _request({
          'type': 'generate',
          'text': text,
          'voice': voice,
          'speed': speed,
          'heading': heading,
          'path': path,
        });
        await _recordMetrics(result);
        await _trim(path);
        completer.complete(path);
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _inFlight.remove(key);
      }
    });
    _tail = work.catchError((Object _) {});
    return completer.future;
  }

  Future<void> _recordMetrics(Map<String, dynamic> result) async {
    final current = File('${cache.path}/metrics.jsonl');
    if (await current.exists() && await current.length() >= 2 * 1024 * 1024) {
      final previous = File('${cache.path}/metrics.previous.jsonl');
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    await current.writeAsString(
      '${jsonEncode({'at': DateTime.now().toIso8601String(), ...result})}\n',
      mode: FileMode.append,
    );
  }

  Future<void> _trim(String keep) async {
    final files = await cache
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.wav'))
        .cast<File>()
        .toList();
    final stats = <String, FileStat>{};
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      stats[file.path] = stat;
      total += stat.size;
    }
    files.sort(
      (a, b) => stats[a.path]!.modified.compareTo(stats[b.path]!.modified),
    );
    for (final file in files) {
      if (total <= 100 * 1024 * 1024) break;
      if (file.path == keep) continue;
      total -= stats[file.path]!.size;
      await file.delete();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _initialization?.catchError((Object _) {});
    await _tail;
    if (_commands != null) await _request({'type': 'close'});
    _isolate?.kill();
    _responses.close();
  }
}

void _worker(List<Object> arguments) {
  final replies = arguments[0] as SendPort;
  final directory = arguments[1] as String;
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  sherpa.OfflineTts? engine;
  requests.listen((message) {
    final request = Map<String, dynamic>.from(message as Map);
    final id = request['id'];
    try {
      if (request['type'] == 'load') {
        final clock = Stopwatch()..start();
        sherpa.initBindings();
        engine?.free();
        final settings = File('$directory/onnx-session.config')
          ..writeAsStringSync(onnxSessionSettings);
        engine = sherpa.OfflineTts(
          engineConfig(directory, settings: settings.path),
        );
        if (engine!.numSpeakers != expectedNativeSpeakers) {
          throw StateError('El modelo instalado no coincide con las voces.');
        }
        replies.send({'id': id, 'loadMs': clock.elapsedMilliseconds});
      } else if (request['type'] == 'close') {
        engine?.free();
        replies.send({'id': id});
        requests.close();
      } else {
        final clock = Stopwatch()..start();
        final audio = engine!.generateWithConfig(
          text: request['text'] as String,
          config: generationConfig(
            request['voice'] as int,
            request['speed'] as double,
          ),
        );
        final generationMs = clock.elapsedMilliseconds;
        validateSpeechAudio(
          audio.samples,
          audio.sampleRate,
          expectedSampleRate: engineSampleRate,
        );
        var samples = prepareSpeechAudio(audio.samples, audio.sampleRate);
        validateSpeechAudio(
          samples,
          audio.sampleRate,
          expectedSampleRate: engineSampleRate,
        );
        if (request['heading'] == true) {
          final padding = (audio.sampleRate * 0.25).round();
          final speech = samples;
          samples = Float32List(speech.length + 2 * padding)
            ..setRange(padding, padding + speech.length, speech);
        }
        final path = request['path'] as String;
        if (!sherpa.writeWave(
          filename: '$path.tmp',
          samples: samples,
          sampleRate: audio.sampleRate,
        )) {
          throw StateError('No se pudo guardar el audio.');
        }
        File('$path.tmp').renameSync(path);
        final seconds = samples.length / audio.sampleRate;
        replies.send({
          'id': id,
          'model': modelVersion,
          'pipeline': audioPipelineVersion,
          'voice': request['voice'],
          'textCharacters': (request['text'] as String).length,
          'speed': request['speed'],
          'path': path,
          'generationMs': generationMs,
          'audioProcessingMs': clock.elapsedMilliseconds - generationMs,
          'audioSeconds': seconds,
          'rtf': generationMs / 1000 / seconds,
          'rssBytes': ProcessInfo.currentRss,
          'peakRssBytes': ProcessInfo.maxRss,
        });
      }
    } catch (error) {
      replies.send({'id': id, 'error': error.toString()});
    }
  });
}
