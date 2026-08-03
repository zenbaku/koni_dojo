// The playground's consent-toggle store: an app-specific
// `LocalStoragePreferenceStore` (a JSON dotfile, same shape as
// `cloudflare.dart`'s `PlaygroundClearanceStore`) so a config author can
// actually flip a source's declared `localStoragePreferences` and see
// whether a probe stage's result changes: the same reason `login.dart`
// exists for `loginUrl`.
import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/koni_dojo.dart';

/// Per-source consent overrides, persisted to their own dotfile so a toggle
/// survives playground restarts. Keyed by source id (not host): a
/// preference is declared per-source, unlike Cloudflare clearance which is
/// domain-scoped.
class PlaygroundConsentStore implements LocalStoragePreferenceStore {
  PlaygroundConsentStore({String? path})
    : _path =
          path ??
          '${Platform.environment['HOME'] ?? '.'}/.konimanga_playground_consent.json';

  final String _path;
  final Map<String, Map<String, bool>> _bySource = {};

  @override
  Future<void> load() async {
    try {
      final json = jsonDecode(File(_path).readAsStringSync());
      (json as Map).forEach((sourceId, value) {
        if (value is! Map) return;
        _bySource['$sourceId'] = value.map(
          (id, v) => MapEntry('$id', v == true),
        );
      });
    } catch (_) {
      // No saved consent overrides yet.
    }
  }

  @override
  Map<String, bool> valuesFor(String sourceId) =>
      _bySource[sourceId] ?? const {};

  void save(String sourceId, String prefId, bool value) {
    (_bySource[sourceId] ??= {})[prefId] = value;
    try {
      File(_path).writeAsStringSync(jsonEncode(_bySource));
    } catch (_) {
      // Non-fatal: the override just won't survive a restart.
    }
  }
}

/// Process-wide seam, mirroring `playgroundClearance`/`playgroundLogin`,
/// created lazily so tests (no plugin host) never touch the filesystem.
final playgroundConsent = PlaygroundConsentStore();
bool _consentLoaded = false;

Future<void> ensureConsentLoaded() async {
  if (_consentLoaded) return;
  _consentLoaded = true;
  await playgroundConsent.load();
}
