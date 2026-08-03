/// Extended CSS selector matching for `package:html` documents.
///
/// `package:html`'s built-in `Element.querySelector`/`querySelectorAll`
/// delegate to a private `SelectorEvaluator`
/// (`package:html/src/query_selector.dart`) that implements only a subset of
/// CSS pseudo-classes: no `:contains()`, no `:nth-of-type()` /
/// `:nth-last-of-type()` / `:first-of-type` / `:last-of-type` /
/// `:only-of-type`, and `:nth-child()` / `:nth-last-child()` only accept a
/// bare positive integer (no `An+B`, no `odd`/`even`). That evaluator isn't
/// exported and its match state (`_element`) is private to its own library,
/// so it can't be subclassed or patched from outside `package:html`.
///
/// This file re-parses selectors with the same (public) `csslib` parser
/// `package:html` uses internally, then walks the resulting AST with our own
/// [Visitor] against the same (public) DOM tree `package:html` builds.
/// Everything the built-in evaluator already gets right (combinators, basic
/// selectors, attribute operators, `:not()`, `:lang()`, ...) is reproduced
/// here so this is a full drop-in replacement for those selector strings,
/// not just a patch bolted onto the two originally-missing pseudo-classes.
library;

import 'package:csslib/parser.dart';
import 'package:csslib/visitor.dart';
import 'package:html/dom.dart';

/// Every `:name` pseudo-class [_ExtendedSelectorEvaluator] can match without
/// throwing. Exported so static tooling (e.g. a config lint) can check a
/// selector string against the *actual* runtime support surface instead of
/// keeping a separate, driftable copy of this list. See
/// `extended_selectors_test.dart` for the test pinning this against real
/// evaluator behavior.
const supportedPseudoClasses = {
  'root',
  'empty',
  'first-child',
  'last-child',
  'only-child',
  'first-of-type',
  'last-of-type',
  'only-of-type',
  'link',
  'visited',
};

/// Every `:name(...)` functional pseudo-class [_ExtendedSelectorEvaluator]
/// can match without throwing. See [supportedPseudoClasses].
const supportedPseudoClassFunctions = {
  'lang',
  'contains',
  'nth-child',
  'nth-last-child',
  'nth-of-type',
  'nth-last-of-type',
};

/// `::name` pseudo-elements that are valid CSS but can never match a real
/// element (mirrors browser behavior) rather than being an error. Anything
/// else in `::name`/`::name()` position throws.
const legacyPseudoElements = {'before', 'after', 'first-line', 'first-letter'};

extension ExtendedSelectors on Node {
  /// Like [Element.querySelector], but understands `:contains()`,
  /// `:nth-of-type()`, `:nth-last-child()`, `:nth-last-of-type()`,
  /// `:first-of-type`, `:last-of-type`, `:only-of-type`, and `An+B` / `odd` /
  /// `even` arguments to `:nth-child()` / `:nth-of-type()`.
  Element? querySelectorExt(String selector) =>
      _ExtendedSelectorEvaluator().querySelector(this, _parse(selector));

  /// Like [Element.querySelectorAll], with the same extended pseudo-class
  /// support as [querySelectorExt].
  List<Element> querySelectorAllExt(String selector) {
    final results = <Element>[];
    _ExtendedSelectorEvaluator().querySelectorAll(
      this,
      _parse(selector),
      results,
    );
    return results;
  }
}

SelectorGroup _parse(String selector) {
  final errors = <Message>[];
  final group = parseSelectorGroup(selector, errors: errors);
  if (group == null || errors.isNotEmpty) {
    throw FormatException("'$selector' is not a valid selector: $errors");
  }
  return group;
}

class _ExtendedSelectorEvaluator extends Visitor {
  Element? _element;

  bool matches(Element element, SelectorGroup selector) {
    _element = element;
    return visitSelectorGroup(selector);
  }

  Element? querySelector(Node root, SelectorGroup selector) {
    for (final element in root.nodes.whereType<Element>()) {
      if (matches(element, selector)) return element;
      final result = querySelector(element, selector);
      if (result != null) return result;
    }
    return null;
  }

  void querySelectorAll(
    Node root,
    SelectorGroup selector,
    List<Element> results,
  ) {
    for (final element in root.nodes.whereType<Element>()) {
      if (matches(element, selector)) results.add(element);
      querySelectorAll(element, selector, results);
    }
  }

  // --- Combinators (ported as-is from package:html's SelectorEvaluator;
  // this part was never broken) ---

  @override
  bool visitSelectorGroup(SelectorGroup node) =>
      node.selectors.any(visitSelector);

  @override
  bool visitSelector(Selector node) {
    final old = _element;
    var result = true;

    int? combinator;
    for (final s in node.simpleSelectorSequences.reversed) {
      if (combinator == null) {
        result = s.simpleSelector.visit(this) as bool;
      } else {
        if (combinator == TokenKind.COMBINATOR_DESCENDANT) {
          do {
            _element = _element!.parent;
          } while (_element != null && !(s.simpleSelector.visit(this) as bool));
          if (_element == null) result = false;
        } else if (combinator == TokenKind.COMBINATOR_TILDE) {
          do {
            _element = _element!.previousElementSibling;
          } while (_element != null && !(s.simpleSelector.visit(this) as bool));
          if (_element == null) result = false;
        }
        combinator = null;
      }

      if (!result) break;

      switch (s.combinator) {
        case TokenKind.COMBINATOR_PLUS:
          _element = _element!.previousElementSibling;
        case TokenKind.COMBINATOR_GREATER:
          _element = _element!.parent;
        case TokenKind.COMBINATOR_DESCENDANT:
        case TokenKind.COMBINATOR_TILDE:
          combinator = s.combinator;
        case TokenKind.COMBINATOR_NONE:
          break;
        default:
          throw FormatException("'$node' is not a valid selector");
      }

      if (_element == null) {
        result = false;
        break;
      }
    }

    _element = old;
    return result;
  }

  // --- Basic selectors (ported as-is) ---

  @override
  bool visitNamespaceSelector(NamespaceSelector node) {
    if (!(node.nameAsSimpleSelector!.visit(this) as bool)) return false;
    if (node.isNamespaceWildcard) return true;
    if (node.namespace == '') return _element!.namespaceUri == null;
    throw UnimplementedError("namespace '${node.namespace}' is not supported");
  }

  @override
  bool visitElementSelector(ElementSelector node) =>
      node.isWildcard || _element!.localName == node.name.toLowerCase();

  @override
  bool visitIdSelector(IdSelector node) => _element!.id == node.name;

  @override
  bool visitClassSelector(ClassSelector node) =>
      _element!.classes.contains(node.name);

  @override
  bool visitNegationSelector(NegationSelector node) =>
      !(node.negationArg!.visit(this) as bool);

  @override
  bool visitAttributeSelector(AttributeSelector node) {
    final value = _element!.attributes[node.name.toLowerCase()];
    if (value == null) return false;
    if (node.operatorKind == TokenKind.NO_MATCH) return true;

    final select = '${node.value}';
    return switch (node.operatorKind) {
      TokenKind.EQUALS => value == select,
      TokenKind.INCLUDES =>
        value.split(' ').any((v) => v.isNotEmpty && v == select),
      TokenKind.DASH_MATCH =>
        value.startsWith(select) &&
            (value.length == select.length || value[select.length] == '-'),
      TokenKind.PREFIX_MATCH => value.startsWith(select),
      TokenKind.SUFFIX_MATCH => value.endsWith(select),
      TokenKind.SUBSTRING_MATCH => value.contains(select),
      _ => throw FormatException("'$node' is not a valid selector"),
    };
  }

  @override
  bool visitPseudoElementSelector(PseudoElementSelector node) {
    // :before/:after/:first-line/:first-letter can't match a real element.
    if (legacyPseudoElements.contains(node.name)) return false;
    throw UnimplementedError("'::${node.name}' is not implemented");
  }

  @override
  bool visitPseudoElementFunctionSelector(PseudoElementFunctionSelector node) =>
      throw UnimplementedError("'::${node.name}()' is not implemented");

  // --- Pseudo-classes: parity cases + newly implemented ones ---

  @override
  bool visitPseudoClassSelector(PseudoClassSelector node) {
    final el = _element!;
    switch (node.name) {
      case 'root':
        return el.localName == 'html' && el.parentNode == null;
      case 'empty':
        return el.nodes.every(
          (n) => !(n is Element || (n is Text && n.text.isNotEmpty)),
        );
      case 'first-child':
        return el.previousElementSibling == null;
      case 'last-child':
        return el.nextElementSibling == null;
      case 'only-child':
        return el.previousElementSibling == null &&
            el.nextElementSibling == null;
      // Newly implemented: the *-of-type family.
      case 'first-of-type':
        return _indexOfType(el) == 1;
      case 'last-of-type':
        return _indexOfType(el) == _siblingsOfType(el).length;
      case 'only-of-type':
        return _siblingsOfType(el).length == 1;
      case 'link':
        return el.attributes['href'] != null;
      case 'visited':
        return false;
    }
    if (legacyPseudoElements.contains(node.name)) return false;
    throw UnimplementedError("':${node.name}' is not implemented");
  }

  @override
  bool visitPseudoClassFunctionSelector(PseudoClassFunctionSelector node) {
    final el = _element!;
    switch (node.name) {
      case 'lang':
        final toMatch = node.expression.span.text;
        final lang = _inheritedLanguage(el);
        return lang != null && lang.startsWith(toMatch);

      // Newly implemented below. `:contains()` is a jQuery/Sizzle
      // extension, not part of the CSS spec, but csslib parses arbitrary
      // `:name(...)` functions generically so it comes through fine.
      case 'contains':
        final needle = _unquote(node.expression.span.text.trim());
        return el.text.contains(needle);

      case 'nth-child':
        return _matchesAnB(node, _indexAmongSiblings(el));
      case 'nth-last-child':
        final total = el.parent?.children.length ?? 1;
        return _matchesAnB(node, total - _indexAmongSiblings(el) + 1);
      case 'nth-of-type':
        return _matchesAnB(node, _indexOfType(el));
      case 'nth-last-of-type':
        final total = _siblingsOfType(el).length;
        return _matchesAnB(node, total - _indexOfType(el) + 1);
    }
    throw UnimplementedError("':${node.name}()' is not implemented");
  }

  // --- helpers ---

  static String? _inheritedLanguage(Node? node) {
    while (node != null) {
      final lang = node.attributes['lang'];
      if (lang != null) return lang;
      node = node.parent;
    }
    return null;
  }

  static String _unquote(String s) {
    if (s.length >= 2 &&
        ((s.startsWith("'") && s.endsWith("'")) ||
            (s.startsWith('"') && s.endsWith('"')))) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /// 1-indexed position among element siblings (unlike package:html's own
  /// `nth-child`, which indexes `parent.nodes` and so miscounts against
  /// whitespace text nodes between tags in non-minified HTML).
  static int _indexAmongSiblings(Element el) {
    final parent = el.parent;
    if (parent == null) return 1;
    return parent.children.indexOf(el) + 1;
  }

  static List<Element> _siblingsOfType(Element el) {
    final parent = el.parent;
    if (parent == null) return [el];
    return parent.children.where((c) => c.localName == el.localName).toList();
  }

  static int _indexOfType(Element el) => _siblingsOfType(el).indexOf(el) + 1;

  static bool _matchesAnB(PseudoClassFunctionSelector node, int position) {
    final anb = parseAnB(node.expression.span.text);
    if (anb == null) return false;
    final (a, b) = anb;
    if (a == 0) return position == b;
    final k = (position - b) / a;
    return k >= 0 && k == k.truncateToDouble();
  }
}

/// Parses the CSS `An+B` micro-grammar: `odd`, `even`, a bare integer (`B`),
/// or `An+B` / `An-B` / `-An+B` / `n` / `-n` forms. Returns null for anything
/// else, which every `nth-*()` case treats as "matches nothing" rather than
/// an error (mirroring how a browser treats an unparseable An+B argument).
///
/// csslib tokenizes e.g. `2n+1` into several separate expression terms
/// rather than a single literal, so (the same way package:html's own
/// evaluator works around csslib's tokenizer for `:lang()`) this reads the
/// raw argument text instead of decoding the term list. Exported (alongside
/// [supportedPseudoClasses]) so a selector lint can determine "this nth-*()
/// argument can never match anything" statically, without evaluating
/// against a DOM.
(int, int)? parseAnB(String raw) {
  final text = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (text == 'odd') return (2, 1);
  if (text == 'even') return (2, 0);

  final match = RegExp(r'^([+-]?\d*n)?([+-]?\d+)?$').firstMatch(text);
  if (match == null || (match.group(1) == null && match.group(2) == null)) {
    return null;
  }

  var a = 0;
  final aTerm = match.group(1);
  if (aTerm != null) {
    final digits = aTerm.substring(0, aTerm.length - 1); // strip 'n'
    a = switch (digits) {
      '' || '+' => 1,
      '-' => -1,
      _ => int.parse(digits),
    };
  }
  final b = match.group(2) == null ? 0 : int.parse(match.group(2)!);
  return (a, b);
}
