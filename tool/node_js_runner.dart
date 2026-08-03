// A Node-subprocess [JsRunner] for CLI probing of `js: true` configs.
//
// The app injects QuickJS (flutter_js) and the playground does the same, but
// plain-Dart tooling has no JS engine, so this shells out to `node` and runs
// the code in a fresh `vm` context, which matches QuickJS where it matters
// here: program semantics (a top-level `return` is a syntax error; site
// scripts must be run via `new Function`) and the result being the value of
// the last expression.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/koni_dojo.dart';

class NodeJsRunner implements JsRunner {
  /// Null when `node` isn't on PATH.
  static NodeJsRunner? detect() =>
      Process.runSync('which', ['node']).exitCode == 0 ? NodeJsRunner() : null;

  @override
  Future<String> eval(String code) async {
    final proc = await Process.start('node', [
      '-e',
      'const vm=require("node:vm");let s="";'
          'process.stdin.on("data",d=>s+=d);'
          'process.stdin.on("end",()=>{'
          'try{process.stdout.write(String(vm.runInNewContext(s,{},{timeout:10000})));}'
          'catch(e){process.stderr.write(String(e));process.exit(1);}'
          '});',
    ]);
    proc.stdin.write(code);
    await proc.stdin.close();
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    if (await proc.exitCode != 0) {
      throw StateError('JS step failed: ${(await err).trim()}');
    }
    return out;
  }
}
