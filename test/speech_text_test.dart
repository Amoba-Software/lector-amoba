import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/engine_config.dart';
import 'package:lector_amoba/speech_text.dart';

void main() {
  String es(String text, [List<Pronunciation> rules = const []]) =>
      speakable(text, ReadingLanguage.es, rules);

  test('La voz no deletrea restos de Markdown ni de código', () {
    expect(es('#Título sin espacio'), 'Título sin espacio');
    expect(es('Color #3568F0'), 'Color 3568F0');
    expect(es('- elemento suelto'), 'elemento suelto');
    expect(es('**negrita rota'), 'negrita rota');
    expect(es('Ver `ef_dora` en assets/model'), 'Ver ef dora en assets model');
    expect(es('Especificación — Lector'), 'Especificación, Lector');
    expect(es('Opciones → Apariencia'), 'Opciones, Apariencia');
    expect(es('Botón «Abrir .md».'), 'Botón Abrir .md.');
    expect(es('Pasos 1–3'), 'Pasos 1 a 3');
    expect(speakable('Steps 1–3', ReadingLanguage.en), 'Steps 1 to 3');
    expect(es('Fecha 9/10/2026, 25 %'), 'Fecha 9/10/2026, 25 %');
    expect(es('Listo 🚀'), 'Listo');
  });

  test('El diccionario cambia palabras completas sin tocar otras', () {
    const rules = [Pronunciation('MVP', 'eme ve pe')];
    expect(es('Desarrollar el MVP.', rules), 'Desarrollar el eme ve pe.');
    expect(es('MVPS no cambia', rules), 'MVPS no cambia');
  });

  test('El diccionario se guarda y tolera archivos dañados', () async {
    final directory = await Directory.systemTemp.createTemp('lector-pron');
    addTearDown(() => directory.delete(recursive: true));
    final repository = PronunciationRepository(directory);
    expect(await repository.load(), isEmpty);
    await repository.save(const [Pronunciation('API', 'a pe i')]);
    final loaded = await PronunciationRepository(directory).load();
    expect(loaded.single.spoken, 'a pe i');
    await File('${directory.path}/pronunciation.json').writeAsString('{');
    expect(await repository.load(), isEmpty);
  });
}
