import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'reader_theme.dart';

/// Read-only presentation: the document and speech parser retain their source.
class DocumentPreview extends StatelessWidget {
  const DocumentPreview({super.key, required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final colors = ReaderPalette.of(context);
    final ink = colors.ink;
    final blue = colors.primary;
    final body = TextStyle(
      fontFamily: 'Nunito',
      fontSize: 17,
      height: 1.65,
      color: ink,
    );
    return ColoredBox(
      color: colors.page,
      child: SelectionArea(
        child: Markdown(
          data: source,
          selectable: false,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: body,
            h1: body.copyWith(
              fontSize: 28,
              height: 1.25,
              fontWeight: FontWeight.w800,
            ),
            h2: body.copyWith(
              fontSize: 23,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
            h3: body.copyWith(
              fontSize: 20,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
            h4: body.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
            h5: body.copyWith(fontWeight: FontWeight.w800),
            h6: body.copyWith(fontWeight: FontWeight.w700),
            a: body.copyWith(color: blue, decoration: TextDecoration.underline),
            strong: const TextStyle(fontWeight: FontWeight.w800),
            em: const TextStyle(fontStyle: FontStyle.italic),
            blockSpacing: 20,
            listBullet: body.copyWith(color: blue),
            blockquote: body,
            blockquotePadding: const EdgeInsets.all(16),
            blockquoteDecoration: BoxDecoration(
              color: colors.tint,
              border: Border(left: BorderSide(color: blue, width: 3)),
            ),
            code: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.5,
              color: ink,
            ),
            codeblockPadding: const EdgeInsets.all(16),
            codeblockDecoration: BoxDecoration(
              color: colors.page,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            tableHead: body.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
            tableBody: body.copyWith(fontSize: 16),
            tableColumnWidth: const IntrinsicColumnWidth(),
            tableCellsPadding: const EdgeInsets.all(12),
            tableHeadCellsDecoration: BoxDecoration(color: colors.tint),
            tableBorder: TableBorder.all(color: colors.border),
            horizontalRuleDecoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.border)),
            ),
          ),
          // A picked .md grants access to that file, not its referenced images.
          // Keep the offline viewer deterministic without fetching remote URLs.
          imageBuilder: (uri, title, alt) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.page,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.image_outlined, color: blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    alt?.isNotEmpty == true
                        ? 'Imagen: $alt'
                        : 'Imagen vinculada',
                    style: body,
                  ),
                ),
              ],
            ),
          ),
          onTapLink: (text, href, title) async {
            if (href == null || href.isEmpty) return;
            await Clipboard.setData(ClipboardData(text: href));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Enlace copiado')));
            }
          },
        ),
      ),
    );
  }
}
