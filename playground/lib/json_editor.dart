// A TextEditingController that syntax-highlights JSON as you type, reusing the
// shared tokenizer in json_view.dart so the editor and read-only viewers color
// identically.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'json_view.dart';

/// Re-indents [text] as 2-space-pretty JSON; throws on unparseable input.
String prettyJson(String text) =>
    '${const JsonEncoder.withIndent('  ').convert(jsonDecode(text))}\n';

class JsonEditingController extends TextEditingController {
  JsonEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    // Configs are a few KB; the guard only matters for pathological pastes.
    if (text.length > 200000) return TextSpan(text: text, style: base);
    return TextSpan(
      style: base,
      children: jsonSpans(text, base, JsonColors.of(context)),
    );
  }
}
