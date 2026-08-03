// Shared JSON/code display primitives: a VS-Code-ish syntax tokenizer, a
// read-only highlighted [JsonText], and [showRawDataDialog]: the copy-enabled
// full-content viewer used for step bodies and result items. The live editor
// (json_editor.dart) reuses [jsonSpans] so highlighting is identical
// everywhere. Mirrors the app's Extension Lab json_code_field.dart.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const kMono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Consolas'],
  fontSize: 12,
  height: 1.4,
);

/// Token colors for one brightness: keys, strings, numbers, literals, and the
/// dimmed punctuation/whitespace between tokens.
class JsonColors {
  const JsonColors({
    required this.key,
    required this.string,
    required this.number,
    required this.literal,
    required this.punct,
  });

  final Color key;
  final Color string;
  final Color number;
  final Color literal;
  final Color punct;

  factory JsonColors.of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return JsonColors(
      key: dark ? const Color(0xFF7FB4E8) : const Color(0xFF1B6AC9),
      string: dark ? const Color(0xFF9CCC8C) : const Color(0xFF2E7D32),
      number: dark ? const Color(0xFFD8A657) : const Color(0xFFB06F1F),
      literal: dark ? const Color(0xFFCE93D8) : const Color(0xFF8E24AA),
      punct: (theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface)
          .withValues(alpha: 0.55),
    );
  }
}

final _token = RegExp(
  r'"(?:[^"\\]|\\.)*"' // string (key or value)
  r'|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?' // number
  r'|\b(?:true|false|null)\b',
);

/// Tokenizes [text] into colored spans over [base]. A string token followed by
/// `:` is colored as a key. Non-JSON text just comes back dim-punctuation
/// colored, so HTML/plain bodies degrade to readable monospace.
List<TextSpan> jsonSpans(String text, TextStyle base, JsonColors colors) {
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in _token.allMatches(text)) {
    if (m.start > last) {
      spans.add(
        TextSpan(
          text: text.substring(last, m.start),
          style: base.copyWith(color: colors.punct),
        ),
      );
    }
    final tok = m.group(0)!;
    final Color color;
    if (tok.startsWith('"')) {
      color = _isKey(text, m.end) ? colors.key : colors.string;
    } else if (tok == 'true' || tok == 'false' || tok == 'null') {
      color = colors.literal;
    } else {
      color = colors.number;
    }
    spans.add(
      TextSpan(
        text: tok,
        style: base.copyWith(color: color),
      ),
    );
    last = m.end;
  }
  if (last < text.length) {
    spans.add(
      TextSpan(
        text: text.substring(last),
        style: base.copyWith(color: colors.punct),
      ),
    );
  }
  return spans;
}

bool _isKey(String text, int end) {
  for (var i = end; i < text.length; i++) {
    final c = text[i];
    if (c == ' ' || c == '\t') continue;
    return c == ':';
  }
  return false;
}

/// True when [text] looks like a JSON document (starts with `{` or `[`), used
/// to decide whether to highlight a step body or show it as plain text.
bool looksJson(String text) {
  final t = text.trimLeft();
  return t.startsWith('{') || t.startsWith('[');
}

/// Read-only, selectable, syntax-highlighted text. [highlight] false renders
/// plain monospace (for HTML/other bodies).
class JsonText extends StatelessWidget {
  const JsonText(
    this.text, {
    super.key,
    this.highlight = true,
    this.fontSize = 12,
  });

  final String text;
  final bool highlight;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = kMono.copyWith(
      fontSize: fontSize,
      color: Theme.of(context).colorScheme.onSurface,
    );
    if (!highlight) return SelectableText(text, style: base);
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: jsonSpans(text, base, JsonColors.of(context)),
      ),
    );
  }
}

/// Full-content viewer with a Copy button. Pretty-prints when [text] parses as
/// JSON, else shows it verbatim (raw HTML). Scrolls both axes for wide/tall
/// content.
Future<void> showRawDataDialog(
  BuildContext context, {
  required String title,
  required String text,
}) {
  String shown = text;
  bool isJson = false;
  try {
    shown = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    isJson = true;
  } catch (_) {
    // Not JSON: show verbatim.
  }
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _RawDataDialog(title: title, text: shown, isJson: isJson),
  );
}

class _RawDataDialog extends StatefulWidget {
  const _RawDataDialog({
    required this.title,
    required this.text,
    required this.isJson,
  });

  final String title;
  final String text;
  final bool isJson;

  @override
  State<_RawDataDialog> createState() => _RawDataDialogState();
}

class _RawDataDialogState extends State<_RawDataDialog> {
  // Neither SingleChildScrollView below had its own controller, so on
  // desktop (where every scrollable is auto-wrapped in a Scrollbar) both
  // fell back to PrimaryScrollController, not reliably attached inside a
  // Dialog's overlay, throwing "no ScrollPosition attached" on the warm-up
  // frame. Explicit controllers, one per axis, same fix _LogCard already
  // uses for its own scrollable.
  final _verticalController = ScrollController();
  final _horizontalController = ScrollController();

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final text = widget.text;
    final isJson = widget.isJson;
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleSmall),
                  ),
                  Text(
                    '${text.length} chars',
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('Copied')));
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                controller: _verticalController,
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  controller: _horizontalController,
                  scrollDirection: Axis.horizontal,
                  child: JsonText(text, highlight: isJson),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
