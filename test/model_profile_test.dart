import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/engine_config.dart';

void main() {
  test('El perfil de la app coincide con el modelo empaquetado', () {
    final manifest = jsonDecode(
      File('assets/model/manifest.json').readAsStringSync(),
    ) as Map;
    expect(modelVersion, manifest['version']);
    expect(nativeVoiceIds.keys.toSet(), readerVoices.keys.toSet());
    expect(
      nativeVoiceIds.values.every(
        (id) => id >= 0 && id < expectedNativeSpeakers,
      ),
      isTrue,
    );
    final profileFile = File('assets/model/profile.json');
    if (profileFile.existsSync()) {
      final profile = jsonDecode(profileFile.readAsStringSync()) as Map;
      for (final voice in readerVoices.keys) {
        expect(nativeVoiceId(voice), profile['voices']['$voice']);
      }
    }
    expect(() => nativeVoiceId(999), throwsArgumentError);
  });
}
