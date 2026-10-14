import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/reader_theme.dart';

void main() {
  test('Persiste la apariencia y tolera preferencias inválidas', () async {
    final directory = await Directory.systemTemp.createTemp('lector-theme');
    addTearDown(() => directory.delete(recursive: true));
    final preferences = ThemePreferences(directory);
    expect(await preferences.load(), ThemeMode.system);
    await preferences.save(ThemeMode.dark);
    expect(await ThemePreferences(directory).load(), ThemeMode.dark);
    await preferences.save(ThemeMode.light);
    expect(await preferences.load(), ThemeMode.light);
    await File('${directory.path}/appearance.json').writeAsString('corrupto');
    expect(await preferences.load(), ThemeMode.system);
  });
}
