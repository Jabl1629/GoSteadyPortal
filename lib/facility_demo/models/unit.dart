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
}
