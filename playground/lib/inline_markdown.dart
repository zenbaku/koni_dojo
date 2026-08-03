// Minimal inline-markdown rendering for short prose strings (catalog notes,
// archive reasons): backtick code spans and **bold**, nothing else. This
// content never uses headers/lists/links, so a full markdown package would be
// dependency weight for formatting two token types.
import 'package:flutter/material.dart';

/// Renders [text] as selectable rich text: `` `code` `` spans in monospace
/// with a subtle background, `**bold**` spans bolded, everything else as
/// plain prose in [style].
class InlineMarkdown extends StatelessWidget {
  const InlineMarkdown(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final code = base.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas'],
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    final bold = base.copyWith(fontWeight: FontWeight.bold);
    return SelectableText.rich(
      TextSpan(style: base, children: _spans(text, code, bold)),
    );
  }
}

final _tokenPattern = RegExp(r'`[^`]+`|\*\*[^*]+\*\*');

List<InlineSpan> _spans(String text, TextStyle code, TextStyle bold) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _tokenPattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final token = m.group(0)!;
    spans.add(
      token.startsWith('`')
          ? TextSpan(text: token.substring(1, token.length - 1), style: code)
          : TextSpan(text: token.substring(2, token.length - 2), style: bold),
    );
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}
