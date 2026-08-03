/// The web has no isolates, so parse inline, but yield to the event loop
/// first so the frame that requested the parse can paint before the
/// synchronous work runs.
Future<R> runParse<R>(R Function() compute) async {
  await Future<void>.delayed(Duration.zero);
  return compute();
}
