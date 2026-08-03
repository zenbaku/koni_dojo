// Dojo source playground: a Flutter *desktop* workbench over one or
// more workspaces (source collections), aimed at extension developers: open a
// workspace directory, see every source (active / dormant) in one sortable
// table with catalog status and live probe results, switch between registered
// workspaces, and click through to a syntax-highlighted config editor + probe
// view. Desktop
// deliberately: a real HTTP client (no browser CORS) is what makes probing
// the actual sites possible, the same reason `tool/live_probe.dart` is a CLI.
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'cloudflare.dart';
import 'consent.dart';
import 'detail_screen.dart';
import 'login.dart';
import 'probe_store.dart';
import 'sample_config.dart';
import 'table_screen.dart';
import 'workspace.dart';

void main(List<String> args) {
  // Probe history + captured examples DB. Guarded: a missing native sqlite3
  // lib shouldn't stop the app; it just loses persistence.
  try {
    probeStore = ProbeStore.open();
  } catch (_) {
    probeStore = null;
  }
  final workspace = Workspace()..loadRegistry();
  // CLI arg wins (open <app> --args /path/to/workspace), else the last
  // current workspace from the registry.
  final initial =
      args.where((a) => Directory(a).existsSync()).firstOrNull ??
      loadCurrentWorkspace();
  if (initial != null) workspace.open(initial);
  runApp(PlaygroundApp(workspace: workspace));
  // Re-seed the WebView cookie jar from last session's clearances up front, so
  // webview sources are primed before the first probe (and the "N reused"
  // indicator is ready). Fire-and-forget; idempotent with the per-probe call.
  ensureClearanceLoaded();
  // Same idea for captured logins: primed before the first "log in" tap so
  // a previous session's session cookie is already in the jar (the lock icon
  // reads it synchronously from `playgroundLogin`, so this must land before
  // any DetailScreen builds its app bar).
  ensureLoginLoaded();
  // Same idea for consent-toggle overrides: primed before the first probe
  // so a previously-flipped preference (e.g. "show gore content") is already
  // in effect rather than only after the toggle UI is opened once.
  ensureConsentLoaded();
}

class PlaygroundApp extends StatelessWidget {
  const PlaygroundApp({super.key, required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    // The tooling's signature warm-amber accent.
    const seed = Color(0xFFB06F1F);
    return MaterialApp(
      title: 'Dojo Source Playground',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: ListenableBuilder(
        listenable: workspace,
        builder: (context, _) => workspace.root == null
            ? WelcomeScreen(workspace: workspace)
            : TableScreen(workspace: workspace),
      ),
    );
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.travel_explore,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Dojo Source Playground',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 420,
              child: Text(
                'Open a workspace directory (a folder with extensions/, e.g. a '
                'checkout’s workspaces/default) to browse every source — '
                'active and dormant — with catalog status, and live-probe any '
                'of them. You can register several and switch between them.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final dir = await getDirectoryPath();
                if (dir != null) workspace.open(dir);
              },
              icon: const Icon(Icons.folder_open),
              label: const Text('Open workspace…'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailScreen(
                    workspace: workspace,
                    title: 'Scratch config',
                    initialText: sampleConfig,
                  ),
                ),
              ),
              child: const Text('…or just probe a scratch config'),
            ),
          ],
        ),
      ),
    );
  }
}
