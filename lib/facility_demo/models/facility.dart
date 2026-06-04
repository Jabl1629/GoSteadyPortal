/// A facility — physical building owned by a Client. Architecture-level
/// entity; see ARCHITECTURE.md §4.
class Facility {
  final String id;
  final String displayName;

  const Facility({required this.id, required this.displayName});

  // Value equality by facility id — same rationale as [Unit]. Facility
  // selection currently survives only because AddResidentDialog stores the
  // facility list in a `late final` field; adding equality removes that
  // latent fragility and makes Facility safe to derive fresh per build like
  // units are.
  @override
  bool operator ==(Object other) => other is Facility && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
