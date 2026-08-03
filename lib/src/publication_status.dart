/// A series' upstream publication state, as reported by a source.
///
/// Lives in its own file (and is re-exported by `source.dart`) so the app's
/// model layer can branch on it (a fully-read series whose publication has
/// [ended] is genuinely *completed*, not merely *up to date*) without importing
/// the rest of the source engine.
enum PublicationStatus {
  unknown('Unknown'),
  ongoing('Ongoing'),
  completed('Completed'),
  hiatus('Hiatus'),
  cancelled('Cancelled');

  const PublicationStatus(this.label);

  final String label;

  /// Whether the work itself is finished upstream: nothing more is coming.
  bool get ended =>
      this == PublicationStatus.completed ||
      this == PublicationStatus.cancelled;

  static PublicationStatus fromName(String? name) =>
      PublicationStatus.values.firstWhere(
        (status) => status.name == name,
        orElse: () => PublicationStatus.unknown,
      );
}
