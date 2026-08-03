import 'extension_models.dart';
import 'pipeline.dart';

/// Every host a [config] is *statically* configured to contact: `baseUrl`,
/// `apiUrl` (API dialect), and any absolute URL in a
/// [RequestTransform]/[StepRequest] across every operation and its `steps`
/// pipeline.
///
/// This is a lower bound, not a guarantee of everything a config might
/// contact: a cover/page image URL is frequently extracted from the live
/// response body (an API `pages()` template in particular resolves entirely
/// at runtime) and can't be known without running the source. Callers
/// surfacing this to a user should say "configured to contact", not claim
/// completeness.
Set<String> declaredHosts(AnySourceConfig config) {
  final hosts = <String>{};

  void addUrl(String? url) {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      hosts.add(uri.host.toLowerCase());
    }
  }

  void addPipeline(Pipeline? pipeline) {
    if (pipeline == null) return;
    for (final step in pipeline.steps) {
      addUrl(step.request?.url);
    }
  }

  addUrl(config.baseUrl);

  switch (config) {
    case SourceConfig c:
      addPipeline(c.popular.steps);
      addPipeline(c.latest?.steps);
      addPipeline(c.search?.steps);
      addPipeline(c.details.steps);
      addUrl(c.chapters.request?.url);
      addPipeline(c.chapters.steps);
      addUrl(c.pages.request?.url);
      addPipeline(c.pages.steps);
      for (final filter in c.filters) {
        addUrl(filter.optionsFrom?.path);
      }
    case ApiSourceConfig c:
      addUrl(c.apiUrl);
      addPipeline(c.popular.steps);
      addPipeline(c.search?.steps);
      addPipeline(c.details?.steps);
      addPipeline(c.chapters.steps);
      addPipeline(c.pages.steps);
  }

  return hosts;
}
