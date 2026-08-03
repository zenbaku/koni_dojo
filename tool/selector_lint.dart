/// Statically checks every selector string in an extension config against
/// the *actual* support surface of `lib/src/extended_selectors.dart`, the
/// evaluator every source in the pipeline now runs through, so a typo or
/// unsupported pseudo-class fails the build instead of shipping and only
/// surfacing the first time a real page exercises it.
///
/// Every check here is DOM-independent: parse errors, unsupported-pseudo
/// detection, and malformed `An+B` arguments all depend only on the
/// selector *string*, never on a live page. So a selector that passes this
/// lint cannot throw or silently match nothing at runtime, regardless of
/// what a site's markup looks like. See `extended_selectors_test.dart`'s
/// `supportedPseudoClasses`/`supportedPseudoClassFunctions` pinning tests
/// for why that support surface can be trusted here rather than re-derived.
library;

import 'package:csslib/parser.dart';
import 'package:csslib/visitor.dart';
import 'package:koni_dojo/src/extended_selectors.dart';

/// One problem found with one selector string, plus every `file:jsonPath`
/// location it was used at (a selector often repeats across many keys/
/// files, e.g. `"a"` or `"img"`).
class SelectorLintIssue {
  SelectorLintIssue(this.selector, this.reason, this.locations);

  final String selector;
  final String reason;
  final List<String> locations;

  @override
  String toString() =>
      '"$selector": $reason\n'
      '${locations.map((l) => '    at $l').join('\n')}';
}

/// Matches every `*Selector`/`selector` key in the extension JSON schema:
/// `selector`, `itemSelector`, `titleSelector`, `urlSelector`, nested
/// `cover[].selector`, etc.
final _selectorKeyPattern = RegExp(r'^([a-zA-Z]*)?[Ss]elector$');

/// Walks one extension's decoded JSON (as `jsonDecode` produces it, or an
/// equivalent `Map<String, dynamic>`) collecting every selector-bearing
/// string value under any `*Selector`/`selector` key, and returns a lint
/// issue for each *distinct* selector that would fail to parse or is
/// guaranteed to throw/match-nothing under [ExtendedSelectors]. Empty when
/// everything is clean. [fileLabel] is only used to build readable
/// locations in the returned issues.
List<SelectorLintIssue> lintExtensionSelectors(
  Map<String, dynamic> extensionJson,
  String fileLabel,
) {
  final usages = <String, List<String>>{}; // selector -> "file:json.path"

  void walk(dynamic node, String path) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        if (key is! String) continue;
        final childPath = path.isEmpty ? key : '$path.$key';
        final value = entry.value;
        if (_selectorKeyPattern.hasMatch(key) &&
            value is String &&
            value.trim().isNotEmpty) {
          usages.putIfAbsent(value, () => []).add('$fileLabel:$childPath');
        } else {
          walk(value, childPath);
        }
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        walk(node[i], '$path[$i]');
      }
    }
  }

  walk(extensionJson, '');

  final issues = <SelectorLintIssue>[];
  for (final entry in usages.entries) {
    final reason = _lintOne(entry.key);
    if (reason != null) {
      issues.add(SelectorLintIssue(entry.key, reason, entry.value));
    }
  }
  return issues;
}

/// The `nth-*()` functions whose argument must parse as the CSS `An+B`
/// micro-grammar (see [parseAnB]) to ever match anything.
const _nthFunctions = {
  'nth-child',
  'nth-last-child',
  'nth-of-type',
  'nth-last-of-type',
};

String? _lintOne(String selector) {
  final errors = <Message>[];
  final group = parseSelectorGroup(selector, errors: errors);
  if (group == null || errors.isNotEmpty) {
    return 'invalid selector syntax: $errors';
  }

  final collector = _PseudoCollector();
  group.visit(collector);

  for (final name in collector.classNames) {
    if (!supportedPseudoClasses.contains(name)) {
      return 'unsupported pseudo-class `:$name` '
          '(not in extended_selectors.dart\'s supportedPseudoClasses)';
    }
  }
  for (final call in collector.classFnCalls) {
    final (name, node) = call;
    if (!supportedPseudoClassFunctions.contains(name)) {
      return 'unsupported pseudo-class function `:$name(...)` '
          '(not in extended_selectors.dart\'s supportedPseudoClassFunctions)';
    }
    if (_nthFunctions.contains(name)) {
      final argText = node.expression.span.text;
      if (parseAnB(argText) == null) {
        return '`:$name($argText)` is not a valid An+B/odd/even/integer '
            'argument -- can never match anything';
      }
    }
  }
  for (final name in collector.elementNames) {
    if (!legacyPseudoElements.contains(name)) {
      return 'unsupported pseudo-element `::$name`';
    }
  }
  if (collector.elementFnNames.isNotEmpty) {
    return 'unsupported pseudo-element function '
        '`::${collector.elementFnNames.first}(...)`';
  }

  return null;
}

class _PseudoCollector extends Visitor {
  final Set<String> classNames = {};
  final List<(String, PseudoClassFunctionSelector)> classFnCalls = [];
  final Set<String> elementNames = {};
  final Set<String> elementFnNames = {};

  @override
  dynamic visitNegationSelector(NegationSelector node) =>
      node.negationArg?.visit(this);

  @override
  dynamic visitPseudoClassSelector(PseudoClassSelector node) =>
      classNames.add(node.name);

  @override
  dynamic visitPseudoClassFunctionSelector(PseudoClassFunctionSelector node) {
    classFnCalls.add((node.name, node));
  }

  @override
  dynamic visitPseudoElementSelector(PseudoElementSelector node) =>
      elementNames.add(node.name);

  @override
  dynamic visitPseudoElementFunctionSelector(
    PseudoElementFunctionSelector node,
  ) => elementFnNames.add(node.name);
}
