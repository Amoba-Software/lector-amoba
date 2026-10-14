import 'dart:math' as math;
import 'dart:typed_data';

const audioPipelineVersion = 'dc20hz-edges5ms-v2';

/// Blocks DC/subsonic bias with a 20 Hz first-order high-pass, then fades edges.
/// This preserves timing and does not normalize loudness or resample speech.
Float32List prepareSpeechAudio(Float32List source, int sampleRate) {
  if (sampleRate <= 0) throw ArgumentError.value(sampleRate, 'sampleRate');
  final result = Float32List(source.length);
  final pole = math.exp(-2 * math.pi * 20 / sampleRate);
  final gain = (1 + pole) / 2;
  var previousInput = 0.0;
  var previousOutput = 0.0;
  for (var i = 0; i < source.length; i++) {
    final input = source[i];
    final output = gain * (input - previousInput) + pole * previousOutput;
    result[i] = output;
    previousInput = input;
    previousOutput = output;
  }
  return _fadeEdges(result, sampleRate);
}

/// Removes discontinuities at WAV boundaries without altering the middle.
Float32List smoothSpeechEdges(Float32List source, int sampleRate) {
  return _fadeEdges(Float32List.fromList(source), sampleRate);
}

Float32List _fadeEdges(Float32List result, int sampleRate) {
  final count = math.min((sampleRate * 0.005).round(), result.length ~/ 2);
  if (count < 2) return result;
  for (var i = 0; i < count; i++) {
    final gain = 0.5 - 0.5 * math.cos(math.pi * i / (count - 1));
    result[i] *= gain;
    result[result.length - 1 - i] *= gain;
  }
  return result;
}

/// Rejects corrupt synthesis before it reaches the player or cache.
void validateSpeechAudio(
  List<double> samples,
  int sampleRate, {
  int expectedSampleRate = 24000,
}) {
  if (samples.isEmpty || sampleRate != expectedSampleRate || sampleRate <= 0) {
    throw StateError('Kokoro no produjo audio válido.');
  }
  var clipped = 0;
  var railRun = 0;
  var maxRailRun = 0;
  for (final sample in samples) {
    if (!sample.isFinite) {
      throw StateError('Kokoro produjo audio no finito.');
    }
    if (sample.abs() >= 0.999) {
      clipped++;
      railRun++;
      maxRailRun = math.max(maxRailRun, railRun);
    } else {
      railRun = 0;
    }
  }
  if (clipped / samples.length > 0.01 || maxRailRun > sampleRate * 0.02) {
    throw StateError('Kokoro produjo audio saturado. Intenta otro fragmento.');
  }
}
