import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/audio_validation.dart';
import 'package:lector_amoba/engine_config.dart';
import 'package:lector_amoba/tts_service.dart';

void main() {
  test('Una lectura repetida reutiliza la caché sin iniciar el motor y renueva su uso', () async {
    final directory = await Directory.systemTemp.createTemp('lector-cache');
    final service = TtsService(directory);
    try {
      final key = sha256
          .convert(
            utf8.encode(
              '$modelVersion|$audioPipelineVersion|28|1.0|false|Hola',
            ),
          )
          .toString();
      final wav = File('${directory.path}/$key.wav');
      await wav.writeAsBytes([1, 2, 3, 4]);
      await wav.setLastModified(DateTime(2000));
      expect(
        await service.synthesize('Hola', 28, 1.0, false, () => true),
        wav.path,
      );
      expect((await wav.lastModified()).year, greaterThan(2000));
      expect(File('${directory.path}/metrics.jsonl').existsSync(), isFalse);
    } finally {
      await service.dispose();
      await directory.delete(recursive: true);
    }
  });
}
