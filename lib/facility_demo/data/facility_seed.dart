import '../models/facility.dart';
import '../models/patient.dart';
import '../models/unit.dart';

/// Static seed data for the demo: 2 facilities, 5 units, 10 patients.
/// All numbers/values come from `docs/specs/facility-demo.md` §4.
///
/// IDs use the same shape as the architecture's data model
/// (`fac_*`, `cen_*`, `pt_*`) so swapping in a real `ApiClient` later is a
/// pure constructor change.
class FacilitySeed {
  static const List<Facility> facilities = [
    Facility(
      id: 'fac_whitestone',
      displayName: 'Whitestone Senior Living',
    ),
    Facility(
      id: 'fac_cedar',
      displayName: 'Cedar Crossing Skilled Nursing',
    ),
  ];

  static const List<Unit> units = [
    Unit(
      id: 'cen_ws_memory',
      facilityId: 'fac_whitestone',
      displayName: 'Memory Care',
    ),
    Unit(
      id: 'cen_ws_al_east',
      facilityId: 'fac_whitestone',
      displayName: 'Assisted Living — East',
    ),
    Unit(
      id: 'cen_ws_al_west',
      facilityId: 'fac_whitestone',
      displayName: 'Assisted Living — West',
    ),
    Unit(
      id: 'cen_cc_rehab',
      facilityId: 'fac_cedar',
      displayName: 'Rehab Wing',
    ),
    Unit(
      id: 'cen_cc_ltc',
      facilityId: 'fac_cedar',
      displayName: 'Long-Term Care',
    ),
  ];

  static const List<Patient> patients = [
    Patient(
      id: 'pt_001',
      displayName: 'Margaret O\'Sullivan',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_memory',
      room: '12A',
      deviceSerial: 'GS0000000101',
    ),
    Patient(
      id: 'pt_002',
      displayName: 'Robert Chen',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_memory',
      room: '14B',
      deviceSerial: 'GS0000000102',
    ),
    Patient(
      id: 'pt_003',
      displayName: 'James Martinez',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_memory',
      room: '17A',
      deviceSerial: 'GS0000000103',
    ),
    Patient(
      id: 'pt_004',
      displayName: 'Eleanor Park',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_al_east',
      room: '203',
      deviceSerial: 'GS0000000104',
    ),
    Patient(
      id: 'pt_005',
      displayName: 'Helen Anderson',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_al_east',
      room: '207',
      deviceSerial: 'GS0000000105',
    ),
    Patient(
      id: 'pt_006',
      displayName: 'Frank Kowalski',
      facilityId: 'fac_whitestone',
      unitId: 'cen_ws_al_west',
      room: '308',
      deviceSerial: 'GS0000000106',
    ),
    Patient(
      id: 'pt_007',
      displayName: 'Dorothy Williams',
      facilityId: 'fac_cedar',
      unitId: 'cen_cc_rehab',
      room: 'R-4',
      deviceSerial: 'GS0000000107',
    ),
    Patient(
      id: 'pt_008',
      displayName: 'Albert Rivera',
      facilityId: 'fac_cedar',
      unitId: 'cen_cc_rehab',
      room: 'R-7',
      deviceSerial: 'GS0000000108',
    ),
    Patient(
      id: 'pt_009',
      displayName: 'Ruth Patel',
      facilityId: 'fac_cedar',
      unitId: 'cen_cc_ltc',
      room: '102',
      deviceSerial: 'GS0000000109',
    ),
    Patient(
      id: 'pt_010',
      displayName: 'George Wallace',
      facilityId: 'fac_cedar',
      unitId: 'cen_cc_ltc',
      room: '108',
      deviceSerial: 'GS0000000110',
    ),
  ];
}
