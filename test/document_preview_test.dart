import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lector_amoba/document_preview.dart';
import 'package:lector_amoba/reader_theme.dart';

void main() {
  const source = '''# Título

Texto **importante** y *énfasis*.

- Primero
- Segundo

> Una cita.

| Campo | Valor |
| --- | --- |
| Nombre | Ana |

```dart
final documento = 'sin modificar';
```

![Diagrama](https://example.invalid/imagen.png)
''';

  testWidgets('Renderiza estructura y conserva el documento fuente', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DocumentPreview(source: source)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Título', findRichText: true), findsOneWidget);
    expect(find.text('# Título', findRichText: true), findsNothing);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Imagen: Diagrama'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, source);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Arrastrar sobre el texto desplaza el documento', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final paragraphs = List.generate(
      30,
      (i) =>
          'Párrafo $i. Texto largo para deslizar directamente sobre la lectura y continuar leyendo sin usar los bordes.',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentPreview(source: paragraphs.join('\n\n'))),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.pixels, 0);
    await tester.dragFrom(
      tester.getCenter(find.text(paragraphs[1], findRichText: true)),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(100));
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('El visor usa superficies y texto de modo oscuro', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme(Brightness.dark),
        home: const Scaffold(
          body: DocumentPreview(source: '# Lectura nocturna'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final background = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(DocumentPreview),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(background.color, ReaderPalette.dark.page);
    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.styleSheet!.p!.color, ReaderPalette.dark.ink);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tablas y código ancho funcionan en móvil con letra grande', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: DocumentPreview(
              source: '''# Documento

| Primera columna larga | Segunda columna larga | Tercera columna larga |
| --- | --- | --- |
| Un valor largo | Otro valor largo | Texto completo |

```text
una_linea_de_codigo_larga_que_se_desplaza_sin_recortar_ni_romper_el_documento
```
''',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsAtLeastNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });
}
