import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_output.dart';
import 'document_service.dart';
import 'document_preview.dart';
import 'engine_config.dart';
import 'playback_controller.dart';
import 'reading_repository.dart';
import 'markdown_speech_service.dart';
import 'reader_theme.dart';
import 'speech_text.dart';
import 'tts_service.dart';

late final ReaderAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final font = FontLoader('Nunito')
    ..addFont(rootBundle.load('assets/fonts/Nunito.ttf'));
  await font.load();
  audioHandler = await AudioService.init(
    builder: ReaderAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'ec.amoba.lector.channel.audio',
      androidNotificationChannelName: 'Lectura',
      androidNotificationIcon: 'drawable/ic_stat_reader',
    ),
  );
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      [piperTrial ? 'Piper Ald — ficha del modelo' : 'Kokoro-82M'],
      await rootBundle.loadString(
        piperTrial ? 'assets/model/MODEL_CARD' : 'assets/model/LICENSE',
      ),
    );
    yield LicenseEntryWithLineBreaks([
      'Nunito',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'espeak-ng',
    ], await rootBundle.loadString('assets/licenses/espeak-ng-COPYING'));
  });
  runApp(const LectorApp());
}

class LectorApp extends StatefulWidget {
  const LectorApp({super.key});
  @override
  State<LectorApp> createState() => _LectorAppState();
}

class _LectorAppState extends State<LectorApp> {
  ThemeMode _mode = ThemeMode.system;
  ThemePreferences? _preferences;
  bool _chosen = false;
  @override
  void initState() {
    super.initState();
    unawaited(_restoreAppearance());
  }

  Future<void> _restoreAppearance() async {
    try {
      final preferences = ThemePreferences(
        await getApplicationSupportDirectory(),
      );
      _preferences = preferences;
      if (_chosen) {
        await preferences.save(_mode);
        return;
      }
      final mode = await preferences.load();
      if (mounted && !_chosen) setState(() => _mode = mode);
    } catch (error) {
      debugPrint('No se pudo restaurar la apariencia: $error');
    }
  }

  void _setTheme(ThemeMode mode) {
    _chosen = true;
    setState(() => _mode = mode);
    unawaited(
      _preferences?.save(mode).catchError((Object error) {
        debugPrint('No se pudo guardar la apariencia: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: applicationTitle,
    theme: readerTheme(Brightness.light),
    darkTheme: readerTheme(Brightness.dark),
    themeMode: _mode,
    home: ReaderScreen(themeMode: _mode, onThemeChanged: _setTheme),
  );
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.controller,
    this.themeMode = ThemeMode.system,
    this.onThemeChanged,
  });
  final PlaybackController? controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  PlaybackController? _reader;
  DocumentService? _documents;
  TtsService? _engine;
  PronunciationRepository? _pronunciation;
  static const _intents = MethodChannel('ec.amoba.lector/intent');
  String? _initialError;
  bool _opening = false;
  bool _original = false;
  bool _diagnosing = false;
  final _scroll = ScrollController();
  List<double> _chunkHeights = [];
  int _lastIndex = -1;
  // The list follows the voice until the user scrolls away to read ahead.
  bool _following = true;
  DateTime? _sleepAt;
  Timer? _sleepTimer;
  ReaderPalette get _colors => ReaderPalette.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      _reader = widget.controller;
      _reader!.addListener(_update);
      _update();
    } else {
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final temporary = await getTemporaryDirectory();
      final audio = LocalAudioOutput(audioHandler);
      await audio.initialize();
      final engine = TtsService(Directory('${temporary.path}/audio'));
      final reader = PlaybackController(
        engine,
        audio,
        ReadingRepository(directory),
        warmUp: true,
      );
      final pronunciation = PronunciationRepository(directory);
      reader.pronunciations = await pronunciation.load();
      _pronunciation = pronunciation;
      await reader.restore();
      if (!mounted) {
        await reader.close();
        return;
      }
      _engine = engine;
      _documents = DocumentService(Directory('${directory.path}/documents'));
      _reader = reader;
      reader.addListener(_update);
      _initialError = null;
      _update();
      _intents.setMethodCallHandler((call) async {
        if (call.method == 'documentAvailable') await _takeShared();
      });
      await _takeShared();
    } catch (error) {
      if (mounted) setState(() => _initialError = error.toString());
    }
  }

  void _update() {
    if (!mounted) return;
    setState(() {});
    final reader = _reader!;
    if (_lastIndex != reader.index && !_original) {
      _lastIndex = reader.index;
      if (_following) _scrollToCurrent();
    }
  }

  void _scrollToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final reader = _reader;
      if (!mounted || reader == null || !_scroll.hasClients) return;
      _scroll.animateTo(
        // The list's top padding already places the spoken passage at ~18%
        // of the viewport, leaving the previous lines in view above it.
        _chunkHeights
            .take(reader.index)
            .fold<double>(0, (sum, h) => sum + h)
            .clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _follow() {
    setState(() => _following = true);
    _scrollToCurrent();
  }

  void _setSleep(Duration? delay) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    setState(() => _sleepAt = delay == null ? null : DateTime.now().add(delay));
    if (delay == null) return;
    _sleepTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      final at = _sleepAt;
      if (at == null || !mounted) {
        timer.cancel();
      } else if (!DateTime.now().isBefore(at)) {
        timer.cancel();
        unawaited(_reader?.pause());
        setState(() => _sleepAt = null);
      } else {
        setState(() {});
      }
    });
  }

  void _showSleep() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Pausar la lectura en',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            for (final minutes in [15, 30, 45, 60])
              ListTile(
                leading: Icon(Icons.bedtime_outlined),
                title: Text('$minutes minutos'),
                onTap: () {
                  Navigator.pop(context);
                  _setSleep(Duration(minutes: minutes));
                },
              ),
            if (_sleepAt != null)
              ListTile(
                leading: Icon(Icons.timer_off_outlined),
                title: Text('Desactivar temporizador'),
                onTap: () {
                  Navigator.pop(context);
                  _setSleep(null);
                },
              ),
            SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  String _duration(Duration value) {
    final minutes = (value.inSeconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    final rest = minutes % 60;
    return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
  }

  // Kokoro reads about 13 characters per second at 1×; an estimate only.
  Duration _remaining(PlaybackController reader) => Duration(
    seconds:
        (reader.chunks
                    .skip(reader.index)
                    .fold<int>(0, (sum, chunk) => sum + chunk.text.length + 1) /
                (13 * reader.speed))
            .round(),
  );

  // Reading continues with the screen off or in another app; the
  // media notification controls it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(_reader?.pause());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reader?.removeListener(_update);
    if (widget.controller == null) unawaited(_reader?.close());
    _sleepTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _opening = true);
    await _reader!.pause();
    try {
      final document = await _documents!.pick();
      if (document != null) await _openDocument(document);
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// A file opened with, or text shared to, the app from elsewhere.
  Future<void> _takeShared() async {
    final data = await _intents.invokeMapMethod<String, Object?>(
      'takeDocument',
    );
    if (data == null || !mounted || _reader == null) return;
    if (data['error'] != null) {
      _message(data['error'] as String);
      return;
    }
    setState(() => _opening = true);
    await _reader!.pause();
    try {
      await _openDocument(
        await _documents!.importBytes(
          data['name'] as String,
          data['bytes'] as Uint8List,
        ),
      );
    } catch (error) {
      _message(error.toString().replaceFirst('FormatException: ', ''));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  // A document read before resumes where it was left.
  Future<void> _openDocument(ReadingDocument document) async {
    final reader = _reader!;
    final saved = (await reader.repository.library()).where(
      (entry) => entry.hash == document.hash,
    );
    await reader.open(
      document,
      position: saved.isEmpty ? 0 : saved.first.index,
      detectLanguage: true,
    );
  }

  Future<void> _openEntry(LibraryEntry entry) async {
    final reader = _reader!;
    setState(() => _opening = true);
    await reader.pause();
    try {
      await reader.open(
        await reader.repository.load(entry),
        position: entry.index,
        detectLanguage: true,
      );
    } catch (error) {
      _message('No se pudo abrir ${displayName(entry.name)}.');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _showLibrary(PlaybackController reader) async {
    var entries = await reader.repository.library();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => StatefulBuilder(
          builder: (context, refresh) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: FilledButton.icon(
                  onPressed: _documents == null
                      ? null
                      : () {
                          Navigator.pop(context);
                          unawaited(_open());
                        },
                  icon: Icon(Icons.add_rounded),
                  label: Text('Abrir documento'),
                ),
              ),
              if (entries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                  child: Text(
                    'Recientes',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: _colors.muted,
                    ),
                  ),
                ),
              for (final entry in entries)
                () {
                  final current = entry.hash == reader.document?.hash;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    selected: current,
                    selectedColor: _colors.primary,
                    leading: Icon(
                      current
                          ? Icons.graphic_eq_rounded
                          : Icons.article_outlined,
                    ),
                    title: Text(
                      displayName(entry.name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      current
                          ? 'Escuchando ahora'
                          : entry.total == 0
                          ? 'Sin empezar'
                          : 'Fragmento ${entry.index + 1} de ${entry.total}',
                    ),
                    trailing: current
                        ? null
                        : IconButton(
                            tooltip: 'Quitar ${displayName(entry.name)}',
                            icon: Icon(Icons.close_rounded),
                            onPressed: () async {
                              await reader.repository.forget(entry.hash);
                              entries = await reader.repository.library();
                              refresh(() {});
                            },
                          ),
                    onTap: current || _opening || _diagnosing
                        ? null
                        : () {
                            Navigator.pop(context);
                            unawaited(_openEntry(entry));
                          },
                  );
                }(),
            ],
          ),
        ),
      ),
    );
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _diagnose() async {
    final engine = _engine!;
    setState(() => _diagnosing = true);
    await _reader!.stop();
    try {
      final clock = Stopwatch()..start();
      await engine.initialize();
      final loadMs = clock.elapsedMilliseconds;
      final results = <Map<String, Object>>[];
      for (final voice in readerVoices.keys) {
        clock.reset();
        final path = await engine.synthesize(
          voiceLanguage(voice) == ReadingLanguage.en
              ? 'Hello there. How is the kid doing? The trip costs 25 dollars.'
              : 'Hola a todos. ¿Cómo está el niño? El viaje cuesta 25 dólares.',
          voice,
          1.0,
          false,
          () => mounted,
        );
        final bytes = await File(path).readAsBytes();
        final view = ByteData.sublistView(bytes);
        final duration =
            (bytes.length - 44) / view.getUint32(28, Endian.little);
        results.add({
          'voice': readerVoices[voice]!.name,
          'elapsedMs': clock.elapsedMilliseconds,
          'audioSeconds': duration,
        });
      }
      final report = const JsonEncoder.withIndent('  ').convert({
        'platform': Platform.operatingSystem,
        'model': modelVersion,
        'loadMs': loadMs,
        'rssBytes': ProcessInfo.currentRss,
        'peakRssBytes': ProcessInfo.maxRss,
        'results': results,
        'note':
            'La caché puede reducir elapsedMs. Inferencia real en inference.',
        'inference': await File('${engine.cache.path}/metrics.jsonl').exists()
            ? await File('${engine.cache.path}/metrics.jsonl').readAsString()
            : '',
      });
      await FilePicker.saveFile(
        dialogTitle: 'Guardar diagnóstico',
        fileName: 'lector-diagnostico.json',
        bytes: Uint8List.fromList(utf8.encode(report)),
      );
      _message(
        'Prueba terminada. Abre el documento de prueba para escuchar ambas voces.',
      );
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _diagnosing = false);
    }
  }

  void _showSource(String source) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Texto fuente',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SelectionArea(
                    child: Text(
                      source,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAppearance() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Apariencia',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            for (final entry in {
              ThemeMode.system: 'Usar tema del teléfono',
              ThemeMode.light: 'Claro',
              ThemeMode.dark: 'Oscuro',
            }.entries)
              ListTile(
                title: Text(entry.value),
                leading: Icon(
                  entry.key == ThemeMode.dark
                      ? Icons.dark_mode_outlined
                      : entry.key == ThemeMode.light
                      ? Icons.light_mode_outlined
                      : Icons.brightness_auto_outlined,
                ),
                trailing: widget.themeMode == entry.key
                    ? Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  widget.onThemeChanged?.call(entry.key);
                },
              ),
            SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  String _speed(double value) =>
      '${value.toString().replaceAll('.0', '').replaceAll('.', ',')}×';

  void _toggleOriginal() {
    _original = !_original;
    _following = true;
    _lastIndex = -1;
    _update();
  }

  void _showVoices(PlaybackController reader) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: reader,
          builder: (context, _) {
            final disabled = _opening || _diagnosing;
            Widget title(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: _colors.muted,
                ),
              ),
            );
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final language in ReadingLanguage.values)
                    if (voicesFor(language).isNotEmpty) ...[
                      title(language.label),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final voice in voicesFor(language))
                              ChoiceChip(
                                label: Text(readerVoices[voice]!.name),
                                selected: reader.voice == voice,
                                showCheckmark: false,
                                labelStyle: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: reader.voice == voice
                                      ? _colors.onPrimary
                                      : _colors.ink,
                                ),
                                selectedColor: _colors.primary,
                                backgroundColor: _colors.tint,
                                side: BorderSide.none,
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                onSelected: disabled
                                    ? null
                                    : (_) => unawaited(
                                        reader.configure(newVoice: voice),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  title('Velocidad'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<double>(
                        showSelectedIcon: false,
                        segments: [
                          for (final speed in [0.8, 1.0, 1.2, 1.5])
                            ButtonSegment(
                              value: speed,
                              label: Text(_speed(speed)),
                            ),
                        ],
                        selected: {reader.speed},
                        onSelectionChanged: disabled
                            ? null
                            : (value) => unawaited(
                                reader.configure(newSpeed: value.first),
                              ),
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    leading: Icon(Icons.bedtime_outlined),
                    title: Text(
                      _sleepAt == null
                          ? 'Temporizador'
                          : 'Se pausa en ${_duration(_sleepAt!.difference(DateTime.now()))}',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showSleep();
                    },
                  ),
                  SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showSections(PlaybackController reader) {
    final sections = [
      for (var i = 0; i < reader.chunks.length; i++)
        if (reader.chunks[i].heading) i,
    ];
    final current = sections.lastWhere(
      (index) => index <= reader.index,
      orElse: () => -1,
    );
    final currentKey = GlobalKey();
    var centered = false;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => sections.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Este documento no tiene títulos para saltar entre secciones.',
                  style: TextStyle(color: _colors.muted, fontSize: 16),
                ),
              )
            : ListView(
                controller: scroll,
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  for (final index in sections)
                    () {
                      final here = index == current;
                      if (here && !centered) {
                        centered = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          final target = currentKey.currentContext;
                          if (target != null && target.mounted) {
                            Scrollable.ensureVisible(target, alignment: 0.3);
                          }
                        });
                      }
                      return ListTile(
                        key: here ? currentKey : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                        ),
                        selected: here,
                        selectedColor: _colors.primary,
                        leading: here
                            ? Icon(Icons.graphic_eq_rounded)
                            : SizedBox(width: 24),
                        title: Text(
                          reader.chunks[index].text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: here
                                ? FontWeight.w900
                                : FontWeight.w700,
                          ),
                        ),
                        onTap: _opening || _diagnosing
                            ? null
                            : () {
                                Navigator.pop(context);
                                _following = true;
                                unawaited(reader.select(index));
                              },
                      );
                    }(),
                ],
              ),
      ),
    );
  }

  void _showPronunciation(PlaybackController reader) {
    final written = TextEditingController();
    final spoken = TextEditingController();
    var rules = [...reader.pronunciations];
    Future<void> commit(List<Pronunciation> next) async {
      rules = next;
      try {
        await _pronunciation?.save(next);
      } catch (error) {
        _message('No se pudo guardar la pronunciación: $error');
      }
      await reader.setPronunciations(next);
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Pronunciación',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Cuando aparezca la palabra escrita, la voz dirá lo otro. '
                    'Por ejemplo: MVP → eme ve pe.',
                    style: TextStyle(color: _colors.muted, height: 1.4),
                  ),
                  SizedBox(height: 16),
                  for (final rule in rules)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        rule.written,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text('se dice «${rule.spoken}»'),
                      trailing: IconButton(
                        tooltip: 'Quitar ${rule.written}',
                        icon: Icon(Icons.close_rounded),
                        onPressed: () async {
                          await commit([...rules]..remove(rule));
                          refresh(() {});
                        },
                      ),
                    ),
                  TextField(
                    controller: written,
                    decoration: InputDecoration(labelText: 'Se escribe'),
                    textInputAction: TextInputAction.next,
                  ),
                  SizedBox(height: 8),
                  TextField(
                    controller: spoken,
                    decoration: InputDecoration(labelText: 'Se dice'),
                  ),
                  SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      final from = written.text.trim();
                      final to = spoken.text.trim();
                      if (from.isEmpty || to.isEmpty) return;
                      await commit([
                        ...rules.where(
                          (rule) =>
                              rule.written.toLowerCase() != from.toLowerCase(),
                        ),
                        Pronunciation(from, to),
                      ]);
                      written.clear();
                      spoken.clear();
                      refresh(() {});
                    },
                    icon: Icon(Icons.add_rounded),
                    label: Text('Añadir'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      written.dispose();
      spoken.dispose();
    });
  }

  Widget _empty(bool disabled) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'Escucha tus documentos.',
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                  letterSpacing: -1.5,
                  color: _colors.ink,
                ),
              ),
              SizedBox(height: 20),
              Text(
                'Abre un Markdown o un Word y Kokoro lo lee en español o inglés, '
                'sin conexión y con la pantalla apagada.',
                style: TextStyle(
                  fontSize: 18,
                  height: 1.55,
                  color: _colors.muted,
                ),
              ),
              SizedBox(height: 40),
              FilledButton.icon(
                onPressed: disabled || _documents == null ? null : _open,
                icon: Icon(Icons.add_rounded),
                label: Text(_opening ? 'Abriendo…' : 'Abrir documento'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  // The passage being spoken is larger and fully lit; what was read fades
  // back and what comes next waits at half light.
  TextStyle _chunkStyle(bool heading, bool current, bool past) => TextStyle(
    fontFamily: 'Nunito',
    fontSize: current ? (heading ? 27 : 23) : (heading ? 21 : 18),
    height: current ? 1.42 : 1.6,
    fontWeight: heading
        ? FontWeight.w900
        : current
        ? FontWeight.w700
        : FontWeight.w500,
    letterSpacing: current ? -0.2 : 0,
    color: _colors.ink.withValues(alpha: current ? 1 : (past ? 0.3 : 0.55)),
  );

  static const _gutter = 28.0;
  static const _rule = 3.0;
  static const _ruleGap = 14.0;
  static const _paragraphGap = 22.0;

  List<SpeechChunk>? _measuredChunks;
  double _measuredWidth = -1;
  TextScaler? _measuredScale;
  List<double> _restingHeights = [];
  List<double> _spokenHeights = [];

  // Measure each passage once per document, width and accessibility text
  // scale, in both sizes; the extents drive restoration and automatic scroll.
  // Read and upcoming text share metrics, they only differ in color.
  void _measure(
    List<SpeechChunk> chunks,
    double width,
    TextScaler scale,
    TextDirection direction,
  ) {
    if (identical(chunks, _measuredChunks) &&
        width == _measuredWidth &&
        scale == _measuredScale) {
      return;
    }
    double height(SpeechChunk chunk, bool spoken) {
      final painter = TextPainter(
        text: TextSpan(
          text: chunk.text,
          style: _chunkStyle(chunk.heading, spoken, false),
        ),
        textDirection: direction,
        textScaler: scale,
      )..layout(maxWidth: width);
      final result = painter.height + _paragraphGap;
      painter.dispose();
      return result;
    }

    _restingHeights = [for (final chunk in chunks) height(chunk, false)];
    _spokenHeights = [for (final chunk in chunks) height(chunk, true)];
    _measuredChunks = chunks;
    _measuredWidth = width;
    _measuredScale = scale;
  }

  Widget _reading(PlaybackController reader, bool disabled) => LayoutBuilder(
    builder: (context, constraints) {
      final width = (constraints.maxWidth - 2 * _gutter - _rule - _ruleGap)
          .clamp(1.0, double.infinity);
      _measure(
        reader.chunks,
        width,
        MediaQuery.textScalerOf(context),
        Directionality.of(context),
      );
      _chunkHeights = [
        for (var index = 0; index < reader.chunks.length; index++)
          index >= reader.index && index < reader.batchEnd
              ? _spokenHeights[index]
              : _restingHeights[index],
      ];
      final list = ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(
          _gutter,
          constraints.maxHeight * 0.18,
          _gutter,
          constraints.maxHeight * 0.6,
        ),
        itemCount: reader.chunks.length,
        itemExtentBuilder: (index, _) => _chunkHeights[index],
        itemBuilder: (context, index) {
          final chunk = reader.chunks[index];
          final current = index >= reader.index && index < reader.batchEnd;
          return Padding(
            padding: const EdgeInsets.only(bottom: _paragraphGap),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: disabled
                  ? null
                  : () {
                      _following = true;
                      unawaited(reader.select(index));
                    },
              child: Semantics(
                selected: current,
                button: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      width: _rule,
                      decoration: BoxDecoration(
                        color: current ? _colors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(_rule),
                      ),
                    ),
                    SizedBox(width: _ruleGap),
                    Expanded(
                      child: ClipRect(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          style: _chunkStyle(
                            chunk.heading,
                            current,
                            index < reader.index,
                          ),
                          child: Text(chunk.text),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      return NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (_following && notification.direction != ScrollDirection.idle) {
            setState(() => _following = false);
          }
          return false;
        },
        child: list,
      );
    },
  );

  Widget _capsule(PlaybackController reader, bool disabled) {
    final finished = reader.status == ReadingStatus.finished;
    final progress = finished ? 1.0 : (reader.index + 1) / reader.chunks.length;
    final busy =
        reader.status == ReadingStatus.preparing ||
        reader.status == ReadingStatus.generating;
    final label = reader.wantsPlayback
        ? 'Pausar'
        : reader.status == ReadingStatus.error
        ? 'Reintentar'
        : 'Escuchar';
    final headline = _diagnosing
        ? 'Midiendo voces…'
        : finished
        ? 'Terminado'
        : busy && reader.wantsPlayback
        ? 'Preparando la voz…'
        : 'Quedan ${_duration(_remaining(reader))}';
    final voice = readerVoices[reader.voice]!;
    final detail = [
      availableLanguages.length > 1
          ? '${voice.name} en ${voice.language.label.toLowerCase()}'
          : voice.name,
      _speed(reader.speed),
      if (_sleepAt != null)
        'pausa en ${_duration(_sleepAt!.difference(DateTime.now()))}',
    ].join(', ');
    return Material(
      key: const ValueKey('capsule'),
      color: _colors.surface,
      shape: StadiumBorder(side: BorderSide(color: _colors.border)),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      shadowColor: _colors.primary.withValues(alpha: 0.25),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: _colors.primary,
              backgroundColor: Colors.transparent,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Fragmento anterior',
                  icon: Icon(Icons.skip_previous_rounded),
                  onPressed: disabled || reader.index == 0
                      ? null
                      : () => unawaited(reader.select(reader.index - 1)),
                ),
                SizedBox(
                  width: 60,
                  height: 60,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (busy && reader.wantsPlayback)
                        SizedBox(
                          width: 60,
                          height: 60,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: _colors.primary,
                          ),
                        ),
                      IconButton.filled(
                        tooltip: label,
                        iconSize: 30,
                        style: IconButton.styleFrom(
                          backgroundColor: _colors.primary,
                          foregroundColor: _colors.onPrimary,
                          fixedSize: const Size(52, 52),
                        ),
                        onPressed: disabled
                            ? null
                            : () => unawaited(
                                reader.wantsPlayback
                                    ? reader.pause()
                                    : reader.play(),
                              ),
                        icon: Icon(
                          reader.wantsPlayback
                              ? Icons.pause_rounded
                              : reader.status == ReadingStatus.error
                              ? Icons.refresh_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Fragmento siguiente',
                  icon: Icon(Icons.skip_next_rounded),
                  onPressed:
                      disabled || reader.index + 1 >= reader.chunks.length
                      ? null
                      : () => unawaited(reader.select(reader.index + 1)),
                ),
                SizedBox(width: 4),
                Expanded(
                  child: Tooltip(
                    message: 'Voz y velocidad',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _showVoices(reader),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              headline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: _colors.ink,
                              ),
                            ),
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _colors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuButton<String> _menu(PlaybackController? reader, bool disabled) =>
      PopupMenuButton<String>(
        tooltip: 'Opciones',
        icon: Icon(Icons.more_horiz_rounded),
        onSelected: (value) {
          if (value == 'diagnostic' && _engine != null && !disabled) {
            unawaited(_diagnose());
          }
          if (value == 'stop' && reader != null && !disabled) {
            unawaited(reader.stop(release: true));
          }
          if (value == 'appearance') _showAppearance();
          if (value == 'sleep') _showSleep();
          if (value == 'pronunciation' && reader != null) {
            _showPronunciation(reader);
          }
          if (value == 'source' && reader?.document != null) {
            _showSource(reader!.document!.markdown);
          }
          if (value == 'licenses') {
            showLicensePage(
              context: context,
              applicationName: applicationTitle,
            );
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'appearance',
            enabled: widget.onThemeChanged != null,
            child: Text('Apariencia'),
          ),
          PopupMenuItem(
            value: 'sleep',
            enabled: reader?.document != null,
            child: Text('Temporizador'),
          ),
          PopupMenuItem(
            value: 'pronunciation',
            enabled: reader != null,
            child: Text('Pronunciación'),
          ),
          PopupMenuItem(
            value: 'source',
            enabled: reader?.document != null,
            child: Text('Ver texto fuente'),
          ),
          PopupMenuItem(
            value: 'stop',
            enabled: reader != null && reader.chunks.isNotEmpty && !disabled,
            child: Text('Detener lectura'),
          ),
          PopupMenuItem(
            value: 'diagnostic',
            enabled: _engine != null && !disabled,
            child: Text('Prueba técnica'),
          ),
          const PopupMenuItem(value: 'licenses', child: Text('Licencias')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final reader = _reader;
    final disabled = _opening || _diagnosing;
    final document = reader?.document;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: _gutter - 4,
        title: document == null
            ? Text(
                'amoba',
                style: TextStyle(
                  fontSize: 26,
                  letterSpacing: -1.2,
                  fontWeight: FontWeight.w900,
                  color: _colors.primary,
                ),
              )
            : Tooltip(
                message: 'Secciones',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _showSections(reader),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            reader!.documentTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: _colors.muted,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 20,
                          color: _colors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        actions: [
          if (document != null) ...[
            IconButton(
              tooltip: _original ? 'Ver fragmentos' : 'Ver documento',
              onPressed: _toggleOriginal,
              icon: Icon(
                _original ? Icons.graphic_eq_rounded : Icons.article_outlined,
              ),
            ),
            IconButton(
              tooltip: 'Documentos',
              onPressed: disabled ? null : () => _showLibrary(reader!),
              icon: Icon(Icons.folder_open_outlined),
            ),
          ],
          _menu(reader, disabled),
          SizedBox(width: 8),
        ],
      ),
      body: reader == null
          ? Center(
              child: _initialError == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_initialError!),
                          TextButton(
                            onPressed: _initialize,
                            child: Text('Reintentar'),
                          ),
                        ],
                      ),
                    ),
            )
          : document == null
          ? SafeArea(child: _empty(disabled))
          : Stack(
              children: [
                Positioned.fill(
                  child: _original
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 96),
                          child: DocumentPreview(
                            key: PageStorageKey('preview-${document.hash}'),
                            source: document.markdown,
                          ),
                        )
                      : _reading(reader, disabled),
                ),
                // Text dissolves into the page before it reaches the capsule.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 140,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            _colors.page.withValues(alpha: 0),
                            _colors.page,
                          ],
                          stops: const [0, 0.7],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (reader.error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                            child: Text(
                              reader.error!,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (!_following && !_original)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: FilledButton.tonalIcon(
                              onPressed: _follow,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 44),
                                backgroundColor: _colors.tint,
                                foregroundColor: _colors.ink,
                              ),
                              icon: Icon(Icons.my_location_rounded, size: 18),
                              label: Text('Ir al fragmento actual'),
                            ),
                          ),
                        _capsule(reader, disabled),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
