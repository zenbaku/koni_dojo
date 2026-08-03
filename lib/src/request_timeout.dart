import 'package:http/http.dart' as http;

/// Cap on each HTTP request to a source, extension repo, or image CDN: a
/// hung connection fails the operation (which surfaces on its job card or
/// screen) instead of stalling it forever.
const sourceRequestTimeout = Duration(seconds: 30);

extension RequestTimeout on Future<http.Response> {
  /// Fails with an [http.ClientException] naming [url] when no response
  /// arrives within [sourceRequestTimeout].
  Future<http.Response> withRequestTimeout(Uri url) => timeout(
    sourceRequestTimeout,
    onTimeout: () => throw http.ClientException(
      'Timed out after ${sourceRequestTimeout.inSeconds}s',
      url,
    ),
  );
}
