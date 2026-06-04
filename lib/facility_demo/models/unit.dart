/// A unit within a facility — wing, floor, ward. Architecture calls this a
/// "Census" (industry term meaning the headcount of a unit); the UI label is
/// "Unit" because Census doesn't read right outside senior-living. The id
/// here is the Census id from the data model.
class Unit {
  final String id;
  final String facilityId;
  final String displayName;

  const Unit({
    required this.id,
    required this.facilityId,
    required this.displayName,
  });

  // Value equality by census id. Required so a [DropdownButtonFormField]'s
  // `value` matches one of its `items` across rebuilds: the live repository
  // derives Unit instances fresh from the cached /me/patients response on
  // every build (see LiveFacilityRepository.allUnits), so identity equality
  // would make a just-selected unit `!=` its rebuilt item and silently drop
  // the selection (release build) or assert (debug). Keyed on id because the
  // census id is canonical and unique.
  @override
  bool operator ==(Object other) => other is Unit && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
