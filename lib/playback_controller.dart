import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_output.dart';
import 'document_service.dart';
import 'engine_config.dart';
import 'markdown_speech_service.dart';
import 'reading_repository.dart';
import 'tts_service.dart';
import 'speech_batch.dart';
import 'language_detection.dart';
import 'speech_text.dart';

enum ReadingStatus {
  ready,
  preparing,
  generating,
  reading,
  paused,
  finished,
  error,
}

class _Prepared {
  const _Prepared(this.batch, this.path);
  final SpeechBatch batch;
  final Future<String> path;
}

class PlaybackController extends ChangeNotifier {
  PlaybackController(
    this.engine,
    this.audio,
    this.repository, {
    this.warmUp = false,
  }) {
    _subscriptions.add(
      audio.completed.listen((_) {
        if (!_wanted || status != ReadingStatus.reading) return;
        if (_batchEnd < chunks.length) {
          unawaited(_advance());
        } else {
          _wanted = false;
          status = ReadingStatus.finished;
          _changed();
          // Release the notification and the foreground once the end is read.
          unawaited(_serial(audio.pause).catchError((Object _) {}));
          unawaited(_save());
        }
      }),
    );
    _subscriptions.add(audio.interruptions.listen((_) => unawaited(pause())));
    _subscriptions.add(
      audio.skips.listen((step) {
        if (_closed || chunks.isEmpty) return;
        // Quick repeated presses add up from the last requested fragment.
        final next = ((_skipTarget ?? index) + step).clamp(
          0,
          chunks.length - 1,
        );
        _skipTarget = next;
        unawaited(
          select(next).whenComplete(() {
            if (_skipTarget == next) _skipTarget = null;
          }),
        );
      }),
    );
    _subscriptions.add(
      audio.remoteStops.listen((_) => unawaited(stop(release: true))),
    );
    // Play requested outside the app, e.g. from the media notification.
    _subscriptions.add(
      audio.resumes.listen((_) {
        if (!_wanted) unawaited(play());
      }),
    );
    _subscriptions.add(
      audio.errors.listen((message) {
        unawaited(pause());
        _fail(StateError(message));
      }),
    );
  }
  final SpeechEngine engine;
  final AudioOutput audio;
  final ReadingRepository repository;
  final bool warmUp;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  ReadingDocument? document;
  List<SpeechChunk> chunks = [];
  int index = 0;
  int voice = 28;
  double speed = 1;
  ReadingStatus status = ReadingStatus.ready;
  String? error;
  int _epoch = 0;
  int? _loaded;
  bool _wanted = false;
  bool _closed = false;
  Future<void> _audioTail = Future.value();
  Future<void>? _loading;
  int _batchEnd = 1;
  bool _awake = false;
  int? _skipTarget;
  // Last block the warm-up may prepare while nothing is playing.
  int _warmHold = -1;
  final _prepared = <int, _Prepared>{};
  final _voiceByLanguage = <ReadingLanguage, int>{};
  List<Pronunciation> pronunciations = const [];

  int get batchEnd => _loaded == index ? _batchEnd : index + 1;

  bool get wantsPlayback => _wanted;
  ReadingLanguage get language => voiceLanguage(voice);
  String get documentTitle => displayName(document?.name ?? '');

  void _changed() {
    // Keep the CPU running while reading, including synthesis gaps with the
    // screen off; released as soon as playback is no longer wanted.
    if (_awake != _wanted && !_closed) {
      _awake = _wanted;
      unawaited(audio.keepAwake(_awake).catchError((Object _) {}));
    }
    if (!_closed) notifyListeners();
  }

  void _fail(Object failure) {
    if (_closed) return;
    _wanted = false;
    error = failure.toString().replaceFirst(
      RegExp(r'^(Bad state: |FormatException: )'),
      '',
    );
    status = ReadingStatus.error;
    _changed();
  }

  Future<void> _serial(Future<void> Function() operation) {
    final result = _audioTail.then((_) => operation());
    _audioTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> restore() async {
    try {
      final snapshot = await repository.restore();
      if (snapshot == null) return;
      voice = snapshot.voice;
      speed = snapshot.speed;
      await open(snapshot.document, position: snapshot.index);
    } catch (failure) {
      _fail(failure);
    }
  }

  Future<void> open(
    ReadingDocument next, {
    int position = 0,
    bool detectLanguage = false,
  }) async {
    final stopped = stop();
    final operation = _epoch;
    final parsed = await compute(parseMarkdown, next.markdown);
    if (parsed.isEmpty) {
      throw const FormatException('El archivo no contiene texto pronunciable.');
    }
    await stopped;
    if (operation != _epoch || _closed) return;
    document = next;
    chunks = parsed;
    index = position.clamp(0, chunks.length - 1);
    status = ReadingStatus.ready;
    error = null;
    if (detectLanguage) {
      final detected = detectReadingLanguage(parsed.map((chunk) => chunk.text));
      if (detected != language && voicesFor(detected).isNotEmpty) {
        _useLanguage(detected);
      }
    }
    _changed();
    await _save();
    _warmUp();
  }

  // Load the model and synthesize the first fragment before the user presses
  // play, so the first wait happens while they are still looking at the text.
  void _warmUp() {
    if (!warmUp || chunks.isEmpty) return;
    final epoch = _epoch;
    unawaited(
      engine.prepare().then((_) {
        if (epoch != _epoch || _closed || _wanted || _loaded == index) return;
        final batch = speechBatch(chunks, index, maxChunks: 1);
        _track(batch.start, _generate(batch, epoch, voice, speed), epoch);
        // A short opening heading plays in a second or two; have the next
        // block ready too.
        if (batch.end < chunks.length) {
          final next = speechBatch(
            chunks,
            batch.end,
            maxCharacters: ((batch.text.length + 1) * 2).clamp(1, 480),
          );
          _warmHold = next.start;
          _track(next.start, _generate(next, epoch, voice, speed), epoch);
        }
      }, onError: (Object _) {}),
    );
  }

  void _useLanguage(ReadingLanguage next) {
    voice = _voiceByLanguage[next] ?? voicesFor(next).first;
  }

  Future<void> play() => _play(quick: true);

  Future<void> _play({required bool quick}) async {
    if (chunks.isEmpty || _closed) return;
    _wanted = true;
    error = null;
    if (status == ReadingStatus.finished) {
      await select(0, autoplay: true);
      return;
    }
    if (_loaded == index) {
      _prefetch(_epoch);
      status = ReadingStatus.reading;
      _changed();
      final epoch = _epoch;
      await _serial(() async {
        if (_wanted && epoch == _epoch) _launchPlay(epoch);
      });
      return;
    }
    if (_loading == null) {
      final epoch = _epoch;
      _loading = _load(epoch, quick).whenComplete(() {
        if (epoch == _epoch) _loading = null;
      });
    }
    await _loading;
  }

  void _launchPlay(int epoch) {
    unawaited(
      audio.play().catchError((Object failure) {
        if (epoch == _epoch) _fail(failure);
      }),
    );
  }

  Future<void> _load(int epoch, bool quick) async {
    final selected = index;
    final selectedVoice = voice;
    final selectedSpeed = speed;
    bool valid() => epoch == _epoch && !_closed;
    status = ReadingStatus.preparing;
    _changed();
    try {
      await engine.prepare();
      if (!valid()) return;
      status = _wanted ? ReadingStatus.generating : ReadingStatus.paused;
      _changed();
      // A cold start reads a single fragment so audio begins sooner; later
      // batches were sized by the prefetch that prepared them.
      final batch =
          _prepared[selected]?.batch ??
          speechBatch(chunks, selected, maxChunks: quick ? 1 : 4);
      final path = await _generate(batch, epoch, selectedVoice, selectedSpeed);
      if (!valid()) return;
      await _serial(() async {
        if (!valid()) return;
        await audio.load(
          path,
          title: documentTitle,
          detail: 'Fragmento ${selected + 1} de ${chunks.length}',
        );
        if (!valid()) return;
        _loaded = selected;
        _batchEnd = batch.end;
        status = _wanted ? ReadingStatus.reading : ReadingStatus.paused;
        _changed();
        if (_wanted) _launchPlay(epoch);
      });
      if (valid() && _wanted) _prefetch(epoch);
    } catch (failure) {
      if (valid()) {
        _prepared.remove(selected);
        _fail(failure);
      }
    }
  }

  Future<String> _generate(
    SpeechBatch batch,
    int epoch,
    int selectedVoice,
    double selectedSpeed,
  ) {
    final existing = _prepared[batch.start];
    if (existing != null && existing.batch.end == batch.end) {
      return existing.path;
    }
    final spoken = speakable(
      batch.text,
      voiceLanguage(selectedVoice),
      pronunciations,
    );
    final path = engine.synthesize(
      spoken.isEmpty ? batch.text : spoken,
      selectedVoice,
      selectedSpeed,
      batch.heading,
      // While paused only the block needed to resume (or the warm-up) is
      // still synthesized; queued look-ahead is dropped to save battery.
      () =>
          epoch == _epoch &&
          !_closed &&
          (_wanted || batch.start <= index || batch.start <= _warmHold),
    );
    _prepared[batch.start] = _Prepared(batch, path);
    return path;
  }

  void _track(int start, Future<String> future, int epoch) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (epoch == _epoch && identical(_prepared[start]?.path, future)) {
            _prepared.remove(start);
          }
        },
      ),
    );
  }

  void _prefetch(int epoch) {
    if (!_wanted || epoch != _epoch || _closed) return;
    _prepared.removeWhere((start, _) => start < index);
    var next = _batchEnd;
    var characters = 0;
    // Each batch holds at most twice the text of the one before it, so after a
    // cold start (often a short heading) the next audio is ready before the
    // current one ends. The queue then keeps a few minutes of audio ahead;
    // inference stays serial.
    var previous = chunks
        .sublist(index, _batchEnd.clamp(index + 1, chunks.length))
        .fold<int>(0, (sum, chunk) => sum + chunk.text.length + 1);
    for (
      var count = 0;
      count < 12 && next < chunks.length && (count < 3 || characters < 2400);
      count++
    ) {
      final batch =
          _prepared[next]?.batch ??
          speechBatch(
            chunks,
            next,
            maxCharacters: (previous * 2).clamp(1, 480),
          );
      previous = batch.text.length;
      _track(batch.start, _generate(batch, epoch, voice, speed), epoch);
      characters += batch.text.length;
      next = batch.end;
    }
  }

  Future<void> pause() async {
    _wanted = false;
    _warmHold = -1;
    if (chunks.isEmpty) return;
    status = ReadingStatus.paused;
    _changed();
    try {
      await _serial(audio.pause);
      await _save();
    } catch (failure) {
      _fail(failure);
    }
  }

  Future<void> stop({bool release = false}) async {
    _epoch++;
    _warmHold = -1;
    _prepared.clear();
    _wanted = false;
    _loaded = null;
    _loading = null;
    status = ReadingStatus.ready;
    error = null;
    _changed();
    try {
      await _serial(() => audio.stop(release: release));
      await _save();
    } catch (failure) {
      _fail(failure);
    }
  }

  Future<void> select(int next, {bool? autoplay}) async {
    if (next < 0 || next >= chunks.length) return;
    final resume = autoplay ?? _wanted;
    final stopped = stop();
    final operation = _epoch;
    await stopped;
    if (operation != _epoch || _closed) return;
    index = next;
    _changed();
    await _save();
    if (resume) await play();
  }

  // Natural completion keeps audio focus and the prefetch session alive.
  // Explicit navigation still cancels generation and releases the old audio.
  Future<void> _advance() async {
    final operation = _epoch;
    index = _batchEnd;
    _loaded = null;
    _loading = null;
    status = ReadingStatus.preparing;
    _changed();
    await _save();
    if (operation == _epoch && !_closed && _wanted) await _play(quick: false);
  }

  Future<void> configure({int? newVoice, double? newSpeed}) async {
    final resume = _wanted;
    final stopped = stop();
    final operation = _epoch;
    await stopped;
    if (operation != _epoch || _closed) return;
    if (newVoice != null && readerVoices.containsKey(newVoice)) {
      voice = newVoice;
      _voiceByLanguage[voiceLanguage(newVoice)] = newVoice;
    }
    if (newSpeed != null && [0.8, 1.0, 1.2, 1.5].contains(newSpeed)) {
      speed = newSpeed;
    }
    _changed();
    await _save();
    if (resume) {
      await play();
    } else {
      _warmUp();
    }
  }

  /// New rules apply from the current fragment, which is synthesized again.
  Future<void> setPronunciations(List<Pronunciation> rules) async {
    pronunciations = List.unmodifiable(rules);
    await configure();
  }

  Future<void> _save() async {
    final current = document;
    if (current == null) return;
    try {
      await repository.save(
        ReadingSnapshot(current, index, voice, speed, total: chunks.length),
      );
    } catch (failure) {
      _fail(failure);
    }
  }

  Future<void> close() async {
    await pause();
    _closed = true;
    await audio.keepAwake(false).catchError((Object _) {});
    _epoch++;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await audio.dispose();
    await engine.dispose();
    super.dispose();
  }
}
