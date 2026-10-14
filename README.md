# Lector Amoba

App Android (Flutter) que lee en voz alta documentos Markdown y Word, en español e inglés, sin conexión. La voz se genera en el propio teléfono con [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) mediante [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); no hay backend, cuentas ni envío de datos.

## Qué hace

- Abre `.md`, `.markdown`, `.txt` y `.docx`, desde el selector de archivos, con «Abrir con» desde otras apps o compartiendo texto.
- Lee en español (voces Dora y Alex) e inglés (Heart y Michael). Detecta el idioma del documento al abrirlo.
- Sigue leyendo con la pantalla apagada o en otra app, con controles en la notificación: anterior, pausa, siguiente y parar.
- Pantalla de lectura inmersiva: el pasaje que suena se resalta y la lista lo sigue; índice de secciones, documentos recientes con su posición, velocidades de 0,8× a 1,5×, temporizador y modo claro u oscuro.
- La voz no deletrea restos de Markdown o código (`#`, `*`, `_`, `/`, flechas…), y un diccionario editable permite fijar pronunciaciones (por ejemplo, «MVP» → «eme ve pe»).

## Compilar

Requisitos: Flutter 3.47.4 (Dart 3.13.3), Java 17 y Android SDK 36. Las versiones directas están fijadas en `pubspec.yaml` y las transitivas en `pubspec.lock`.

```sh
python3 tool/fetch_model.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

`tool/fetch_model.py` descarga el modelo (156 MB) desde las Releases del repositorio y comprueba su tamaño y SHA-256 contra `assets/model/manifest.json`. El resto de recursos del modelo (voces, tokens y datos de espeak-ng) ya está en `assets/model/`.

El APK resultante está en `build/app/outputs/flutter-apk/app-release.apk` (unos 210 MB, solo ARM64, Android 7 o posterior). Al leer por primera vez, la app copia y verifica el modelo en su almacenamiento privado.

## Arquitectura

- `DocumentService` y `docx_converter.dart`: importación con UTF-8 estricto, límites de tamaño y conversión de Word a Markdown (títulos, listas, tablas).
- `MarkdownSpeechService`: convierte el Markdown en fragmentos pronunciables; omite bloques de código, URLs y separadores, y lee las tablas como «columna: valor».
- `speech_text.dart`: limpia el texto que va a la voz y aplica el diccionario de pronunciación.
- `TtsService`: motor Kokoro persistente en un isolate, una inferencia a la vez, con caché de audio de hasta 100 MiB. El idioma se pasa a espeak-ng por solicitud, así que un mismo modelo sirve para ambos idiomas.
- `PlaybackController`: estado de lectura, navegación y anticipación. El primer bloque es corto para empezar antes; cada bloque siguiente tiene como mucho el doble de texto que el anterior; al pausar se descarta la anticipación pendiente.
- `audio_output.dart`: reproducción con `just_audio` y sesión multimedia con `audio_service`. El estado publicado sigue la intención de lectura, de modo que el servicio sigue en primer plano entre bloques.
- `ReadingRepository`: posición, voz y velocidad guardadas de forma atómica, y biblioteca de documentos recientes.

## Modelo

`tool/compact_model.py` genera el modelo incluido a partir de la exportación oficial `kokoro-multi-lang-v1_0` de sherpa-onnx: pesos guardados en FP16 y cálculo en FP32, con solo las cuatro voces que usa la app. `tool/select_model.py` lo activa y actualiza `lib/model_profile.dart`. `tool/probe.dart` y `tool/benchmark.dart` generan audio de prueba y miden tiempos en el ordenador.

## Licencias

Kokoro-82M y sherpa-onnx se distribuyen bajo Apache-2.0; los datos de espeak-ng, bajo GPL-3.0-or-later; la fuente Nunito, bajo SIL Open Font License. Los textos están en `assets/licenses/`, `assets/model/LICENSE` y `assets/fonts/OFL.txt`, y la app los muestra en Opciones → Licencias.
