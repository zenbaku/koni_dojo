// Minimal static file server for a workspace's built repo/. Needs only the
// Dart SDK. Serves the index (and icons) over the LAN for a phone to add as a
// repository. Workspace-aware (--workspace / WORKSPACE, default
// workspaces/default); the port comes from the workspace manifest's
// `servePort` unless a positional port is passed. See tool/workspace.dart.
//
// Basic Auth is optional: set it via --user/--pass (flags win) or the
// AUTH_USER/AUTH_PASS env vars. Both a user and a pass are required together;
// leave both unset to serve without auth.
//
//   dart run tool/serve_repo.dart                    # default workspace + its port
//   dart run tool/serve_repo.dart --workspace nsfw   # another workspace
//   dart run tool/serve_repo.dart 9000               # override the port
//   dart run tool/serve_repo.dart --user admin --pass secret   # require Basic Auth
//   AUTH_USER=admin AUTH_PASS=secret dart run tool/serve_repo.dart  # same, via env
//   → http://<lan-ip>:<port>/index.min.json
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'workspace.dart';

const _contentTypes = <String, String>{
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.html': 'text/html; charset=utf-8',
};

/// Value of `--name value` / `--name=value` in [args], flags win over env.
String? _flagOrEnv(List<String> args, String flag, String envVar) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--$flag' && i + 1 < args.length) return args[i + 1];
    if (a.startsWith('--$flag=')) return a.substring('--$flag='.length);
  }
  return Platform.environment[envVar];
}

/// Removes `--name value` / `--name=value` from [args] (mirrors
/// Workspace.stripArgs, generalized to an arbitrary flag).
List<String> _stripFlag(List<String> args, String flag) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--$flag') {
      i++; // also skip its value
      continue;
    }
    if (a.startsWith('--$flag=')) continue;
    out.add(a);
  }
  return out;
}

Future<void> main(List<String> args) async {
  final ws = Workspace.resolve(args);
  final user = _flagOrEnv(args, 'user', 'AUTH_USER');
  final pass = _flagOrEnv(args, 'pass', 'AUTH_PASS');
  if ((user == null) != (pass == null)) {
    stderr.writeln(
      'Both --user/AUTH_USER and --pass/AUTH_PASS are required together to '
      'enable Basic Auth; only one was set.',
    );
    exit(1);
  }
  final expectedAuth = user != null
      ? 'Basic ${base64.encode(utf8.encode('$user:$pass'))}'
      : null;

  var rest = Workspace.stripArgs(args);
  rest = _stripFlag(_stripFlag(rest, 'user'), 'pass');
  final positional = rest.where((a) => !a.startsWith('--'));
  final port = positional.isNotEmpty
      ? int.parse(positional.first)
      : ws.servePort;
  final root = Directory(ws.repoDir).absolute;
  if (!root.existsSync()) {
    stderr.writeln(
      'No ${ws.repoDir}/ directory for workspace "${ws.name}" — run '
      'build-repo first, from the project root.',
    );
    exit(1);
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print(
    'Serving ${root.path} on http://0.0.0.0:$port/'
    '${expectedAuth != null ? ' [Basic Auth enabled]' : ''} (Ctrl-C to stop)',
  );

  await for (final req in server) {
    if (expectedAuth != null &&
        req.headers.value(HttpHeaders.authorizationHeader) != expectedAuth) {
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="koni_dojo"',
      );
      req.response.write('401: Unauthorized');
      await req.response.close();
      print('${req.response.statusCode} ${req.method} ${req.uri.path}');
      continue;
    }

    // Decoded segments; refusing '..'/'/' segments keeps requests inside repo/.
    final segments = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final safe = segments.every(
      (s) => s != '..' && !s.contains('/') && !s.contains(r'\'),
    );
    final rel = segments.isEmpty ? 'index.min.json' : segments.join('/');
    final file = File('${root.path}/$rel');
    if (!safe || !file.existsSync()) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('404: ${req.uri.path}');
    } else {
      final ext = rel.contains('.') ? rel.substring(rel.lastIndexOf('.')) : '';
      req.response.headers.contentType = ContentType.parse(
        _contentTypes[ext] ?? 'application/octet-stream',
      );
      await req.response.addStream(file.openRead());
    }
    await req.response.close();
    print('${req.response.statusCode} ${req.method} ${req.uri.path}');
  }
}
