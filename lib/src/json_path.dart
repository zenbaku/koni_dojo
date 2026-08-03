/// Minimal JSON path evaluation for declarative API sources, the JSON
/// equivalent of the CSS selectors HTML configs use.
///
/// Grammar, by example against a typical JSON:API-style response:
///
/// - `data`                         map key
/// - `attributes.title.en`         nested keys
/// - `attributes.title.*`          first value of a map / first list element
/// - `data[0]`                     list index
/// - `relationships[type=author]`  first list element whose `type` equals
///                                 the literal (the key may be a dotted
///                                 path itself)
///
/// Every miss (absent key, wrong type, out-of-range index, no matching
/// element) resolves to null rather than throwing, so configs degrade
/// like missing CSS selectors do.
library;

Object? readJsonPath(Object? root, String path) {
  var current = root;
  for (final segment in path.split('.')) {
    if (current == null) return null;
    current = _readSegment(current, segment);
  }
  return current;
}

final _segmentPattern = RegExp(r'^([^\[\]]*)((?:\[[^\]]*\])*)$');
final _bracketPattern = RegExp(r'\[([^\]]*)\]');

Object? _readSegment(Object? current, String segment) {
  final match = _segmentPattern.firstMatch(segment);
  if (match == null) return null;
  final name = match.group(1)!;
  if (name.isNotEmpty) {
    current = _readName(current, name);
  }
  for (final bracket in _bracketPattern.allMatches(match.group(2)!)) {
    current = _readBracket(current, bracket.group(1)!);
  }
  return current;
}

Object? _readName(Object? current, String name) {
  if (name == '*') {
    return switch (current) {
      Map(values: final values) => values.firstOrNull,
      List list => list.firstOrNull,
      _ => null,
    };
  }
  return current is Map ? current[name] : null;
}

Object? _readBracket(Object? current, String selector) {
  if (current is! List) return null;
  final index = int.tryParse(selector);
  if (index != null) {
    return index >= 0 && index < current.length ? current[index] : null;
  }
  final equals = selector.indexOf('=');
  if (equals <= 0) return null;
  final key = selector.substring(0, equals);
  final wanted = selector.substring(equals + 1);
  for (final element in current) {
    if ('${readJsonPath(element, key)}' == wanted) return element;
  }
  return null;
}

/// Renders a `{placeholder}` template. `{value}` becomes [value]; any other
/// placeholder is looked up in [vars], then as a JSON path against [item],
/// then against [root]. A placeholder that resolves to nothing throws a
/// [FormatException] naming it; a malformed API response must fail the
/// fetch, not produce broken URLs.
String renderJsonTemplate(
  String template, {
  String? value,
  Object? item,
  Map<String, String> vars = const {},
  Object? root,
}) {
  return template.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
    final name = match.group(1)!;
    if (name == 'value' && value != null) return value;
    final fromVars = vars[name];
    if (fromVars != null) return fromVars;
    final resolved = readJsonPath(item, name) ?? readJsonPath(root, name);
    if (resolved == null || resolved is Map || resolved is List) {
      throw FormatException('Missing "$name" in the source response');
    }
    return '$resolved';
  });
}
