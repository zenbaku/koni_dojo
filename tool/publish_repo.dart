// Publishes a workspace's built repo/ to its Cloudflare Pages project (the
// public URL an app's "Add repository" points at). The target project comes
// from the workspace manifest's `publish.cfProject`. Workspace-aware
// (--workspace / WORKSPACE, default workspaces/default); see tool/workspace.dart.
//
//   dart run tool/publish_repo.dart                    # default workspace
//   dart run tool/publish_repo.dart --workspace nsfw   # another workspace
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
  if (!Directory(ws.repoDir).existsSync()) {
    stderr.writeln('No ${ws.repoDir}/ — run build-repo first.');
    exit(1);
  }
  print('Publishing ${ws.repoDir} → Cloudflare Pages project "$project"');
  final proc = await Process.start('npx', [
    'wrangler',
    'pages',
    'deploy',
    ws.repoDir,
    '--project-name=$project',
  ], mode: ProcessStartMode.inheritStdio);
  exit(await proc.exitCode);
}
