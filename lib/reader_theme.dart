import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class ReaderPalette {
  const ReaderPalette(
    this.page,
    this.surface,
    this.ink,
    this.muted,
    this.tint,
    this.border,
    this.primary,
    this.selectedBorder,
    this.onPrimary,
  );
  final Color page, surface, ink, muted, tint, border, primary, selectedBorder;
  final Color onPrimary;
  // Cool reading paper by day; deep Amoba navy (blue, not black) by night.
  static const light = ReaderPalette(
    Color(0xfff1f4fa),
    Colors.white,
    Color(0xff0f1b36),
    Color(0xff5d6b86),
    Color(0xffe3eafb),
    Color(0xffdbe2ef),
    Color(0xff2f5bea),
    Color(0xffb7c8f7),
    Colors.white,
  );
  static const dark = ReaderPalette(
    Color(0xff0f1b36),
    Color(0xff1a2a4f),
    Color(0xfff4f6fb),
    Color(0xff9eabc6),
    Color(0xff22345f),
    Color(0xff2a3c66),
    Color(0xff8caeff),
    Color(0xff5275b5),
    Color(0xff0f1b36),
  );
  static ReaderPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData readerTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark
      ? ReaderPalette.dark
      : ReaderPalette.light;
  return ThemeData(
    brightness: brightness,
    fontFamily: 'Nunito',
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff3568f0),
      brightness: brightness,
      primary: colors.primary,
      surface: colors.surface,
      onSurface: colors.ink,
    ),
    scaffoldBackgroundColor: colors.page,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.page,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: colors.primary,
        selectedForegroundColor: colors.onPrimary,
        foregroundColor: colors.ink,
        side: BorderSide(color: colors.border),
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    useMaterial3: true,
  );
}

class ThemePreferences {
  ThemePreferences(this.directory);
  final Directory directory;
  Future<void> _tail = Future.value();
  Future<ThemeMode> load() async {
    try {
      final data = jsonDecode(
        await File('${directory.path}/appearance.json').readAsString(),
      ) as Map<String, dynamic>;
      return ThemeMode.values.firstWhere(
        (mode) => mode.name == data['theme'],
        orElse: () => ThemeMode.system,
      );
    } catch (_) {
      return ThemeMode.system;
    }
  }

  Future<void> save(ThemeMode mode) {
    final work = _tail.then((_) async {
      await directory.create(recursive: true);
      final file = File('${directory.path}/appearance.json.tmp');
      await file.writeAsString(jsonEncode({'theme': mode.name}), flush: true);
      await file.rename('${directory.path}/appearance.json');
    });
    _tail = work.catchError((Object _) {});
    return work;
  }
}
