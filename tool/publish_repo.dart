// Publishes a workspace's built index to its Cloudflare Pages project (the
// public URL an app's "Add repository" points at). The target project comes
// from the workspace manifest's `publish.cfProject`. Workspace-aware
// (--workspace / WORKSPACE, default workspaces/default); see tool/workspace.dart.
//
//   dart run tool/publish_repo.dart                    # default workspace
//   dart run tool/publish_repo.dart --workspace nsfw   # another workspace
//
// **Publishes `repo/index.min.json` only**, not the whole `repo/` directory.
// That directory also holds `generated-index.min.json` — a workspace's
// bulk-generated, live-unverified tier — which is working state, not a
// deliverable: nothing fetches it over HTTP (tooling reads it from disk), and
// it lists sources that deliberately haven't passed verification. Deploying
// the directory wholesale would publish it as a side effect of publishing the
// index, so the upload is staged from a temp directory containing just the
// index instead.
//
// The deploy branch comes from the workspace (`publish.cfBranch`, default
// `main`), never from the git checkout this runs in — otherwise publishing from
// a feature branch or a worktree lands a **preview** deployment while printing
// "Deployment complete!" and exiting 0, leaving production on the old index.
//
// One-time setup: `npx wrangler login`, and create the project once with
// `npx wrangler pages project create <cfProject>`.
// ignore_for_file: avoid_print
import 'dart:io';

import 'workspace.dart';

Future<void> main(List<String> args) async {
  final ws = Workspace.resolve(args);
  final project = ws.publishProject;
  if (project == null || project.isEmpty) {
    stderr.writeln(
      'Workspace "${ws.name}" has no publish.cfProject in '
      '${ws.root}/workspace.json — add one to publish it.',
    );
    exit(1);
  }
  final index = File(ws.repoIndex);
  if (!index.existsSync()) {
    stderr.writeln('No ${ws.repoIndex} — run build-repo first.');
    exit(1);
  }

  // Staged rather than uploading ws.repoDir directly; see the header note.
  final staging = Directory.systemTemp.createTempSync('koni_dojo_publish_');
  try {
    index.copySync('${staging.path}/index.min.json');
    final sizeKb = (index.lengthSync() / 1024).round();
    print(
      'Publishing ${ws.repoIndex} ($sizeKb KB) → '
      'Cloudflare Pages project "$project", branch "${ws.publishBranch}"',
    );
    final proc = await Process.start('npx', [
      'wrangler',
      'pages',
      'deploy',
      staging.path,
      '--project-name=$project',
      // Never inferred from git — see [Workspace.publishBranch].
      '--branch=${ws.publishBranch}',
    ], mode: ProcessStartMode.inheritStdio);
    exit(await proc.exitCode);
  } finally {
    staging.deleteSync(recursive: true);
  }
}
