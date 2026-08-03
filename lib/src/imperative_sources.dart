import 'package:http/http.dart' as http;

import 'js_runner.dart';
import 'source.dart';

/// The built-in **imperative** sources: the escape hatch for sites the
/// declarative engines can't express (request signing, image decryption).
/// Each is a hand-written [Source] value, built alongside the declarative
/// configs and registered the same way. [js] is the app's JavaScript runtime
/// (null where unavailable, e.g. web; sources that need it then error
/// clearly rather than half-work).
///
/// Currently empty: the one imperative source ever registered here was
/// ported to a declarative `js`-step config (see `docs/js-step-proposal.md`
/// for the worked example) once that step type shipped, and its old
/// hand-written flow is broken server-side (see a workspace's own
/// sources-catalog.md). The seam stays: the next JS-gated site that won't
/// fit a config lands here.
List<Source> imperativeSources({required http.Client client, JsRunner? js}) =>
    const [];
