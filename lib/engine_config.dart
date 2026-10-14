import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_profile.dart' as kokoro;

const piperTrial = bool.fromEnvironment('PIPER_TRIAL');
const modelVersion = piperTrial
    ? 'piper-es_MX-ald-medium-int8-1'
    : kokoro.modelVersion;
const nativeVoiceIds = piperTrial ? {28: 0} : kokoro.nativeVoiceIds;
const expectedNativeSpeakers = piperTrial ? 1 : kokoro.expectedNativeSpeakers;
const engineSampleRate = piperTrial ? 22050 : 24000;
const applicationTitle = piperTrial ? 'Lector Amoba Piper' : 'Lector Amoba';

enum ReadingLanguage {
  es('Español', 'es'),
  en('Inglés', 'en-us');

  const ReadingLanguage(this.label, this.espeak);
  final String label;
  final String espeak;
}

class ReaderVoice {
  const ReaderVoice(this.name, this.language);
  final String name;
  final ReadingLanguage language;
}

// Public IDs follow the upstream Kokoro v1.0 speaker table.
const readerVoices = piperTrial
    ? {28: ReaderVoice('Ald', ReadingLanguage.es)}
    : {
        28: ReaderVoice('Dora', ReadingLanguage.es),
        29: ReaderVoice('Alex', ReadingLanguage.es),
        3: ReaderVoice('Heart', ReadingLanguage.en),
        16: ReaderVoice('Michael', ReadingLanguage.en),
      };

ReadingLanguage voiceLanguage(int voice) =>
    readerVoices[voice]?.language ?? ReadingLanguage.es;

Iterable<int> voicesFor(ReadingLanguage language) => readerVoices.keys.where(
  (voice) => readerVoices[voice]!.language == language,
);

Set<ReadingLanguage> get availableLanguages =>
    readerVoices.values.map((voice) => voice.language).toSet();

const engineSilenceScale = 0.6;

// Kokoro v1.0 accepts the espeak language per request, so one loaded model
// serves both languages without a reload.
sherpa.OfflineTtsGenerationConfig generationConfig(int voice, double speed) =>
    sherpa.OfflineTtsGenerationConfig(
      sid: nativeVoiceId(voice),
      speed: speed,
      silenceScale: engineSilenceScale,
      extra: piperTrial ? const {} : {'lang': voiceLanguage(voice).espeak},
    );

int nativeVoiceId(int voice) {
  final result = nativeVoiceIds[voice];
  if (result == null) {
    throw ArgumentError.value(voice, 'voice', 'Voz desconocida');
  }
  return result;
}

// ONNX Runtime keeps its worker threads spinning after each operator to
// shave latency; on a phone that burns battery between and after blocks.
const onnxSessionSettings =
    'SessionConfig.session.intra_op.allow_spinning=0\n'
    'SessionConfig.session.inter_op.allow_spinning=0\n';

/// [settings] is a file with [onnxSessionSettings]; without it the runtime
/// keeps its defaults.
sherpa.OfflineTtsConfig engineConfig(
  String directory, {
  int threads = 4,
  String? settings,
}) => sherpa.OfflineTtsConfig(
  model: sherpa.OfflineTtsModelConfig(
    vits: piperTrial
        ? sherpa.OfflineTtsVitsModelConfig(
            model: '$directory/model.onnx',
            tokens: '$directory/tokens.txt',
            dataDir: '$directory/espeak-ng-data',
          )
        : const sherpa.OfflineTtsVitsModelConfig(),
    kokoro: piperTrial
        ? const sherpa.OfflineTtsKokoroModelConfig()
        : sherpa.OfflineTtsKokoroModelConfig(
            model: '$directory/model.onnx',
            voices: '$directory/voices.bin',
            tokens: '$directory/tokens.txt',
            dataDir: '$directory/espeak-ng-data',
            lang: 'es',
          ),
    numThreads: threads,
    provider: settings == null ? 'cpu' : 'cpu:$settings',
    debug: false,
  ),
  maxNumSenetences: 1,
  silenceScale: engineSilenceScale,
);
