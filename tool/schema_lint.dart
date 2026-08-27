/// Validates one extension file against `docs/source-config.schema.json`, the
/// same document a config author's editor reads, so the two can never disagree
/// about what a config may contain.
///
/// **This checks the half the engine cannot.** `build_repo.dart` already parses
/// every entry through the real models, which catches a field of the wrong
/// type or a missing required one — but an *unknown* key is not an error to a
/// `fromJson`, it is simply never read. A misspelled `itemSelctor` inside a
/// listing block parses fine, ships fine, and produces an empty catalogue on a
/// real site with nothing anywhere to say why. The schema declares
/// `additionalProperties: false` at every level, so validating against it is
/// what turns that silence into a failed build.
///
/// It is also the gate that was missing when a field the engine had gained
/// (`imageRateLimit`) went unrecorded in the schema: nothing compared the two,
/// so a published config used a key the published schema called invalid, with
/// every suite green.
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';

/// The compiled schema, plus a compiled view of each source dialect.
///
/// The dialect views exist for error messages, not for correctness. The
/// top-level schema reaches a source through a `oneOf` over the two dialects,
/// and a `oneOf` that fails reports only that no branch matched — "violated No
/// element", which tells an author nothing. Re-validating a source against the
/// dialect it actually declares recovers the real complaint ("Additional
/// properties are not allowed ('latest')"), because there is no longer a
/// branch to choose between.
class ExtensionSchema {
  ExtensionSchema._(this._document, this._html, this._api);

  final JsonSchema _document;
  final JsonSchema _html;
  final JsonSchema _api;

  /// Compiles the schema at [path]. Do this once per run — compilation walks
  /// the whole document, and the build validates a few hundred files.
  factory ExtensionSchema.load(String path) {
    final root = jsonDecode(File(path).readAsStringSync());
    final defs = (root as Map<String, dynamic>)[r'$defs'];
    JsonSchema dialect(String name) => JsonSchema.create({
      r'$ref': '#/\$defs/$name',
      r'$defs': defs,
    }, schemaVersion: SchemaVersion.draft2020_12);
    return ExtensionSchema._(
      JsonSchema.create(root, schemaVersion: SchemaVersion.draft2020_12),
      dialect('sourceConfig'),
      dialect('apiSourceConfig'),
    );
  }

  /// The dialect [source] claims to be. The schema discriminates on `type`
  /// exactly this way (`"api"` selects the API dialect; the HTML dialect
  /// asserts `type` is absent), so this picks the branch the author meant
  /// rather than guessing at the one that fits best.
  JsonSchema _dialectOf(Object? source) =>
      (source is Map && source['type'] == 'api') ? _api : _html;
}

/// Every way [extensionJson] disagrees with the schema, as messages an author
/// can act on. Empty when it validates.
///
/// [fileLabel] is unused in the messages themselves — the caller prefixes them
/// with the filename, the way the other gates in `build_repo.dart` do — and is
/// kept in the signature so this reads like `lintExtensionSelectors` at the
/// call site.
List<String> lintExtensionSchema(
  Map<String, dynamic> extensionJson,
  String fileLabel,
  ExtensionSchema schema,
) {
  final result = schema._document.validate(extensionJson);
  if (result.isValid) return const [];

  /* Sources first, and usually last: nearly every real failure is inside one,
   * and only here is the message specific enough to fix. */
  final issues = <String>[];
  final sources = extensionJson['sources'];
  if (sources is List) {
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final errors = schema._dialectOf(source).validate(source).errors;
      for (final e in errors) {
        issues.add('sources[$i]${e.instancePath}: ${e.message}');
      }
    }
  }
  if (issues.isNotEmpty) return issues;

  /* Every source validated on its own, so the disagreement is with the
   * envelope around them — a bad `pkg`, a missing `name`. The raw errors are
   * readable here because nothing above this level is a `oneOf`. */
  return [for (final e in result.errors) '${e.instancePath}: ${e.message}'];
}
