import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

const _repoUrl = 'https://repo.example/index.min.json';

/// A no-op JS runtime: its presence is what registers any JS-gated
/// imperative sources; their ops aren't invoked here, so it never needs to
/// eval.
class _FakeJs implements JsRunner {
  @override
  Future<String> eval(String code) async => '';
}

/// In-memory [ExtensionBlobStore], mirroring the app's `MemoryStorageBackend`.
class _FakeBlobStore implements ExtensionBlobStore {
  final Map<String, Uint8List> _files = {};

  @override
  Future<Uint8List?> read(String path) async => _files[path];

  @override
  Future<void> write(String path, Uint8List bytes) async =>
      _files[path] = bytes;

  @override
  Future<void> delete(String path) async => _files.remove(path);

  @override
  Future<List<String>> list(String prefix) async =>
      _files.keys.where((p) => p.startsWith(prefix)).toList()..sort();
}

/// In-memory [ExtensionMetaStore], mirroring the app's `LibraryDatabase`
/// `KeyValues` rows.
class _FakeMetaStore implements ExtensionMetaStore {
  final Map<String, Map<String, dynamic>> _rows = {};

  @override
  Future<Map<String, dynamic>?> loadMeta(String key) async => _rows[key];

  @override
  Future<void> saveMeta(String key, Map<String, dynamic> value) async =>
      _rows[key] = value;
}

/// A [ClearanceStore] that never has anything on file: the tests here don't
/// exercise Cloudflare replay, just that [ExtensionManager] wires it through.
class _FakeClearanceStore implements ClearanceStore {
  int loadCalls = 0;

  @override
  Future<void> load() async => loadCalls++;

  @override
  Map<String, String> headersFor(String url) => const {};
}

/// A [RepoAuthStore] returning a fixed header for every repo, tracking how
/// often [load] runs.
class _FakeRepoAuthStore implements RepoAuthStore {
  int loadCalls = 0;

  @override
  Future<void> load() async => loadCalls++;

  @override
  Map<String, String> headersFor(String repoUrl) => const {
    'Authorization': 'Basic dGVzdDpwYXNz',
  };
}

final _index = [
  {
    'name': 'Example Source',
    'pkg': 'app.konimanga.extension.en.example',
    'version': '1.0.0',
    'lang': 'en',
    'nsfw': 0,
    'sources': [
      {
        'id': 'example',
        'name': 'Example',
        'lang': 'en',
        'baseUrl': 'https://example.com',
        'popular': {'path': '/popular?page={page}', 'itemSelector': '.item'},
        'chapters': {'itemSelector': '.chapter'},
        'pages': {'imageSelector': '.page img'},
      },
    ],
  },
  // APK-only entry from a Mihon repo: no declarative sources, must be
  // filtered out.
  {
    'name': 'Tachiyomi: SomeApk',
    'pkg': 'eu.kanade.tachiyomi.extension.all.someapk',
    'apk': 'tachiyomi-all.someapk-v1.4.3.apk',
    'version': '1.4.3',
    'lang': 'all',
    'nsfw': 1,
  },
];

http.Client _fakeRepo() => MockClient((request) async {
  if (request.url.toString() == _repoUrl) {
    return http.Response(jsonEncode(_index), 200);
  }
  return http.Response('not found', 404);
});

void main() {
  late _FakeBlobStore storage;
  late _FakeMetaStore meta;
  late ExtensionManager manager;

  ExtensionManager build({
    http.Client? client,
    JsRunner? jsRunner,
    RepoAuthStore? repoAuth,
  }) => ExtensionManager(
    storage: storage,
    meta: meta,
    clearance: _FakeClearanceStore(),
    repoAuth: repoAuth,
    client: client ?? _fakeRepo(),
    jsRunner: jsRunner,
  );

  setUp(() {
    storage = _FakeBlobStore();
    meta = _FakeMetaStore();
    manager = build();
  });

  test('repos persist across instances sharing the same meta store', () async {
    await manager.addRepo(_repoUrl);
    await manager.addRepo(_repoUrl); // duplicate is ignored

    final fresh = build();
    expect(await fresh.loadRepos(), [_repoUrl]);

    await fresh.removeRepo(_repoUrl);
    expect(await fresh.loadRepos(), isEmpty);
  });

  test(
    'updateRepo replaces in place, deduplicates, and falls back to add',
    () async {
      await manager.addRepo('https://a.example/index.json');
      await manager.addRepo('https://b.example/index.json');

      expect(
        await manager.updateRepo(
          'https://a.example/index.json',
          'https://c.example/index.json',
        ),
        ['https://c.example/index.json', 'https://b.example/index.json'],
      );

      expect(
        await manager.updateRepo(
          'https://c.example/index.json',
          'https://b.example/index.json',
        ),
        ['https://b.example/index.json'],
      );

      expect(
        await manager.updateRepo(
          'https://missing.example/index.json',
          'https://d.example/index.json',
        ),
        ['https://b.example/index.json', 'https://d.example/index.json'],
      );
    },
  );

  test('updateRepo to the same URL is a no-op, not a deletion', () async {
    await manager.addRepo('https://a.example/index.json');
    await manager.addRepo('https://b.example/index.json');

    expect(
      await manager.updateRepo(
        'https://a.example/index.json',
        'https://a.example/index.json',
      ),
      ['https://a.example/index.json', 'https://b.example/index.json'],
    );
  });

  test(
    'addLocalRepo registers a repo whose fetchIndex reads it back locally',
    () async {
      final id = await manager.addLocalRepo(
        'My Repo.json',
        Uint8List.fromList(utf8.encode(jsonEncode(_index))),
      );

      expect(manager.isLocalRepo(id), isTrue);
      expect(await manager.loadRepos(), [id]);

      final extensions = await manager.fetchIndex(id);
      expect(extensions.single.pkg, 'app.konimanga.extension.en.example');
    },
  );

  test('addLocalRepo throws on a file with nothing installable', () async {
    await expectLater(
      manager.addLocalRepo('empty.json', Uint8List.fromList(utf8.encode('[]'))),
      throwsFormatException,
    );
    expect(await manager.loadRepos(), isEmpty);
  });

  test('addLocalRepo de-duplicates a colliding slug', () async {
    final first = await manager.addLocalRepo(
      'repo.json',
      Uint8List.fromList(utf8.encode(jsonEncode(_index))),
    );
    final second = await manager.addLocalRepo(
      'repo.json',
      Uint8List.fromList(utf8.encode(jsonEncode(_index))),
    );

    expect(first, isNot(second));
    expect(await manager.loadRepos(), [first, second]);
    // Both remain independently fetchable: the second didn't overwrite the
    // first's blob.
    expect((await manager.fetchIndex(first)).single.pkg, isNotEmpty);
    expect((await manager.fetchIndex(second)).single.pkg, isNotEmpty);
  });

  test(
    'removeRepo deletes a local repo\'s stored blob, not just the list entry',
    () async {
      final id = await manager.addLocalRepo(
        'repo.json',
        Uint8List.fromList(utf8.encode(jsonEncode(_index))),
      );
      expect(storage.list('extensions/local-repos/'), completion(isNotEmpty));

      await manager.removeRepo(id);

      expect(await manager.loadRepos(), isEmpty);
      expect(await storage.list('extensions/local-repos/'), isEmpty);
      // Gone from storage, not just deregistered: re-fetching fails clearly.
      await expectLater(manager.fetchIndex(id), throwsFormatException);
    },
  );

  test('fetchIndex parses entries and drops APK-only ones', () async {
    final extensions = await manager.fetchIndex(_repoUrl);
    expect(extensions.length, 1);
    expect(extensions.single.pkg, 'app.konimanga.extension.en.example');
    expect(extensions.single.sources.single.baseUrl, 'https://example.com');
  });

  test(
    'fetchIndex has no Authorization header when repoAuth is null',
    () async {
      http.Request? captured;
      final withRepoAuth = build(
        client: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode(_index), 200);
        }),
      );
      await withRepoAuth.fetchIndex(_repoUrl);
      expect(captured!.headers.containsKey('Authorization'), false);
    },
  );

  test('fetchIndex merges repoAuth headers and loads it first', () async {
    http.Request? captured;
    final repoAuth = _FakeRepoAuthStore();
    final withRepoAuth = build(
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(_index), 200);
      }),
      repoAuth: repoAuth,
    );
    await withRepoAuth.fetchIndex(_repoUrl);
    expect(captured!.headers['Authorization'], 'Basic dGVzdDpwYXNz');
    expect(repoAuth.loadCalls, 1);
  });

  test('parseExtensionsJson accepts an index list or a single entry', () {
    final fromList = manager.parseExtensionsJson(jsonEncode(_index));
    expect(fromList.single.pkg, 'app.konimanga.extension.en.example');

    final fromMap = manager.parseExtensionsJson(jsonEncode(_index.first));
    expect(fromMap.single.pkg, 'app.konimanga.extension.en.example');

    expect(
      () => manager.parseExtensionsJson('"just a string"'),
      throwsFormatException,
    );
    expect(
      () => manager.parseExtensionsJson('not json at all'),
      throwsFormatException,
    );
  });

  test('install/uninstall round trip', () async {
    final extension = (await manager.fetchIndex(_repoUrl)).single;
    await manager.install(extension);

    var installed = await manager.loadInstalled();
    expect(installed.single.name, 'Example Source');

    await manager.uninstall(extension.pkg);
    installed = await manager.loadInstalled();
    expect(installed, isEmpty);
  });

  test(
    'buildSources is empty until extensions are installed — nothing bundled',
    () async {
      expect(await manager.buildSources(), isEmpty);

      final extension = (await manager.fetchIndex(_repoUrl)).single;
      await manager.install(extension);

      final sources = await manager.buildSources();
      expect(sources.map((s) => s.id).toList(), ['example']);
    },
  );

  test('buildSources loads the clearance store', () async {
    await manager.buildSources();
    expect((manager.clearance as _FakeClearanceStore).loadCalls, 1);
  });

  test(
    'fetchIndex rejects responses that are not an extension index',
    () async {
      final htmlClient = MockClient(
        (request) async => http.Response('<html>not found</html>', 200),
      );
      final managerWithHtml = build(client: htmlClient);
      await expectLater(
        managerWithHtml.fetchIndex(_repoUrl),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not return a valid extension index'),
          ),
        ),
      );

      final wrongShapeClient = MockClient(
        (request) async => http.Response('{"not": "a list"}', 200),
      );
      final managerWithWrongShape = build(client: wrongShapeClient);
      await expectLater(
        managerWithWrongShape.fetchIndex(_repoUrl),
        throwsFormatException,
      );
    },
  );

  test('a corrupted installed extension is skipped, not fatal', () async {
    final extension = (await manager.fetchIndex(_repoUrl)).single;
    await manager.install(extension);
    await storage.write(
      'extensions/broken.json',
      Uint8List.fromList(utf8.encode('{not valid json')),
    );

    final installed = await manager.loadInstalled();
    expect(installed.single.pkg, extension.pkg);

    // The source registry (built at startup) keeps working too.
    final sources = await manager.buildSources();
    expect(sources.map((s) => s.id).toList(), ['example']);
  });

  test('a corrupted repo list reads as empty instead of throwing', () async {
    await storage.write(
      'extensions/repos.json',
      Uint8List.fromList(utf8.encode(']]] garbage')),
    );
    expect(await manager.loadRepos(), isEmpty);

    // Adding a repo afterwards rewrites a healthy entry.
    expect(await manager.addRepo(_repoUrl), [_repoUrl]);
    expect(await manager.loadRepos(), [_repoUrl]);
  });

  test('a legacy repos.json file is imported once, then dropped', () async {
    await storage.write(
      'extensions/repos.json',
      Uint8List.fromList(utf8.encode(jsonEncode([_repoUrl]))),
    );

    expect(await manager.loadRepos(), [_repoUrl]);
    // Imported into meta and the legacy file deleted.
    expect(await storage.read('extensions/repos.json'), isNull);
    expect((await meta.loadMeta(ExtensionManager.reposKey))?['repos'], [
      _repoUrl,
    ]);
  });

  test(
    'the imperative-source seam is empty — every built source is config-backed',
    () async {
      // The one imperative source ever registered was ported to a
      // declarative js-step config, so imperativeSources() contributes
      // nothing even with a JS runtime present; the seam stays for the next
      // JS-gated site. Nothing is bundled either, so with no installs the
      // list is empty.
      final withJs = build(jsRunner: _FakeJs());
      expect(await withJs.buildSources(), isEmpty);
    },
  );

  test('ExtensionInfo accepts keiyoushi-style numeric nsfw flags', () {
    final info = ExtensionInfo.fromJson({
      'name': 'X',
      'pkg': 'x',
      'nsfw': 1,
      'sources': [],
    });
    expect(info.nsfw, true);
  });

  test('ExtensionInfo.updatedAt round-trips through JSON when present, and '
      'is omitted (not written as "") when absent', () {
    final withDate = ExtensionInfo.fromJson({
      'name': 'X',
      'pkg': 'x',
      'sources': [],
      'updatedAt': '2026-07-11',
    });
    expect(withDate.updatedAt, '2026-07-11');
    expect(withDate.toJson()['updatedAt'], '2026-07-11');

    final withoutDate = ExtensionInfo.fromJson({
      'name': 'X',
      'pkg': 'x',
      'sources': [],
    });
    expect(withoutDate.updatedAt, '');
    expect(withoutDate.toJson().containsKey('updatedAt'), false);
  });
}
