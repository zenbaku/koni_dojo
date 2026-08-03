// A small SQLite database persisting probe activity so the playground remembers
// status across restarts and keeps captured request/response examples (great as
// offline fixtures). Two tables: `probe_run` (one row per probe: status,
// failed stage, latency, timestamp) and `example` (the request/response of each
// step of the *latest* run per source; replaced on each probe to stay small).
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'probe.dart';

/// One recorded probe: its outcome and timing.
class ProbeRun {
  ProbeRun({
    required this.sourceId,
    required this.op,
    required this.ranAt,
    required this.passed,
    this.failedStage,
    this.error,
    this.elapsedMs,
    this.tier,
  });

  final String sourceId;
  final String op; // 'full', 'popular', …
  final DateTime ranAt;
  final bool passed;
  final String? failedStage;
  final String? error;
  final int? elapsedMs;
  final String? tier;
}

/// One captured request/response step of a probe.
class ProbeExample {
  ProbeExample({
    required this.stepIndex,
    required this.method,
    this.requestUrl,
    this.captured = const {},
    this.body = '',
    this.terminal = false,
  });

  final int stepIndex;
  final String method;
  final String? requestUrl;
  final Map<String, String> captured;
  final String body;
  final bool terminal;
}

const _maxBody = 500 * 1024; // cap a stored response body at 500 KB
const _historyPerSource = 50; // keep the last N runs per source

class ProbeStore {
  ProbeStore._(this._db) {
    _migrate();
  }

  final Database _db;

  /// Opens (creating if needed) the on-disk store. Home-dir dotfile, matching
  /// the playground's other persisted state.
  factory ProbeStore.open([String? path]) {
    final p =
        path ??
        '${Platform.environment['HOME'] ?? '.'}/.konimanga_playground.db';
    return ProbeStore._(sqlite3.open(p));
  }

  /// In-memory store for tests.
  factory ProbeStore.memory() => ProbeStore._(sqlite3.openInMemory());

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS probe_run (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL,
        tier TEXT,
        op TEXT NOT NULL,
        ran_at TEXT NOT NULL,
        passed INTEGER NOT NULL,
        failed_stage TEXT,
        error TEXT,
        elapsed_ms INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_run_source ON probe_run (source_id, id DESC);

      CREATE TABLE IF NOT EXISTS example (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL,
        op TEXT,
        ran_at TEXT NOT NULL,
        step_index INTEGER,
        method TEXT,
        request_url TEXT,
        captured TEXT,
        body TEXT,
        terminal INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_example_source ON example (source_id);
    ''');
  }

  /// Records a finished probe: its status row, plus the request/response of each
  /// traced step (replacing this source's prior examples). No-op for a run that
  /// never resolved a source (bad config) so we don't log noise.
  void record(ProbeState state, {String? tier}) {
    final id = state.sourceInfo?.id;
    if (id == null || id.isEmpty || state.phase != ProbePhase.done) return;
    final ranAt = DateTime.now().toIso8601String();

    _db.execute(
      'INSERT INTO probe_run '
      '(source_id, tier, op, ran_at, passed, failed_stage, error, elapsed_ms) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        tier,
        state.ranStage.name,
        ranAt,
        state.passed ? 1 : 0,
        state.failedStage,
        state.runError ?? state.stageError?.toString(),
        state.elapsed?.inMilliseconds,
      ],
    );

    // The examples are the latest run's steps: replace, don't accumulate.
    _db.execute('DELETE FROM example WHERE source_id = ?', [id]);
    if (state.traces.isNotEmpty) {
      final stmt = _db.prepare(
        'INSERT INTO example '
        '(source_id, op, ran_at, step_index, method, request_url, captured, body, terminal) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      for (final t in state.traces) {
        final raw = t.body.isNotEmpty ? t.body : t.bodyPreview;
        final body = raw.length > _maxBody ? raw.substring(0, _maxBody) : raw;
        stmt.execute([
          id,
          state.ranStage.name,
          ranAt,
          t.index,
          t.method,
          t.requestUrl,
          jsonEncode(t.captured),
          body,
          t.terminal ? 1 : 0,
        ]);
      }
      stmt.dispose();
    }

    _db.execute(
      'DELETE FROM probe_run WHERE source_id = ? AND id NOT IN '
      '(SELECT id FROM probe_run WHERE source_id = ? ORDER BY id DESC LIMIT ?)',
      [id, id, _historyPerSource],
    );
  }

  ProbeRun? lastRun(String sourceId) {
    final rows = history(sourceId, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Most recent runs for [sourceId], newest first.
  List<ProbeRun> history(String sourceId, {int limit = 25}) {
    final result = _db.select(
      'SELECT * FROM probe_run WHERE source_id = ? ORDER BY id DESC LIMIT ?',
      [sourceId, limit],
    );
    return [for (final r in result) _runFromRow(r)];
  }

  /// The captured examples for [sourceId] (latest run), in step order.
  List<ProbeExample> examplesFor(String sourceId) {
    final result = _db.select(
      'SELECT * FROM example WHERE source_id = ? ORDER BY step_index ASC',
      [sourceId],
    );
    return [
      for (final r in result)
        ProbeExample(
          stepIndex: (r['step_index'] as int?) ?? 0,
          method: (r['method'] as String?) ?? 'GET',
          requestUrl: r['request_url'] as String?,
          captured: _decodeCaptured(r['captured'] as String?),
          body: (r['body'] as String?) ?? '',
          terminal: (r['terminal'] as int? ?? 0) == 1,
        ),
    ];
  }

  ProbeRun _runFromRow(Row r) => ProbeRun(
    sourceId: r['source_id'] as String,
    op: (r['op'] as String?) ?? 'full',
    ranAt:
        DateTime.tryParse('${r['ran_at']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    passed: (r['passed'] as int? ?? 0) == 1,
    failedStage: r['failed_stage'] as String?,
    error: r['error'] as String?,
    elapsedMs: r['elapsed_ms'] as int?,
    tier: r['tier'] as String?,
  );

  Map<String, String> _decodeCaptured(String? json) {
    if (json == null || json.isEmpty) return const {};
    try {
      return (jsonDecode(json) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return const {};
    }
  }

  void close() => _db.dispose();
}

/// Process-wide store, opened at startup (null in tests until set).
ProbeStore? probeStore;

/// Reconstructs a display-only [ProbeState] from a persisted [ProbeRun], for
/// seeding the table's last-known status across restarts. Carries just status +
/// timing (no bodies/results; those live in the examples).
ProbeState probeStateFromRun(ProbeRun run) {
  final state = ProbeState()
    ..phase = ProbePhase.done
    ..ranStage = ProbeStage.values.firstWhere(
      (s) => s.name == run.op,
      orElse: () => ProbeStage.full,
    )
    ..elapsed = run.elapsedMs == null
        ? null
        : Duration(milliseconds: run.elapsedMs!)
    ..recordedAt = run.ranAt;
  if (!run.passed) {
    if (run.failedStage != null) {
      state.failedStage = run.failedStage;
      state.stageError = run.error;
    } else {
      state.runError = run.error;
    }
  }
  return state;
}
