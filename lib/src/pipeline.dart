import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'crypto_decrypt.dart';
import 'extended_selectors.dart';
import 'extension_models.dart';
import 'js_runner.dart';
import 'json_path.dart';
import 'parse_isolate.dart';

/// Thrown when a pipeline reaches a [JsStep] but no [JsRunner] was injected
/// (web, tests, or an app build without a JS runtime). Surfaces a clear error
/// rather than silently producing empty results, the same contract the
/// imperative sources that need JS already have.
class JsUnavailable implements Exception {
  const JsUnavailable();
  @override
  String toString() =>
      'JsUnavailable: this source has a JS step but no JavaScript runtime is '
      'available here.';
}

/// One step's diagnostics, emitted while a pipeline runs inside [runWithTrace]:
/// the resolved request, the vars it captured, and a preview of the body it
/// parsed. Powers the Extension Lab's step-by-step view; a no-op in production
/// (nothing reads the trace unless a sink is installed).
class StepTrace {
  StepTrace({
    required this.index,
    this.requestUrl,
    this.method = 'GET',
    this.captured = const {},
    this.bodyPreview = '',
    this.body = '',
    this.terminal = false,
  });

  /// 0-based position of the step in its pipeline.
  final int index;

  /// The resolved request URL, or null when the step reused the prior body.
  final String? requestUrl;
  final String method;

  /// Scalars this (intermediate) step captured for later steps; empty on the
  /// terminal step.
  final Map<String, String> captured;

  /// A truncated preview of the body this step parsed (for a collapsed view).
  final String bodyPreview;

  /// The full body this step parsed, for on-demand inspection. Held only while
  /// a trace sink is installed (the Lab), so the cost is debug-time only.
  final String body;

  /// Whether this is the yielding (result-producing) step.
  final bool terminal;
}

const _traceKey = #konimangaStepTrace;

/// Runs [body] with [sink] receiving a [StepTrace] for every pipeline step it
/// triggers; the runners read this ambient sink, so no production API carries a
/// trace parameter.
Future<T> runWithTrace<T>(
  void Function(StepTrace) sink,
  Future<T> Function() body,
) => runZoned(body, zoneValues: {_traceKey: sink});

void _emitTrace(StepTrace trace) {
  final sink = Zone.current[_traceKey];
  if (sink is void Function(StepTrace)) sink(trace);
}

/// A short, single-line-ish preview of a fetched body for the trace.
String _preview(String body) {
  final trimmed = body.trimLeft();
  return trimmed.length > 500 ? '${trimmed.substring(0, 500)}…' : trimmed;
}

/// A linear pipeline: an ordered list of [Step]s that thread captured variables
/// forward. Each operation (pages, chapters, …) of a declarative source
/// compiles to one of these.
///
/// This is the unifying model behind the two scraping dialects: a step makes a
/// request, parses the response in *its own* format ([StepParse]), and either
/// captures scalars for later steps or yields the operation's result. A pure
/// single-request HTML source is a one-step pipeline; a two-phase id-lookup
/// (Madara) or a cross-format hop (HTML page → id → JSON ajax) is two steps
/// differing only in a step's [StepParse]. There is deliberately no control
/// flow: execution walks the steps once, top to bottom. See
/// `docs/source-pipeline-engine.md`.
class Pipeline {
  const Pipeline(this.steps);

  factory Pipeline.fromJson(List<dynamic> json) => Pipeline([
    for (final s in json) Step.fromJson(s as Map<String, dynamic>),
  ]);

  final List<Step> steps;

  List<dynamic> toJson() => [for (final s in steps) s.toJson()];
}

/// How a [Step] reads its response body before extraction.
enum StepParse {
  /// Parse as an HTML document; locators are CSS [Locator.selector] + attr.
  html,

  /// Parse as JSON; locators are [Locator.path] + [Locator.template].
  json,

  /// Pull a JSON blob out of a larger body with [Step.regex] (group 1 is the
  /// JSON text), then treat it as [json], e.g. MangaThemesia's `ts_reader.run`.
  regexJson,

  /// Decode the body as JSON, lift the HTML string at [Step.htmlFrom], and parse
  /// *that* as an HTML document, for AJAX endpoints that wrap an HTML fragment
  /// in a JSON envelope (`{"html": "<div…", "totalPages": 9}`).
  jsonHtml;

  static StepParse fromName(String name) => switch (name) {
    'json' => StepParse.json,
    'regexJson' => StepParse.regexJson,
    'jsonHtml' => StepParse.jsonHtml,
    _ => StepParse.html,
  };

  String get name => switch (this) {
    StepParse.json => 'json',
    StepParse.regexJson => 'regexJson',
    StepParse.jsonHtml => 'jsonHtml',
    StepParse.html => 'html',
  };
}

/// One hop of a [Pipeline]: fetch ([request]), parse ([parse]/[regex]), then
/// either [capture] scalars for later steps or [output] the result list. An
/// intermediate step carries [capture]; the terminal step carries [output].
class Step {
  const Step({
    this.request,
    this.js,
    this.decrypt,
    this.parse = StepParse.html,
    this.regex = '',
    this.htmlFrom = '',
    this.capture = const {},
    this.output,
  });

  factory Step.fromJson(Map<String, dynamic> json) => Step(
    request: json['request'] == null
        ? null
        : StepRequest.fromJson(json['request'] as Map<String, dynamic>),
    js: json['js'] == null
        ? null
        : JsStep.fromJson(json['js'] as Map<String, dynamic>),
    decrypt: json['decrypt'] == null
        ? null
        : DecryptStep.fromJson(json['decrypt'] as Map<String, dynamic>),
    parse: StepParse.fromName(json['parse'] as String? ?? 'html'),
    regex: json['regex'] as String? ?? '',
    htmlFrom: json['htmlFrom'] as String? ?? '',
    capture: (json['capture'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, Locator.fromJson(v as Map<String, dynamic>)),
    ),
    output: json['yield'] == null
        ? null
        : StepOutput.fromJson(json['yield'] as Map<String, dynamic>),
  );

  /// Where to fetch; null reuses the previous step's response body.
  final StepRequest? request;

  /// A compute step: run JS in the injected [JsRunner] and capture its result,
  /// instead of fetching. Mutually exclusive with [request] on the same step.
  final JsStep? js;

  /// A compute step: decrypt an already-captured ciphertext blob instead of
  /// fetching. Mutually exclusive with [request]/[js] on the same step; see
  /// [DecryptStep].
  final DecryptStep? decrypt;
  final StepParse parse;

  /// First capture group yields the JSON text when [parse] is [StepParse.regexJson].
  final String regex;

  /// JSON path to the HTML string when [parse] is [StepParse.jsonHtml].
  final String htmlFrom;

  /// Scalars threaded into later steps' templates (`{name}` placeholders).
  final Map<String, Locator> capture;

  /// The result producer; present only on the terminal step. When paired with
  /// [decrypt] (no [request]), the decrypted plaintext stands in for a
  /// fetched body; [parse]/[regex] then extract from *that*, same as any
  /// other terminal step.
  final StepOutput? output;

  Map<String, dynamic> toJson() => {
    if (request != null) 'request': request!.toJson(),
    if (js != null) 'js': js!.toJson(),
    if (decrypt != null) 'decrypt': decrypt!.toJson(),
    if (parse != StepParse.html) 'parse': parse.name,
    if (regex.isNotEmpty) 'regex': regex,
    if (htmlFrom.isNotEmpty) 'htmlFrom': htmlFrom,
    if (capture.isNotEmpty)
      'capture': capture.map((k, v) => MapEntry(k, v.toJson())),
    if (output != null) 'yield': output!.toJson(),
  };
}

/// A compute step: decrypt [data] (an already-captured `{ct, iv, s}` JSON
/// blob, see [decryptAesJson]) with [password], both `{var}` templates
/// resolved from the threaded vars. On an intermediate step the plaintext is
/// stored in [capture]; paired with [Step.output] on the terminal step, it
/// stands in for a fetched body instead.
class DecryptStep {
  const DecryptStep({
    required this.data,
    required this.password,
    this.capture = '',
  });

  factory DecryptStep.fromJson(Map<String, dynamic> json) => DecryptStep(
    data: json['data'] as String? ?? '',
    password: json['password'] as String? ?? '',
    capture: json['capture'] as String? ?? '',
  );

  final String data;
  final String password;
  final String capture;

  Map<String, dynamic> toJson() => {
    'data': data,
    'password': password,
    if (capture.isNotEmpty) 'capture': capture,
  };
}

/// A compute step: evaluate [code] in the injected [JsRunner] and thread the
/// result into later steps. [args] are `{var}` templates resolved from the
/// current vars, JSON-encoded, and exposed to the code as the global `$`; data
/// crosses the boundary as data (no structural injection). Site-supplied code
/// runs only where the author writes `eval($.something)`. The string result is
/// stored in [capture]; or, when it's a JSON object, [captureJson] parses it and
/// stores several vars by path.
class JsStep {
  const JsStep({
    required this.code,
    this.args = const {},
    this.capture = '',
    this.captureJson = const {},
  });

  factory JsStep.fromJson(Map<String, dynamic> json) => JsStep(
    code: json['code'] as String? ?? '',
    args: (json['args'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, '$v'),
    ),
    capture: json['capture'] as String? ?? '',
    captureJson: (json['captureJson'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, '$v'),
    ),
  );

  final String code;
  final Map<String, String> args;
  final String capture;
  final Map<String, String> captureJson;

  Map<String, dynamic> toJson() => {
    'code': code,
    if (args.isNotEmpty) 'args': args,
    if (capture.isNotEmpty) 'capture': capture,
    if (captureJson.isNotEmpty) 'captureJson': captureJson,
  };
}

/// A step's request target. Two ways to specify it:
///  - [transform] + [base]: apply [RequestTransform] semantics to the variable
///    named [base], the bridge that lets today's configs desugar onto the
///    pipeline without re-encoding their URL rewrites.
///  - [url] template: `{var}` placeholders resolved from the threaded vars,
///    the explicit-steps form.
class StepRequest {
  const StepRequest({
    this.url = '',
    this.method = 'GET',
    this.body = '',
    this.headers = const {},
    this.transform,
    this.base = '',
  });

  factory StepRequest.fromJson(Map<String, dynamic> json) => StepRequest(
    url: json['url'] as String? ?? '',
    method: (json['method'] as String? ?? 'GET').toUpperCase(),
    body: json['body'] as String? ?? '',
    headers: (json['headers'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
  );

  final String url;
  final String method;
  final String body;
  final Map<String, String> headers;

  /// Non-null only for desugared configs: reuses the existing rewrite/POST
  /// machinery rather than re-expressing it as a template.
  final RequestTransform? transform;

  /// The variable [transform] applies to (e.g. `chapterUrl`).
  final String base;

  Map<String, dynamic> toJson() => {
    if (url.isNotEmpty) 'url': url,
    if (method != 'GET') 'method': method,
    if (body.isNotEmpty) 'body': body,
    if (headers.isNotEmpty) 'headers': headers,
  };
}

/// Extraction of one value from a parsed response, polymorphic over the step's
/// format: under HTML, [selector] + [attr] (empty attr = element text, empty
/// selector = the root); under JSON, [path] + [template] (`{value}` = the
/// located node). [imageFallback] mirrors the scraper's lazy-load tolerance:
/// fall back to `data-src` when [attr] is absent, holds an inline `data:`
/// placeholder, or (see `_valueFromElement`) is a value repeated across
/// other items in the same list, the shape a themed loading-spinner asset
/// takes when it isn't a `data:` URI.
class Locator {
  const Locator({
    this.selector = '',
    this.attr = '',
    this.path = '',
    this.template = '',
    this.regex = '',
    this.from = '',
    this.imageFallback = false,
    this.exists = false,
    this.values = false,
    this.encode = false,
    this.rewrite,
    this.fallbacks = const [],
  });

  factory Locator.fromJson(Map<String, dynamic> json) => Locator(
    selector: json['selector'] as String? ?? '',
    attr: json['attr'] as String? ?? '',
    path: json['path'] as String? ?? '',
    template: json['template'] as String? ?? '',
    regex: json['regex'] as String? ?? '',
    from: json['from'] as String? ?? '',
    imageFallback: json['imageFallback'] as bool? ?? false,
    exists: json['exists'] as bool? ?? false,
    values: json['values'] as bool? ?? false,
    encode: json['encode'] as bool? ?? false,
    rewrite: json['rewrite'] == null
        ? null
        : ValueRewrite.fromJson(json['rewrite'] as Map<String, dynamic>),
    fallbacks: [
      for (final f in (json['fallbacks'] as List<dynamic>? ?? const []))
        Locator.fromJson(f as Map<String, dynamic>),
    ],
  );

  final String selector;
  final String attr;
  final String path;
  final String template;

  /// A regex whose first capture group is the value, matched against the raw
  /// response body (or the [from] var, when set), independent of
  /// [selector]/[path]. Yields values that live in inline script/JS literals (a
  /// `String.fromCharCode(…)` blob, a `totalPages: 12`) that no selector or JSON
  /// path can reach. Takes precedence over [selector]/[path] when set.
  final String regex;

  /// For a [regex] capture: match against this threaded var instead of the
  /// response body, e.g. splitting a composite ref (`chapterId#seriesId`) back
  /// into parts. Empty = match the body.
  final String from;
  final bool imageFallback;

  /// Presence check: yields `"1"` when the element/node is found, `""` otherwise,
  /// used for a listing's has-next flag and other "does this exist" meta.
  final bool exists;

  /// On a list locator: when the resolved JSON node is an object, iterate its
  /// *values* as the list, object-keyed collections (`{"1":{…},"2":{…}}`).
  final bool values;

  /// On a capture locator: URL-encode the captured value (a path-segment
  /// component) before it is threaded into a later step's request, for ids or
  /// labels carrying spaces/punctuation (`data-label="BEN 10"`).
  final bool encode;

  /// Applied to the located value when non-empty, the per-step rewrite a cover
  /// chain carries (e.g. a `small`→`normal` swap, a protocol fixup).
  final ValueRewrite? rewrite;

  /// Tried in order when this locator yields nothing; the first non-empty wins.
  /// Lets one locator express a cover chain (several selector/attr candidates).
  final List<Locator> fallbacks;

  Map<String, dynamic> toJson() => {
    if (selector.isNotEmpty) 'selector': selector,
    if (attr.isNotEmpty) 'attr': attr,
    if (path.isNotEmpty) 'path': path,
    if (template.isNotEmpty) 'template': template,
    if (regex.isNotEmpty) 'regex': regex,
    if (from.isNotEmpty) 'from': from,
    if (imageFallback) 'imageFallback': true,
    if (exists) 'exists': true,
    if (values) 'values': true,
    if (encode) 'encode': true,
    if (rewrite != null) 'rewrite': rewrite!.toJson(),
    if (fallbacks.isNotEmpty)
      'fallbacks': [for (final f in fallbacks) f.toJson()],
  };
}

/// The terminal step's result producer, in one of three shapes:
///  - **flat list**: [list] locates a collection and [value] turns each
///    element into a string (page image URLs);
///  - **record list**: [list] + [fields] produce one record (`{key: value}`)
///    per element (listings, chapters);
///  - **single record**: [fields] with no [list] produce one record (details).
///
/// [list] locates the collection (HTML selector → elements, JSON path → array);
/// each field/value [Locator] extracts from one element. [fields] non-empty
/// selects the record shapes; otherwise [value] selects the flat shape.
class StepOutput {
  const StepOutput({
    this.list = const Locator(),
    this.value = const Locator(),
    this.fields = const {},
    this.meta = const {},
    this.count = const Locator(),
    this.start = 1,
    this.pad = 0,
    this.paginate,
  });

  factory StepOutput.fromJson(Map<String, dynamic> json) => StepOutput(
    list: json['list'] == null
        ? const Locator()
        : Locator.fromJson(json['list'] as Map<String, dynamic>),
    value: json['value'] == null
        ? const Locator()
        : Locator.fromJson(json['value'] as Map<String, dynamic>),
    fields: (json['fields'] as Map<String, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(k, Locator.fromJson(v as Map<String, dynamic>)),
    ),
    meta: (json['meta'] as Map<String, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(k, Locator.fromJson(v as Map<String, dynamic>)),
    ),
    count: json['count'] == null
        ? const Locator()
        : Locator.fromJson(json['count'] as Map<String, dynamic>),
    start: json['start'] as int? ?? 1,
    pad: json['pad'] as int? ?? 0,
    paginate: json['paginate'] == null
        ? null
        : Pagination.fromJson(json['paginate'] as Map<String, dynamic>),
  );

  final Locator list;
  final Locator value;

  /// Per-field locators for a record output; empty for the flat [value] shape.
  final Map<String, Locator> fields;

  /// Document/root-level locators read once from the terminal response (e.g. a
  /// listing's has-next flag, a total count), returned in [RecordList.meta].
  final Map<String, Locator> meta;

  /// Page-count locator for the **generate** flat shape: readers that report a
  /// count and a URL template (no per-page tags). When set, [value]'s template
  /// is rendered for each index `{n}` in `[start, start+count)`.
  final Locator count;
  final int start;

  /// Zero-pad `{n}` to this width in the **generate** template; 0 leaves it
  /// bare, which is what every existing config wants.
  ///
  /// Not cosmetic. A reader whose page list exists only as a count plus a URL
  /// shape can be scraped without a browser at all — but only if the shape is
  /// reproduced exactly, and a host that writes `p0001.jpg` will not answer
  /// `p1.jpg`. Without this such a source has to be rendered, and one that
  /// also lazy-loads its images then yields whatever happened to be near the
  /// viewport rather than the chapter.
  final int pad;

  /// For a **record** output (chapters/listings) whose source paginates
  /// server-side with no single "give me everything" request: re-runs this
  /// step, incrementing a page var, merging each page's records, until
  /// [Pagination.currentPageMeta]/[Pagination.lastPageMeta] (read from [meta])
  /// say there's nothing left. Null means one request, one page, as before.
  final Pagination? paginate;

  Map<String, dynamic> toJson() => {
    if (list.toJson().isNotEmpty) 'list': list.toJson(),
    if (fields.isEmpty) 'value': value.toJson(),
    if (fields.isNotEmpty)
      'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
    if (meta.isNotEmpty) 'meta': meta.map((k, v) => MapEntry(k, v.toJson())),
    if (count.toJson().isNotEmpty) 'count': count.toJson(),
    if (start != 1) 'start': start,
    if (pad != 0) 'pad': pad,
    if (paginate != null) 'paginate': paginate!.toJson(),
  };
}

/// Drives a record output's re-fetch loop (see [StepOutput.paginate]).
/// [currentPageMeta]/[lastPageMeta] name keys in [StepOutput.meta], read as
/// integers after each page, so the stopping condition ("current == last")
/// is expressed with the same locator machinery as everything else, not a
/// second parallel one. [pageVar] is the request-template placeholder
/// (`{page}` by default) incremented before each re-fetch; [maxPages] is a
/// hard safety cap against a malformed/misconfigured API paginating forever.
class Pagination {
  const Pagination({
    this.pageVar = 'page',
    this.currentPageMeta = '',
    this.lastPageMeta = '',
    this.hasNextMeta = '',
    this.maxPages = 50,
  });

  factory Pagination.fromJson(Map<String, dynamic> json) => Pagination(
    pageVar: json['pageVar'] as String? ?? 'page',
    currentPageMeta: json['currentPageMeta'] as String? ?? '',
    lastPageMeta: json['lastPageMeta'] as String? ?? '',
    hasNextMeta: json['hasNextMeta'] as String? ?? '',
    maxPages: json['maxPages'] as int? ?? 50,
  );

  final String pageVar;
  final String currentPageMeta;
  final String lastPageMeta;

  /// Alternative to [currentPageMeta]/[lastPageMeta] for a paginator that
  /// doesn't reliably expose a total page count (a Laravel-style widget
  /// truncates to nearby page numbers + first/last, not the true last page,
  /// once there are enough pages) but does mark a "next" link/button's
  /// presence: names a [StepOutput.meta] key holding `"1"`/`""` from an
  /// `exists: true` locator, read the same way a listing's own `hasNext`
  /// meta already is. Takes priority over [currentPageMeta]/[lastPageMeta]
  /// when set.
  final String hasNextMeta;
  final int maxPages;

  Map<String, dynamic> toJson() => {
    if (pageVar != 'page') 'pageVar': pageVar,
    'currentPageMeta': currentPageMeta,
    'lastPageMeta': lastPageMeta,
    if (hasNextMeta.isNotEmpty) 'hasNextMeta': hasNextMeta,
    if (maxPages != 50) 'maxPages': maxPages,
  };
}

/// Whether [Pagination] says another page follows, given the terminal step's
/// extracted [meta], shared by every paginated pipeline flavor
/// (record-list chapters/listings, flat-list pages) so the stopping
/// condition has one implementation.
bool _hasNextPage(Pagination p, Map<String, String> meta) {
  if (p.hasNextMeta.isNotEmpty) return meta[p.hasNextMeta] == '1';
  final currentPage = int.tryParse(meta[p.currentPageMeta] ?? '');
  final lastPage = int.tryParse(meta[p.lastPageMeta] ?? '');
  return currentPage != null && lastPage != null && currentPage < lastPage;
}

/// Fetches one step's body. Impure (HTTP, runs on the main isolate); supplied
/// by the engine so the pure runner stays isolate-agnostic.
///
/// [document] says whether this step's body is meant to be a *document*, and
/// exists so the engine can decline to render one that isn't. A browser
/// navigation always produces a document — a JSON endpoint opened in a tab
/// comes back wrapped in `<html><body><pre>` — so a `parse: json` step routed
/// through the browser hands the decoder markup, every time. That is a type
/// mismatch rather than a tuning question, which is why the runner answers it
/// rather than the config.
typedef StepFetch =
    Future<String> Function(
      String url, {
      String method,
      String body,
      Map<String, String> headers,
      bool document,
    });

/// Walks [pipeline]'s steps, threading [vars] forward: each step fetches via
/// [fetch] on the calling isolate, then either captures scalars for later steps
/// or hands the terminal body to [onYield]. The parse+extract work is run
/// through [runParse] (by [onYield] and the capture path) so the heavy DOM/JSON
/// work lands off the UI isolate, exactly as the single-request path did. The
/// three public entrypoints below differ only in [onYield] (the result shape).
Future<T> _runPipeline<T>(
  Pipeline pipeline,
  Map<String, String> vars, {
  required String baseUrl,
  required StepFetch fetch,
  required Future<T> Function(String body, Step step, Map<String, String> vars)
  onYield,
  required T empty,
  JsRunner? js,
}) async {
  var current = Map<String, String>.of(vars);
  var lastBody = '';
  for (var index = 0; index < pipeline.steps.length; index++) {
    final step = pipeline.steps[index];
    if (step.js != null) {
      final got = await _runJsStep(step.js!, current, js);
      current = {...current, ...got};
      _emitTrace(
        StepTrace(
          index: index,
          captured: got,
          bodyPreview: _preview(step.js!.code),
          body: step.js!.code,
        ),
      );
      continue;
    }
    if (step.decrypt != null) {
      final plaintext = decryptAesJson(
        _subst(step.decrypt!.data, current),
        _subst(step.decrypt!.password, current),
      );
      if (step.output != null) {
        _emitTrace(
          StepTrace(
            index: index,
            bodyPreview: _preview(plaintext),
            body: plaintext,
            terminal: true,
          ),
        );
        return onYield(plaintext, step, current);
      }
      final got = <String, String>{
        if (step.decrypt!.capture.isNotEmpty) step.decrypt!.capture: plaintext,
      };
      current = {...current, ...got};
      _emitTrace(
        StepTrace(
          index: index,
          captured: got,
          bodyPreview: _preview(plaintext),
          body: plaintext,
        ),
      );
      continue;
    }
    String? reqUrl;
    var method = 'GET';
    if (step.request != null) {
      final req = _resolveRequest(step.request!, current, baseUrl);
      reqUrl = req.url;
      method = req.method;
      lastBody = await fetch(
        req.url,
        method: req.method,
        body: req.body,
        headers: req.headers,
        // A JSON body is the one shape a rendered page cannot be.
        document: step.parse != StepParse.json,
      );
    }
    if (step.output != null) {
      _emitTrace(
        StepTrace(
          index: index,
          requestUrl: reqUrl,
          method: method,
          bodyPreview: _preview(lastBody),
          body: lastBody,
          terminal: true,
        ),
      );
      return onYield(lastBody, step, current);
    }
    final body = lastBody;
    final parse = step.parse;
    final regex = step.regex;
    final caps = step.capture;
    final got = await runParse(
      () => extractCaptures(body, parse, regex, caps, current),
    );
    current = {...current, ...got};
    _emitTrace(
      StepTrace(
        index: index,
        requestUrl: reqUrl,
        method: method,
        captured: got,
        bodyPreview: _preview(body),
        body: body,
      ),
    );
  }
  return empty;
}

/// Evaluates a [JsStep]: resolves [JsStep.args] from [vars], exposes them to the
/// code as the global `$` (JSON-injected), evals, and captures the result.
/// Throws [JsUnavailable] when no runtime is injected.
Future<Map<String, String>> _runJsStep(
  JsStep step,
  Map<String, String> vars,
  JsRunner? js,
) async {
  if (js == null) throw const JsUnavailable();
  final resolvedArgs = {
    for (final e in step.args.entries) e.key: _subst(e.value, vars),
  };
  final prelude = 'const \$ = ${jsonEncode(resolvedArgs)};\n';
  final result = (await js.eval(prelude + step.code)).trim();
  final got = <String, String>{};
  if (step.capture.isNotEmpty) got[step.capture] = result;
  if (step.captureJson.isNotEmpty) {
    Object? decoded;
    try {
      decoded = jsonDecode(result);
    } catch (_) {
      decoded = null;
    }
    step.captureJson.forEach((key, path) {
      final v = decoded == null
          ? null
          : (path.isEmpty ? decoded : readJsonPath(decoded, path));
      got[key] = v == null ? '' : '$v';
    });
  }
  return got;
}

/// The result of a flat-list pipeline: the resolved URL list, plus
/// document-level [meta] read from the terminal response root in the same
/// parse (e.g. a "does another page follow" flag), see [StepOutput.meta].
class FlatList {
  const FlatList(this.list, this.meta);

  final List<String> list;
  final Map<String, String> meta;
}

/// Runs [pipeline] to a flat list of strings (page URLs); see [_runPipeline].
///
/// When the terminal step declares [StepOutput.paginate] (a chapter/album
/// whose full image set spans more than one server-paginated request, no
/// single "give me everything" URL), the whole pipeline re-runs with its
/// page var incremented, concatenating each page's URLs, on the same terms
/// [runRecordListPipeline] already paginates chapters/listings on (see
/// [Pagination]/[_hasNextPage]).
Future<List<String>> runFlatListPipeline(
  Pipeline pipeline,
  Map<String, String> vars, {
  required String baseUrl,
  required StepFetch fetch,
  JsRunner? js,
}) async {
  // `onYield` must not reference `baseUrl` (or anything else pulled from this
  // function's own captured scope); it shares a closure context with
  // `runOnce`, which captures `fetch`, and `fetch` for a real engine closes
  // over rate-limiter/queue state that `Isolate.run` (inside [runParse])
  // refuses to serialize. So resolution against `baseUrl` happens out here,
  // after `runOnce` returns, on raw (unresolved) values, same convention
  // [extractRecordList] already uses for its fields.
  Future<FlatList> runOnce(Map<String, String> current) =>
      _runPipeline<FlatList>(
        pipeline,
        current,
        baseUrl: baseUrl,
        fetch: fetch,
        js: js,
        empty: const FlatList([], {}),
        onYield: (body, step, stepVars) {
          final out = step.output!;
          return runParse(
            () => extractFlatList(body, step.parse, step.regex, out, stepVars),
          );
        },
      );

  Step? terminal;
  for (final step in pipeline.steps) {
    if (step.output != null) {
      terminal = step;
      break;
    }
  }
  final paginate = terminal?.output?.paginate;
  if (paginate == null) {
    return [
      for (final v in (await runOnce(vars)).list) _resolveUrl(baseUrl, v),
    ];
  }

  var current = Map<String, String>.of(vars);
  current.putIfAbsent(paginate.pageVar, () => '1');
  final urls = <String>[];
  for (var page = 1; page <= paginate.maxPages; page++) {
    final result = await runOnce(current);
    urls.addAll(result.list);
    if (!_hasNextPage(paginate, result.meta)) break;
    current = {...current, paginate.pageVar: '${page + 1}'};
  }
  return [for (final v in urls) _resolveUrl(baseUrl, v)];
}

/// The result of a record-list pipeline: a record per matched element, plus
/// document-level [meta] read from the terminal response root in the same parse
/// (a listing's has-next flag, a total count), see [StepOutput.meta].
class RecordList {
  const RecordList(this.records, this.meta);

  final List<Map<String, String>> records;
  final Map<String, String> meta;
}

/// Runs [pipeline] to a list of records (one `{field: value}` map per matched
/// element) for the listing and chapter operations. Values are returned raw;
/// the adapter resolves URL-typed fields against its base URL.
///
/// When the terminal step declares [StepOutput.paginate], one request isn't
/// the whole story: the whole pipeline (cheap capture steps included, they
/// carry no network cost) re-runs with its page var incremented, merging each
/// page's records, until [Pagination.currentPageMeta]/[Pagination.lastPageMeta]
/// agree there's nothing left or [Pagination.maxPages] is hit.
Future<RecordList> runRecordListPipeline(
  Pipeline pipeline,
  Map<String, String> vars, {
  required String baseUrl,
  required StepFetch fetch,
  JsRunner? js,
}) async {
  Future<RecordList> runOnce(Map<String, String> current) =>
      _runPipeline<RecordList>(
        pipeline,
        current,
        baseUrl: baseUrl,
        fetch: fetch,
        js: js,
        empty: const RecordList([], {}),
        onYield: (body, step, stepVars) {
          final out = step.output!;
          return runParse(
            () => extractRecordList(
              body,
              step.parse,
              step.regex,
              out,
              stepVars,
              step.htmlFrom,
            ),
          );
        },
      );

  Step? terminal;
  for (final step in pipeline.steps) {
    if (step.output != null) {
      terminal = step;
      break;
    }
  }
  final paginate = terminal?.output?.paginate;
  if (paginate == null) return runOnce(vars);

  var current = Map<String, String>.of(vars);
  current.putIfAbsent(paginate.pageVar, () => '1');
  final records = <Map<String, String>>[];
  var meta = const <String, String>{};
  for (var page = 1; page <= paginate.maxPages; page++) {
    final result = await runOnce(current);
    records.addAll(result.records);
    meta = result.meta;
    if (!_hasNextPage(paginate, meta)) break;
    current = {...current, paginate.pageVar: '${page + 1}'};
  }
  return RecordList(records, meta);
}

/// Walks [pipeline]'s steps and returns the terminal step's raw response body,
/// for the details operation, whose extraction (flat selectors *and* the
/// label-row metadata that needs the whole document) the adapter parses inline,
/// keeping interactive browsing on the calling isolate as before. Capture steps
/// still thread `{id}`-style vars, so a multi-step details config works here.
Future<String> runBodyPipeline(
  Pipeline pipeline,
  Map<String, String> vars, {
  required String baseUrl,
  required StepFetch fetch,
  JsRunner? js,
}) async {
  var current = Map<String, String>.of(vars);
  var lastBody = '';
  for (var index = 0; index < pipeline.steps.length; index++) {
    final step = pipeline.steps[index];
    if (step.js != null) {
      final got = await _runJsStep(step.js!, current, js);
      current = {...current, ...got};
      _emitTrace(
        StepTrace(
          index: index,
          captured: got,
          bodyPreview: _preview(step.js!.code),
          terminal: index == pipeline.steps.length - 1,
        ),
      );
      continue;
    }
    String? reqUrl;
    var method = 'GET';
    if (step.request != null) {
      final req = _resolveRequest(step.request!, current, baseUrl);
      reqUrl = req.url;
      method = req.method;
      lastBody = await fetch(
        req.url,
        method: req.method,
        body: req.body,
        headers: req.headers,
        // A JSON body is the one shape a rendered page cannot be.
        document: step.parse != StepParse.json,
      );
    }
    final terminal = index == pipeline.steps.length - 1;
    if (step.capture.isEmpty) {
      _emitTrace(
        StepTrace(
          index: index,
          requestUrl: reqUrl,
          method: method,
          bodyPreview: _preview(lastBody),
          body: lastBody,
          terminal: terminal,
        ),
      );
      continue;
    }
    final body = lastBody;
    final parse = step.parse;
    final regex = step.regex;
    final caps = step.capture;
    final got = await runParse(
      () => extractCaptures(body, parse, regex, caps, current),
    );
    current = {...current, ...got};
    _emitTrace(
      StepTrace(
        index: index,
        requestUrl: reqUrl,
        method: method,
        captured: got,
        bodyPreview: _preview(body),
        body: body,
        terminal: terminal,
      ),
    );
  }
  return lastBody;
}

class _ResolvedRequest {
  const _ResolvedRequest(this.url, this.method, this.body, this.headers);
  final String url;
  final String method;
  final String body;
  final Map<String, String> headers;
}

_ResolvedRequest _resolveRequest(
  StepRequest r,
  Map<String, String> vars,
  String baseUrl,
) {
  final String url;
  final String body;
  if (r.transform != null) {
    final src = vars[r.base] ?? '';
    final id = vars['id'] ?? '';
    final t = r.transform!;
    final raw = t.url.isNotEmpty ? t.url : t.apply(src);
    url = _resolveUrl(baseUrl, raw.replaceAll('{id}', id));
    body = t.bodyFor(src).replaceAll('{id}', id);
  } else if (r.url.isNotEmpty) {
    url = _resolveUrl(baseUrl, _subst(r.url, vars));
    body = _subst(r.body, vars);
  } else {
    // No explicit target: fetch the base variable's URL directly.
    url = _resolveUrl(baseUrl, vars[r.base] ?? '');
    body = _subst(r.body, vars);
  }
  return _ResolvedRequest(
    url,
    r.method,
    body,
    r.headers.map((k, v) => MapEntry(k, _subst(v, vars))),
  );
}

/// Substitutes `{key}` placeholders in [template] from [vars].
String _subst(String template, Map<String, String> vars) {
  if (template.isEmpty || !template.contains('{')) return template;
  var out = template;
  vars.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

// ── Pure extractors (top-level, isolate-sendable) ───────────────────────────

/// Decodes a step's body as JSON, lifting [regex]'s first group out first for
/// [StepParse.regexJson]. Returns null when the regex misses or the JSON is
/// malformed, so callers degrade to an empty result.
Object? _decodeStepJson(String body, StepParse parse, String regex) {
  var text = body;
  if (parse == StepParse.regexJson) {
    final re = RegExp(regex, dotAll: true);
    var match = re.firstMatch(body);
    // Some WordPress themes (notably "mangareader") ship the `ts_reader.run(…)`
    // page blob inside a `data:text/javascript;base64,…` <script> rather than
    // inline, so the regex misses the raw HTML. Decode those scripts and retry
    // before giving up. Only on a miss: the common inline case pays nothing.
    if (match == null) {
      final inlined = _decodedDataScripts(body);
      if (inlined.isNotEmpty) match = re.firstMatch(inlined);
    }
    final raw = (match != null && match.groupCount >= 1)
        ? match.group(1)
        : null;
    if (raw == null) return null;
    text = raw;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  // A root that's itself a JSON-encoded string (`"[\"a\",\"b\"]"` rather than
  // `["a","b"]`) means the source double-encoded, seen from a `decrypt` step
  // whose plaintext is a JSON string wrapping the real array (some sites
  // `json_encode()` their page list twice server-side). Keep unwrapping while
  // that holds; bounded since a legitimate root is never itself valid JSON
  // more than once.
  for (var i = 0; i < 5 && decoded is String; i++) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      break;
    }
  }
  return decoded;
}

/// Concatenates the decoded contents of every `data:text/javascript;base64,…`
/// script in [body]. The WP "mangareader" theme hides its `ts_reader.run(…)`
/// page blob in such a script, so a page-body regex must see the decoded form.
/// Returns '' when there are none (or none decode cleanly).
String _decodedDataScripts(String body) {
  final matches = RegExp(
    r'data:text/javascript;base64,([A-Za-z0-9+/=]+)',
  ).allMatches(body);
  if (matches.isEmpty) return '';
  final buffer = StringBuffer();
  for (final match in matches) {
    try {
      buffer.writeln(utf8.decode(base64.decode(match.group(1)!)));
    } catch (_) {
      // Not valid base64/UTF-8. Skip it.
    }
  }
  return buffer.toString();
}

/// Reads the terminal step's flat URL list out of [body], plus document-level
/// [StepOutput.meta] (e.g. a "does another page follow" flag, see
/// [runFlatListPipeline]). The HTML branch mirrors the scraper's lazy-load
/// tolerance (attr → `data-src`); the JSON and regex-JSON branches share
/// [_flatFromJson]. When [StepOutput.count] is set the **generate** shape
/// runs instead: read a page count, render [StepOutput.value]'s template per
/// index `{n}` (over the threaded [vars]), already the full set in one
/// shot, so it carries no meta.
/// Values are returned raw (no URL resolution), same convention as
/// [extractRecordList], so the caller can resolve against its base URL
/// outside of whatever isolate this runs in; see [runFlatListPipeline].
FlatList extractFlatList(
  String body,
  StepParse parse,
  String regex,
  StepOutput out,
  Map<String, String> vars,
) {
  final count = out.count;
  final generate =
      count.selector.isNotEmpty ||
      count.path.isNotEmpty ||
      count.regex.isNotEmpty;
  // A regex count reads the raw body directly (a `totalPages: 12` JS literal),
  // so it works whatever the parse mode.
  if (generate && count.regex.isNotEmpty) {
    final n = int.tryParse(_regexValue(body, count.regex).trim()) ?? 0;
    return FlatList(_generatePages(out, vars, n), const {});
  }
  if (parse == StepParse.html) {
    final doc = html_parser.parse(body);
    if (generate) {
      final root = doc.documentElement;
      final n = root == null
          ? 0
          : int.tryParse(_attrOf(root, count.selector, count.attr).trim()) ?? 0;
      return FlatList(_generatePages(out, vars, n), const {});
    }
    final elements = doc.querySelectorAllExt(out.list.selector);
    // Only worth building when a placeholder could actually be mistaken for
    // a real value (see [_valueFromElement]'s doc comment); every other
    // Locator use (record fields, covers) never sets [imageFallback].
    Map<String, int>? siblingCounts;
    if (out.value.imageFallback) {
      siblingCounts = <String, int>{};
      for (final element in elements) {
        final raw = element.attributes[out.value.attr]?.trim();
        if (raw != null && raw.isNotEmpty) {
          siblingCounts[raw] = (siblingCounts[raw] ?? 0) + 1;
        }
      }
    }
    final urls = <String>[];
    for (final element in elements) {
      final value = _valueFromElement(
        element,
        out.value,
        siblingCounts: siblingCounts,
      );
      if (value.isNotEmpty) urls.add(value);
    }
    // documentElement (not .body): a meta locator can target <head> content.
    final root = doc.documentElement;
    final meta = (out.meta.isEmpty || root == null)
        ? const <String, String>{}
        : _recordFromElement(root, out.meta, vars);
    return FlatList(urls, meta);
  }
  final decoded = _decodeStepJson(body, parse, regex);
  if (decoded == null) return const FlatList([], {});
  if (generate) {
    final raw = count.path.isEmpty
        ? decoded
        : readJsonPath(decoded, count.path);
    final n = raw is num ? raw.toInt() : (int.tryParse('$raw'.trim()) ?? 0);
    return FlatList(_generatePages(out, vars, n), const {});
  }
  final urls = _flatFromJson(decoded, out, vars);
  final meta = out.meta.isEmpty
      ? const <String, String>{}
      : _recordFromJson(decoded, out.meta, decoded, vars);
  return FlatList(urls, meta);
}

/// Generates [count] page URLs from [StepOutput.value]'s template, substituting
/// the threaded [vars] plus `{n}` for each index in `[start, start+count)`.
List<String> _generatePages(
  StepOutput out,
  Map<String, String> vars,
  int count,
) => [
  for (var n = out.start; n < out.start + count; n++)
    _subst(out.value.template, {
      ...vars,
      // Zero-padded when the host numbers its files that way (`p0001.jpg`).
      // Renderer-free extraction depends on it: a site whose page list is only
      // reachable as a count plus a URL shape cannot be scraped at all if the
      // shape can't be reproduced exactly.
      'n': out.pad > 0 ? '$n'.padLeft(out.pad, '0') : '$n',
    }),
];

/// Reads a list of records (one `{field: value}` map per matched element) out
/// of [body] using [StepOutput.fields], plus [StepOutput.meta] read once from
/// the document/root. Values are raw (no URL resolution); the adapter resolves
/// URL-typed fields. HTML parses + extracts here; JSON shares [_recordFromJson]
/// across the json/regexJson cases.
RecordList extractRecordList(
  String body,
  StepParse parse,
  String regex,
  StepOutput out, [
  Map<String, String> vars = const {},
  String htmlFrom = '',
]) {
  // jsonHtml: lift the HTML fragment out of the JSON envelope and treat it as
  // an ordinary HTML document from here on.
  final htmlBody = parse == StepParse.jsonHtml
      ? _liftHtml(body, htmlFrom)
      : body;
  if (parse == StepParse.html || parse == StepParse.jsonHtml) {
    final doc = html_parser.parse(htmlBody);
    final records = [
      for (final element in doc.querySelectorAllExt(out.list.selector))
        _recordFromElement(element, out.fields, vars),
    ];
    // documentElement (not .body): a meta locator can target <head> content.
    final root = doc.documentElement;
    final meta = (out.meta.isEmpty || root == null)
        ? const <String, String>{}
        : _recordFromElement(root, out.meta, vars);
    return RecordList(records, meta);
  }
  final decoded = _decodeStepJson(body, parse, regex);
  if (decoded == null) return const RecordList([], {});
  final node = out.list.path.isEmpty
      ? decoded
      : readJsonPath(decoded, out.list.path);
  final list = _asList(node, out.list.values);
  final records = list == null
      ? const <Map<String, String>>[]
      : [
          for (final item in list)
            _recordFromJson(item, out.fields, decoded, vars),
        ];
  final meta = out.meta.isEmpty
      ? const <String, String>{}
      : _recordFromJson(decoded, out.meta, decoded, vars);
  return RecordList(records, meta);
}

/// Walks [pipeline] like [runBodyPipeline] and returns its terminal body
/// decoded as JSON (decode offloaded via [runParse], propagating a malformed
/// body's [FormatException]), for the API engine, whose richer field model
/// reads the decoded root with its own JSON evaluators rather than flat records.
Future<Object?> runJsonPipeline(
  Pipeline pipeline,
  Map<String, String> vars, {
  required String baseUrl,
  required StepFetch fetch,
  JsRunner? js,
}) async {
  final body = await runBodyPipeline(
    pipeline,
    vars,
    baseUrl: baseUrl,
    fetch: fetch,
    js: js,
  );
  return runParse(() => jsonDecode(body));
}

Map<String, String> _recordFromElement(
  Element item,
  Map<String, Locator> fields,
  Map<String, String> vars,
) => {
  for (final entry in fields.entries)
    entry.key: _valueFromHtml(item, entry.value, vars),
};

/// Locates [loc] within [item] (empty selector = [item] itself), reads its
/// attr-or-text (with the `data-src` image fallback), applies an optional
/// [Locator.template] (`{value}` = the read value, `{var}` = a threaded var,
/// e.g. packing the manga id into a chapter's url) then [Locator.rewrite], then
/// walks [Locator.fallbacks] until something is found.
String _valueFromHtml(Element item, Locator loc, Map<String, String> vars) {
  final el = loc.selector.isEmpty ? item : item.querySelectorExt(loc.selector);
  if (loc.exists) return el != null ? '1' : '';
  var value = '';
  if (el != null) {
    value = _valueFromElement(el, loc);
    if (value.isNotEmpty &&
        loc.template.isNotEmpty &&
        loc.template != '{value}') {
      value = _subst(loc.template, {...vars, 'value': value});
    }
    if (loc.rewrite != null && value.isNotEmpty) {
      value = loc.rewrite!.apply(value);
    }
  }
  if (value.isNotEmpty) return value;
  for (final fb in loc.fallbacks) {
    final found = _valueFromHtml(item, fb, vars);
    if (found.isNotEmpty) return found;
  }
  return value;
}

Map<String, String> _recordFromJson(
  Object? item,
  Map<String, Locator> fields,
  Object? root,
  Map<String, String> vars,
) => {
  for (final entry in fields.entries)
    entry.key: _valueFromJson(item, entry.value, root, vars),
};

/// Reads [loc]'s value from a JSON [item]: the node at [Locator.path] (empty =
/// [item] itself) rendered through [Locator.template] (which can also pull in
/// the pipeline's threaded [vars], e.g. a manga slug captured from an earlier
/// step, unreachable from the item/response JSON alone), then
/// [Locator.rewrite], then [Locator.fallbacks] until something is found.
String _valueFromJson(
  Object? item,
  Locator loc,
  Object? root,
  Map<String, String> vars,
) {
  final node = loc.path.isEmpty ? item : readJsonPath(item, loc.path);
  if (loc.exists) return node != null ? '1' : '';
  var value = node == null ? '' : '$node';
  if (value.isNotEmpty &&
      loc.template.isNotEmpty &&
      loc.template != '{value}') {
    try {
      value = renderJsonTemplate(
        loc.template,
        value: value,
        item: item,
        vars: vars,
        root: root,
      );
    } on FormatException {
      value = '';
    }
  }
  if (loc.rewrite != null && value.isNotEmpty) {
    value = loc.rewrite!.apply(value);
  }
  if (value.isNotEmpty) return value;
  for (final fb in loc.fallbacks) {
    final found = _valueFromJson(item, fb, root, vars);
    if (found.isNotEmpty) return found;
  }
  return value;
}

/// The list a JSON [node] yields: itself when a list, or its values when an
/// object and [values] is set (object-keyed collections); null otherwise.
List<Object?>? _asList(Object? node, bool values) {
  if (node is List) return node;
  if (values && node is Map) return node.values.toList();
  return null;
}

List<String> _flatFromJson(
  Object? decoded,
  StepOutput out,
  Map<String, String> vars,
) {
  final node = out.list.path.isEmpty
      ? decoded
      : readJsonPath(decoded, out.list.path);
  final list = _asList(node, out.list.values);
  if (list == null) return const [];
  final urls = <String>[];
  final template = out.value.template;
  for (final element in list) {
    final value = element is String ? element : '$element';
    final String rendered;
    if (template.isEmpty || template == '{value}') {
      rendered = value;
    } else {
      try {
        rendered = renderJsonTemplate(
          template,
          value: value,
          item: element,
          vars: vars,
          root: decoded,
        );
      } on FormatException {
        continue;
      }
    }
    if (rendered.isNotEmpty) urls.add(rendered);
  }
  return urls;
}

/// Reads an intermediate step's scalar captures out of [body].
Map<String, String> extractCaptures(
  String body,
  StepParse parse,
  String regex,
  Map<String, Locator> capture, [
  Map<String, String> vars = const {},
]) {
  if (capture.isEmpty) return const {};
  final out = <String, String>{};
  // Regex captures read a raw string (the body, or a threaded var via `from`),
  // independent of parse mode; the rest need the parsed doc/json, built only if
  // any remain.
  final needsParse = <String, Locator>{};
  capture.forEach((key, loc) {
    if (loc.regex.isNotEmpty) {
      final source = loc.from.isEmpty ? body : (vars[loc.from] ?? '');
      out[key] = _maybeEncode(_regexValue(source, loc.regex), loc);
    } else {
      needsParse[key] = loc;
    }
  });
  if (needsParse.isEmpty) return out;
  if (parse == StepParse.html) {
    // documentElement (not .body): a capture locator can target <head>.
    final root = html_parser.parse(body).documentElement;
    needsParse.forEach((key, loc) {
      final value = root == null ? '' : _attrOf(root, loc.selector, loc.attr);
      out[key] = _maybeEncode(value, loc);
    });
    return out;
  }
  final decoded = _decodeStepJson(body, parse, regex);
  if (decoded == null) return out;
  needsParse.forEach((key, loc) {
    final value = loc.path.isEmpty ? decoded : readJsonPath(decoded, loc.path);
    out[key] = _maybeEncode(value == null ? '' : '$value', loc);
  });
  return out;
}

/// First capture group of [pattern] in [body] (dot-all so a group can span
/// lines), or '' when it doesn't match.
String _regexValue(String body, String pattern) {
  final m = RegExp(pattern, dotAll: true).firstMatch(body);
  return (m != null && m.groupCount >= 1) ? (m.group(1) ?? '') : '';
}

/// Decodes [body] as JSON and returns the string at [path], the HTML fragment
/// an AJAX envelope carries (`parse: jsonHtml`). '' when the body isn't JSON or
/// the node isn't a string.
String _liftHtml(String body, String path) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return '';
  }
  final node = path.isEmpty ? decoded : readJsonPath(decoded, path);
  return node is String ? node : '';
}

/// URL-encodes [value] as a path-segment component when [loc] asks for it; the
/// captured id/label is otherwise threaded into later requests verbatim.
String _maybeEncode(String value, Locator loc) =>
    loc.encode && value.isNotEmpty ? Uri.encodeComponent(value) : value;

/// [siblingCounts], when given, is how many times each raw attr value occurs
/// across the whole list this element came from; [imageFallback]'s "does
/// this look like a placeholder" check uses it to catch a lazy-load
/// placeholder that isn't a `data:` URI (a themed loading-spinner asset, the
/// same file for every unloaded page): two distinct manga pages essentially
/// never share one literal image URL, so a value repeated 2+ times in the
/// same list is placeholder evidence regardless of what it looks like.
String _valueFromElement(
  Element element,
  Locator value, {
  Map<String, int>? siblingCounts,
}) {
  if (value.attr.isEmpty) return element.text.trim();
  final primary = element.attributes[value.attr]?.trim();
  if (!value.imageFallback) return primary ?? '';
  final isPlaceholder =
      primary == null ||
      primary.isEmpty ||
      primary.startsWith('data:') ||
      (siblingCounts != null && (siblingCounts[primary] ?? 0) > 1);
  if (!isPlaceholder) return primary;
  return element.attributes['data-src']?.trim() ?? '';
}

String _attrOf(Element root, String selector, String attr) {
  final element = selector.isEmpty ? root : root.querySelectorExt(selector);
  if (element == null) return '';
  if (attr.isEmpty) return element.text.trim();
  return element.attributes[attr]?.trim() ?? '';
}

String _resolveUrl(String baseUrl, String url) {
  if (url.isEmpty) return url;
  return Uri.parse(baseUrl).resolve(url).toString();
}

// ── Desugaring: today's config blocks → a pipeline ──────────────────────────

/// Compiles a [PagesConfig] into a [Pipeline]. The scraper's two page shapes
/// become a single terminal step: `<img>` scraping (selector + `data-src`
/// fallback) or a `ts_reader.run`-style script blob (regex → JSON). This is the
/// desugaring the spike proves faithful; `fetchPages` routes through it and the
/// existing page tests must stay green.
Pipeline pagesPipeline(PagesConfig pages) {
  final request = StepRequest(
    transform: pages.request,
    base: 'chapterUrl',
    method: pages.request?.method ?? 'GET',
    headers: pages.request?.headers ?? const {},
  );
  final script = pages.script;
  final Step step;
  if (script != null) {
    step = Step(
      request: request,
      parse: StepParse.regexJson,
      regex: script.pattern,
      output: StepOutput(
        list: Locator(path: script.itemsPath),
        value: Locator(template: script.template),
      ),
    );
  } else {
    step = Step(
      request: request,
      output: StepOutput(
        list: Locator(selector: pages.imageSelector),
        value: Locator(attr: pages.imageAttr, imageFallback: true),
      ),
    );
  }
  return Pipeline([step]);
}

/// Compiles a [ChaptersConfig] into a [Pipeline] yielding a record per chapter
/// (`{url, name, date}`). The mainline is one HTML step (fetch the chapter-list
/// URL via the config's [RequestTransform], yield records). Madara's legacy
/// two-phase id lookup desugars to a leading capture step that lifts `{id}` from
/// the manga page into the request, the same machinery [pagesPipeline] uses.
///
/// `name` is omitted when both its selector and attr are empty, so the record
/// has no name and the adapter applies its `Chapter N` fallback, exactly what
/// the old text extractor returned for that degenerate config.
Pipeline chaptersPipeline(ChaptersConfig chapters) {
  final request = chapters.request;
  final steps = <Step>[];
  if (request != null && request.hasIdLookup) {
    steps.add(
      Step(
        request: const StepRequest(base: 'mangaUrl'),
        capture: {
          'id': Locator(selector: request.idSelector, attr: request.idAttr),
        },
      ),
    );
  }
  steps.add(
    Step(
      request: StepRequest(
        transform: request,
        base: 'mangaUrl',
        method: request?.method ?? 'GET',
        headers: request?.headers ?? const {},
      ),
      output: StepOutput(
        list: Locator(selector: chapters.itemSelector),
        fields: {
          'url': Locator(
            selector: chapters.urlSelector,
            attr: chapters.urlAttr,
          ),
          if (chapters.nameSelector.isNotEmpty || chapters.nameAttr.isNotEmpty)
            'name': Locator(
              selector: chapters.nameSelector,
              attr: chapters.nameAttr,
            ),
          if (chapters.dateSelector.isNotEmpty)
            'date': Locator(
              selector: chapters.dateSelector,
              attr: chapters.dateAttr,
            ),
          if (chapters.lockedSelector.isNotEmpty)
            'locked': Locator(selector: chapters.lockedSelector, exists: true),
          if (chapters.officialSelector.isNotEmpty)
            'official': Locator(
              selector: chapters.officialSelector,
              attr: chapters.officialAttr,
            ),
        },
      ),
    ),
  );
  return Pipeline(steps);
}

/// Compiles one [CoverSource] chain into a single [Locator]: the first step is
/// the primary, the rest are [Locator.fallbacks], each carrying its own rewrite,
/// so "first selector/attr yielding a non-empty value (after its rewrite)
/// wins" is expressed as data, matching the old `_cover` walk.
Locator _coverLocator(List<CoverSource> chain) {
  Locator forStep(CoverSource c) =>
      Locator(selector: c.selector, attr: c.attr, rewrite: c.rewrite);
  return Locator(
    selector: chain.first.selector,
    attr: chain.first.attr,
    rewrite: chain.first.rewrite,
    fallbacks: [for (final c in chain.skip(1)) forStep(c)],
  );
}

/// Compiles a [ListingConfig] into a [Pipeline] yielding a record per result
/// (`{url, title, cover}`) plus a `hasNext` meta flag. The request target, with
/// its `{page}`/`{offset}`/`{query}` substitution and any filter params, is
/// resolved by the adapter and threaded in as `{listingUrl}`/`{listingBody}`;
/// the listing-specific request building stays out of the generic engine.
Pipeline listingPipeline(ListingConfig listing) {
  final isPost = listing.method == 'POST';
  return Pipeline([
    Step(
      request: StepRequest(
        base: 'listingUrl',
        method: listing.method,
        body: isPost ? '{listingBody}' : '',
        headers: isPost ? listing.headers : const {},
      ),
      output: StepOutput(
        list: Locator(selector: listing.itemSelector),
        fields: {
          'url': Locator(selector: listing.urlSelector, attr: listing.urlAttr),
          if (listing.titleSelector.isNotEmpty || listing.titleAttr.isNotEmpty)
            'title': Locator(
              selector: listing.titleSelector,
              attr: listing.titleAttr,
            ),
          if (listing.coverChain.isNotEmpty)
            'cover': _coverLocator(listing.coverChain),
        },
        meta: {
          if (listing.nextPageSelector.isNotEmpty)
            'hasNext': Locator(
              selector: listing.nextPageSelector,
              exists: true,
            ),
        },
      ),
    ),
  ]);
}
