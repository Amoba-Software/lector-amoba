import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:lector_amoba/main.dart';
import 'package:lector_amoba/audio_output.dart';
import 'package:lector_amoba/document_service.dart';
import 'package:lector_amoba/playback_controller.dart';
import 'package:lector_amoba/reading_repository.dart';
import 'package:lector_amoba/tts_service.dart';
import 'package:lector_amoba/engine_config.dart';
import 'package:lector_amoba/reader_theme.dart';

class FakeEngine implements SpeechEngine {
  @override
  Future<void> prepare() async {}
  final jobs = <Completer<String>>[];
  final voices = <int>[];
  final texts = <String>[];
  final validity = <bool Function()>[];
  @override
  Future<String> synthesize(
    String text,
    int voice,
    double speed,
    bool heading,
    bool Function() valid,
  ) {
    final job = Completer<String>();
    jobs.add(job);
    voices.add(voice);
    texts.add(text);
    validity.add(valid);
    return job.future;
  }

  @override
  Future<void> dispose() async {}
}

class FakeAudio implements AudioOutput {
  final completions = StreamController<void>.broadcast();
  final pauses = StreamController<void>.broadcast();
  final failures = StreamController<String>.broadcast();
  final files = <String>[];
  int plays = 0;
  int stops = 0;
  int position = 0;
  @override
  Stream<void> get completed => completions.stream;
  @override
  Stream<void> get interruptions => pauses.stream;
  @override
  Stream<String> get errors => failures.stream;
  final resumeRequests = StreamController<void>.broadcast();
  @override
  Stream<void> get resumes => resumeRequests.stream;
  final skipRequests = StreamController<int>.broadcast();
  @override
  Stream<int> get skips => skipRequests.stream;
  final stopRequests = StreamController<void>.broadcast();
  @override
  Stream<void> get remoteStops => stopRequests.stream;
  final awake = <bool>[];
  @override
  Future<void> keepAwake(bool value) async => awake.add(value);
  @override
  Future<void> load(
    String path, {
    String title = '',
    String detail = '',
  }) async {
    files.add(path);
    position = 0;
  }

  @override
  Future<void> play() async {
    plays++;
  }

  int pauseCalls = 0;
  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> stop({bool release = false}) async {
    stops++;
    position = 0;
  }

  @override
  Future<void> rewind() async {
    position = 0;
  }

  @override
  Future<void> dispose() async {
    await completions.close();
    await pauses.close();
    await failures.close();
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late Directory directory;
  late FakeEngine engine;
  late FakeAudio audio;
  late PlaybackController reader;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lector-playback');
    engine = FakeEngine();
    audio = FakeAudio();
    reader = PlaybackController(engine, audio, ReadingRepository(directory));
    await reader.open(
      const ReadingDocument(
        name: 'demo.md',
        hash: 'demo',
        markdown: '# Primero.\n\n# Segundo.\n\n# Tercero.',
      ),
    );
  });
  tearDown(() async {
    await reader.close();
    await directory.delete(recursive: true);
  });
  testWidgets('Restaurar y volver desde original muestra el fragmento actual', (
    tester,
  ) async {
    await tester.runAsync(
      () => reader.open(
        ReadingDocument(
          name: 'largo.md',
          hash: 'long',
          markdown: List.generate(30, (i) => 'Párrafo ${i + 1}.').join('\n\n'),
        ),
        position: 20,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(controller: reader)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Párrafo 21.'), findsOneWidget);
    expect(find.text('Párrafo 1.'), findsNothing);
    await tester.tap(find.byTooltip('Ver documento'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ver fragmentos'));
    await tester.pumpAndSettle();
    expect(find.text('Párrafo 21.'), findsOneWidget);
    expect(find.text('Párrafo 1.'), findsNothing);
  });

  testWidgets('Pantalla estrecha con letra grande conserva controles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: ReaderScreen(controller: reader),
        ),
      ),
    );
    expect(find.byTooltip('Escuchar'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Apariencia cambia a oscuro sin reiniciar el lector', (
    tester,
  ) async {
    var mode = ThemeMode.light;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          theme: readerTheme(Brightness.light),
          darkTheme: readerTheme(Brightness.dark),
          themeMode: mode,
          home: ReaderScreen(
            controller: reader,
            themeMode: mode,
            onThemeChanged: (next) => setState(() => mode = next),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Opciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apariencia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oscuro'));
    await tester.pumpAndSettle();
    expect(mode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(ReaderScreen))).brightness,
      Brightness.dark,
    );
    expect(reader.document!.name, 'demo.md');
    expect(
      tester.widget<Material>(find.byKey(const ValueKey('capsule'))).color,
      ReaderPalette.dark.surface,
    );
    expect(tester.takeException(), isNull);
  });

  test('Cambiar configuración descarta la generación anterior', () async {
    final first = reader.play();
    await settle();
    final alternativeVoice = readerVoices.containsKey(29) ? 29 : 28;
    final changed = reader.configure(
      newVoice: alternativeVoice,
      newSpeed: piperTrial ? 1.2 : null,
    );
    await settle();
    expect(engine.voices, [28, alternativeVoice]);
    engine.jobs[0].complete('antiguo.wav');
    await first;
    expect(audio.files, isEmpty);
    engine.jobs[1].complete('nuevo.wav');
    await changed;
    expect(audio.files, ['nuevo.wav']);
    expect(audio.plays, 1);
  });
  test(
    'Pausa durante generación no arranca el audio; continuar conserva posición',
    () async {
      final first = reader.play();
      await settle();
      await reader.pause();
      engine.jobs[0].complete('audio.wav');
      await first;
      expect(audio.plays, 0);
      expect(reader.status, ReadingStatus.paused);
      await reader.play();
      audio.position = 1234;
      await reader.pause();
      await reader.play();
      expect(audio.files, ['audio.wav']);
      expect(audio.position, 1234);
    },
  );
  test('Stop durante generación ignora audio y conserva fragmento', () async {
    await reader.select(1);
    final first = reader.play();
    await settle();
    await reader.stop();
    engine.jobs[0].complete('antiguo.wav');
    await first;
    expect(audio.files, isEmpty);
    expect(reader.index, 1);
    expect(reader.wantsPlayback, isFalse);
  });
  test(
    'Completar reutiliza el audio preparado y anticipa dos bloques',
    () async {
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('primero.wav');
      await first;
      expect(engine.jobs.length, 3);
      final stopsBeforeCompletion = audio.stops;
      audio.completions.add(null);
      audio.completions.add(null);
      await settle();
      expect(reader.index, 1);
      expect(audio.stops, stopsBeforeCompletion);
      expect(engine.jobs.length, 3);
      engine.jobs[1].complete('segundo.wav');
      await settle();
      expect(audio.files, ['primero.wav', 'segundo.wav']);
      expect(reader.index, 1);
    },
  );
  test(
    'Pausar durante el avance natural impide arrancar el siguiente audio',
    () async {
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('primero.wav');
      await first;
      audio.completions.add(null);
      await settle();
      await reader.pause();
      expect(engine.jobs.length, 3);
      engine.jobs[1].complete('segundo.wav');
      await settle();
      expect(reader.index, 1);
      expect(reader.status, ReadingStatus.paused);
      expect(audio.plays, 1);
      expect(reader.wantsPlayback, isFalse);
    },
  );
  test('Agrupa fragmentos y avanza al siguiente bloque sin regenerarlo', () async {
    await reader.open(
      ReadingDocument(
        name: 'bloques.md',
        hash: 'blocks',
        markdown: List.generate(
          20,
          (i) =>
              'Párrafo $i. ${List.filled(12, 'Lectura continua y natural.').join(' ')}',
        ).join('\n\n'),
      ),
    );
    final first = reader.play();
    await settle();
    engine.jobs[0].complete('bloque1.wav');
    await first;
    // A cold start reads one fragment; the prefetch keeps going from there.
    final end = reader.batchEnd;
    expect(end, 1);
    expect(engine.texts.first, reader.chunks.first.text);
    expect(engine.jobs.length, inInclusiveRange(4, 13));
    final preparedNext = engine.texts[1];
    engine.jobs[1].complete('bloque2.wav');
    audio.completions.add(null);
    await settle();
    expect(reader.index, end);
    expect(audio.files, ['bloque1.wav', 'bloque2.wav']);
    expect(engine.texts.where((text) => text == preparedNext).length, 1);
    expect(engine.texts[1], preparedNext);
  });

  test('Cambiar voz invalida también los dos bloques anticipados', () async {
    final first = reader.play();
    await settle();
    engine.jobs[0].complete('primero.wav');
    await first;
    expect(engine.jobs.length, 3);
    final change = reader.configure(newSpeed: 1.2);
    await settle();
    expect(engine.validity[1](), isFalse);
    expect(engine.validity[2](), isFalse);
    engine.jobs[1].complete('antiguo2.wav');
    engine.jobs[2].complete('antiguo3.wav');
    engine.jobs[3].complete('nuevo.wav');
    await change;
    expect(audio.files, ['primero.wav', 'nuevo.wav']);
  });

  test(
    'Un fallo de anticipación se reintenta cuando toca leer ese bloque',
    () async {
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('primero.wav');
      await first;
      engine.jobs[1].completeError(StateError('Fallo temporal'));
      await settle();
      audio.completions.add(null);
      await settle();
      expect(engine.jobs.length, 4);
      engine.jobs[3].complete('reintento.wav');
      await settle();
      expect(reader.status, ReadingStatus.reading);
      expect(audio.files, ['primero.wav', 'reintento.wav']);
    },
  );

  testWidgets('Un documento agrupado termina mostrando progreso completo', (
    tester,
  ) async {
    await tester.runAsync(
      () => reader.open(
        const ReadingDocument(
          name: 'final.md',
          hash: 'finished',
          markdown: 'Uno.\n\nDos.\n\nTres.',
        ),
      ),
    );
    await tester.runAsync(() async {
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('documento.wav');
      await first;
      expect(reader.batchEnd, 1);
      expect(engine.texts[1], 'Dos. Tres.');
      engine.jobs[1].complete('resto.wav');
      audio.completions.add(null);
      await settle();
      expect(reader.batchEnd, 3);
      audio.completions.add(null);
      await settle();
    });
    expect(reader.status, ReadingStatus.finished);
    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(controller: reader)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
    expect(find.text('Terminado'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'Anticipa un párrafo largo aunque delante haya dos títulos cortos',
    () async {
      final paragraph = List.filled(
        16,
        'Texto continuo de la lectura.',
      ).join(' ');
      await reader.open(
        ReadingDocument(
          name: 'titulos.md',
          hash: 'titles',
          markdown: '$paragraph\n\n# A\n\n# B\n\n$paragraph\n\n$paragraph',
        ),
      );
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('bloque.wav');
      await first;
      expect(engine.texts.skip(1), containsAll(['A', 'B']));
      expect(engine.texts.skip(1).any((text) => text.length > 200), isTrue);
      expect(engine.jobs.length, lessThanOrEqualTo(13));
      expect(audio.files, ['bloque.wav']);
    },
  );

  test('Una interrupción pausa y guarda posición', () async {
    final first = reader.play();
    await settle();
    engine.jobs[0].complete('audio.wav');
    await first;
    audio.pauses.add(null);
    await settle();
    expect(reader.status, ReadingStatus.paused);
    expect(reader.wantsPlayback, isFalse);
  });

  test(
    'Cada lote anticipado tiene como mucho el doble de texto que el anterior',
    () async {
      await reader.open(
        ReadingDocument(
          name: 'cortos.md',
          hash: 'short',
          markdown: List.generate(12, (i) => 'Frase $i.').join('\n\n'),
        ),
      );
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('uno.wav');
      await first;
      expect(engine.texts.take(3), [
        'Frase 0.',
        'Frase 1. Frase 2.',
        'Frase 3. Frase 4. Frase 5.',
      ]);
    },
  );

  test('El idioma se detecta al abrir un documento en inglés', () async {
    await reader.open(
      const ReadingDocument(
        name: 'english.md',
        hash: 'english',
        markdown: 'This is the guide for the new reader. It will read the text you open, and it can work without a connection.',
      ),
      detectLanguage: true,
    );
    expect(reader.language, ReadingLanguage.en);
    await reader.configure(newVoice: 16);
    await reader.open(
      const ReadingDocument(
        name: 'es.md',
        hash: 'es',
        markdown: 'Esta es la guía del lector. Lee el texto que abres y funciona sin conexión para que lo escuches.',
      ),
      detectLanguage: true,
    );
    expect(reader.language, ReadingLanguage.es);
    await reader.open(
      const ReadingDocument(
        name: 'en2.md',
        hash: 'en2',
        markdown: 'This is the text that you will read with the voice of your choice.',
      ),
      detectLanguage: true,
    );
    expect(reader.voice, 16);
  });

  test(
    'Play desde la notificación reanuda y mantiene la CPU despierta',
    () async {
      final first = reader.play();
      await settle();
      engine.jobs[0].complete('audio.wav');
      await first;
      expect(audio.awake.last, isTrue);
      audio.pauses.add(null);
      await settle();
      expect(audio.awake.last, isFalse);
      audio.resumeRequests.add(null);
      await settle();
      expect(reader.status, ReadingStatus.reading);
      expect(audio.awake.last, isTrue);
    },
  );

  test(
    'El arranque en caliente prepara los dos primeros bloques sin reproducir',
    () async {
      final warm = PlaybackController(
        engine,
        audio,
        ReadingRepository(directory),
        warmUp: true,
      );
      await warm.open(
        const ReadingDocument(
          name: 'w.md',
          hash: 'warm',
          markdown: 'Uno.\n\nDos.',
        ),
      );
      await settle();
      expect(engine.texts, ['Uno.', 'Dos.']);
      final play = warm.play();
      await settle();
      expect(engine.texts.first, 'Uno.');
      expect(engine.jobs.length, greaterThanOrEqualTo(1));
      engine.jobs[0].complete('uno.wav');
      await play;
      expect(audio.files, ['uno.wav']);
      expect(engine.texts.where((text) => text == 'Uno.').length, 1);
      await warm.close();
    },
  );

  testWidgets('Desplazarse muestra el atajo al fragmento actual', (
    tester,
  ) async {
    await tester.runAsync(
      () => reader.open(
        ReadingDocument(
          name: 'largo.md',
          hash: 'long',
          markdown: List.generate(40, (i) => 'Párrafo $i.').join('\n\n'),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(controller: reader)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ir al fragmento actual'), findsNothing);
    await tester.drag(find.text('Párrafo 0.'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Ir al fragmento actual'), findsOneWidget);
    await tester.tap(find.text('Ir al fragmento actual'));
    await tester.pumpAndSettle();
    expect(find.text('Ir al fragmento actual'), findsNothing);
    expect(find.text('Párrafo 0.'), findsOneWidget);
  });

  test('Siguiente, anterior y parar desde la notificación', () async {
    await reader.open(
      const ReadingDocument(
        name: 'n.md',
        hash: 'notification',
        markdown: 'Uno.\n\nDos.\n\nTres.',
      ),
    );
    audio.skipRequests.add(1);
    await settle();
    expect(reader.index, 1);
    audio.skipRequests.add(-1);
    await settle();
    expect(reader.index, 0);
    audio.skipRequests.add(-1);
    await settle();
    expect(reader.index, 0);
    final first = reader.play();
    await settle();
    engine.jobs.last.complete('uno.wav');
    await first;
    audio.stopRequests.add(null);
    await settle();
    expect(reader.wantsPlayback, isFalse);
    expect(reader.status, ReadingStatus.ready);
  });

  test('Pulsaciones rápidas de anterior se acumulan', () async {
    await reader.open(
      ReadingDocument(
        name: 'r.md',
        hash: 'rapid',
        markdown: List.generate(10, (i) => 'Frase $i.').join('\n\n'),
      ),
      position: 8,
    );
    for (var i = 0; i < 3; i++) {
      audio.skipRequests.add(-1);
    }
    await settle();
    expect(reader.index, 5);
  });

  test('Al terminar el documento se libera el audio', () async {
    final first = reader.play();
    await settle();
    engine.jobs[0].complete('a.wav');
    await first;
    engine.jobs[1].complete('b.wav');
    engine.jobs[2].complete('c.wav');
    for (var i = 0; i < 3; i++) {
      audio.completions.add(null);
      await settle();
    }
    expect(reader.status, ReadingStatus.finished);
    expect(audio.pauseCalls, greaterThan(0));
  });

  test('Pausar deja de anticipar bloques pero conserva el actual', () async {
    await reader.open(
      ReadingDocument(
        name: 'p.md',
        hash: 'pause-prefetch',
        markdown: List.generate(12, (i) => 'Frase número $i.').join('\n\n'),
      ),
    );
    final first = reader.play();
    await settle();
    engine.jobs[0].complete('uno.wav');
    await first;
    expect(engine.jobs.length, greaterThan(2));
    await reader.pause();
    expect(engine.validity[0](), isTrue);
    expect(engine.validity.skip(1).every((valid) => !valid()), isTrue);
    final resumed = reader.play();
    await settle();
    await resumed;
    expect(reader.status, ReadingStatus.reading);
  });
}
