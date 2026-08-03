// A QuickJS-backed [JsRunner] for the playground, so `js` pipeline steps run
// here just as they do in the app. The runtime is created lazily on first use
// (constructing this is cheap and touches no native code, safe for tests).
import 'package:flutter_js/flutter_js.dart';
import 'package:koni_dojo/koni_dojo.dart';

class PlaygroundJsRunner implements JsRunner {
  JavascriptRuntime? _rt;

  @override
  Future<String> eval(String code) async {
    final rt = _rt ??= getJavascriptRuntime();
    final result = await rt.evaluateAsync(code);
    if (result.isError) {
      throw StateError('JS step failed: ${result.stringResult}');
    }
    return result.stringResult;
  }
}

/// Process-wide runner injected into every probed source.
final playgroundJsRunner = PlaygroundJsRunner();
