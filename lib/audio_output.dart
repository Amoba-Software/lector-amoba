import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

abstract class AudioOutput {
  Stream<void> get completed;
  Stream<void> get interruptions;
  Stream<String> get errors;
  Stream<void> get resumes;

  /// Previous (-1) or next (+1) fragment requested from outside the app.
  Stream<int> get skips;

  /// Reading stopped from the notification.
  Stream<void> get remoteStops;
  Future<void> load(String path, {String title = '', String detail = ''});
  Future<void> play();
  Future<void> pause();

  /// Stops the audio. [release] also ends the media session and its
  /// notification; navigation keeps them so the service is not restarted.
  Future<void> stop({bool release = false});
  Future<void> rewind();
  Future<void> keepAwake(bool value);
  Future<void> dispose();
}

enum RemoteCommand { play, pause, stop, next, previous }

/// Media session behind the notification, lock screen and headset buttons.
/// It only relays commands; the reader decides what they do.
class ReaderAudioHandler extends BaseAudioHandler {
  final player = AudioPlayer(handleInterruptions: false);
  final _commands = StreamController<RemoteCommand>.broadcast();
  Stream<RemoteCommand> get commands => _commands.stream;

  @override
  Future<void> play() async => _commands.add(RemoteCommand.play);
  @override
  Future<void> pause() async => _commands.add(RemoteCommand.pause);
  @override
  Future<void> stop() async => _commands.add(RemoteCommand.stop);
  @override
  Future<void> skipToNext() async => _commands.add(RemoteCommand.next);
  @override
  Future<void> skipToPrevious() async => _commands.add(RemoteCommand.previous);

  // Reported state follows the reader's intent, not the player: between two
  // blocks the player has finished but reading is still on, so the session
  // stays "playing" and the service keeps the foreground.
  void publish({
    required bool playing,
    required bool active,
    required bool busy,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          MediaAction.playPause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        processingState: !active
            ? AudioProcessingState.idle
            : busy
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: active && playing,
      ),
    );
  }
}

class LocalAudioOutput implements AudioOutput {
  LocalAudioOutput(this._handler);
  final ReaderAudioHandler _handler;
  AudioPlayer get _player => _handler.player;
  final _interruptions = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  static const _power = MethodChannel('ec.amoba.lector/power');
  AudioSession? _session;
  int _intent = 0;
  bool _expected = false;
  bool _active = false;

  void _publish() => _handler.publish(
    playing: _expected,
    active: _active,
    busy: _expected && _player.processingState != ProcessingState.ready,
  );

  Future<void> initialize() async {
    _session = await AudioSession.instance;
    await _session!.configure(const AudioSessionConfiguration.speech());
    _subscriptions.add(
      _session!.interruptionEventStream.listen((event) {
        if (event.begin) _interruptions.add(null);
      }),
    );
    _subscriptions.add(
      _session!.becomingNoisyEventStream.listen(
        (_) => _interruptions.add(null),
      ),
    );
    _subscriptions.add(
      _handler.commands
          .where((command) => command == RemoteCommand.pause)
          .listen((_) => _interruptions.add(null)),
    );
    _subscriptions.add(_player.processingStateStream.listen((_) => _publish()));
    _subscriptions.add(
      _player.errorStream.listen(
        (error) =>
            _errors.add(error.message ?? 'No se pudo reproducir el audio.'),
      ),
    );
  }

  @override
  Stream<void> get completed => _player.processingStateStream
      .where((state) => state == ProcessingState.completed)
      .map((_) {});
  @override
  Stream<void> get interruptions => _interruptions.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<void> get resumes => _handler.commands
      .where((command) => command == RemoteCommand.play)
      .map((_) {});
  @override
  Stream<int> get skips => _handler.commands
      .where(
        (command) =>
            command == RemoteCommand.next || command == RemoteCommand.previous,
      )
      .map((command) => command == RemoteCommand.next ? 1 : -1);
  @override
  Stream<void> get remoteStops => _handler.commands
      .where((command) => command == RemoteCommand.stop)
      .map((_) {});

  @override
  Future<void> load(
    String path, {
    String title = '',
    String detail = '',
  }) async {
    _active = true;
    _handler.mediaItem.add(
      MediaItem(id: 'lector', title: title, album: detail),
    );
    await _player.setFilePath(path);
  }

  @override
  Future<void> play() async {
    final intent = ++_intent;
    _expected = true;
    _publish();
    if (!await _session!.setActive(true)) {
      _expected = false;
      _publish();
      throw StateError('No se pudo obtener el foco de audio.');
    }
    if (intent != _intent) return;
    await _player.play();
  }

  @override
  Future<void> pause() {
    _intent++;
    _expected = false;
    _publish();
    return _player.pause();
  }

  @override
  Future<void> stop({bool release = false}) async {
    _intent++;
    _expected = false;
    if (release) _active = false;
    _publish();
    await _player.stop();
    await _session?.setActive(false);
  }

  @override
  Future<void> rewind() => _player.seek(Duration.zero);
  @override
  Future<void> keepAwake(bool value) =>
      _power.invokeMethod<void>('keepAwake', value);
  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _interruptions.close();
    await _errors.close();
  }
}
