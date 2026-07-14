import '../api/api_client.dart';
import '../api/api_models.dart';

/// Internal fleet-ops data access — backs the internal_admin fleet screen.
///
/// Standalone (not part of [FacilityRepository]) because the fleet board is
/// internal-only, cross-tenant, and unrelated to the census cache. The live
/// impl is a thin wrapper over [ApiClient]; the mock backs demo-mode rendering.
/// Reads/writes go through the audited device-api — never DDB/IoT directly.
abstract class FleetRepository {
  /// `GET /admin/devices` — the whole fleet, board-ready.
  Future<List<FleetDevice>> listFleet();

  Future<void> provision(String serial, String patientId);
  Future<void> endAssignment(String serial);
  Future<void> forceReset(String serial, String reason);
  Future<void> decommission(String serial, String reason);
  Future<void> recover(String serial);

  /// Release ownership → device is claimable by a new household (D2C rotation).
  Future<void> release(String serial);
}

/// Live impl over the authenticated [ApiClient].
class LiveFleetRepository implements FleetRepository {
  final ApiClient _api;
  LiveFleetRepository(this._api);

  @override
  Future<List<FleetDevice>> listFleet() async =>
      (await _api.getAdminDevices()).devices;

  @override
  Future<void> provision(String serial, String patientId) =>
      _api.provisionDevice(serial, patientId);

  @override
  Future<void> endAssignment(String serial) => _api.endAssignment(serial);

  @override
  Future<void> forceReset(String serial, String reason) =>
      _api.forceReset(serial, reason);

  @override
  Future<void> decommission(String serial, String reason) =>
      _api.decommissionDevice(serial, reason);

  @override
  Future<void> recover(String serial) => _api.recoverDevice(serial);

  @override
  Future<void> release(String serial) => _api.releaseDevice(serial);
}

/// In-memory mock for demo mode (no backend). Holds a small fleet and applies
/// writes locally so the screen is interactive without an API. Data only —
/// shaped to look like `GET /admin/devices` rows.
class MockFleetRepository implements FleetRepository {
  final List<FleetDevice> _fleet = [
    FleetDevice(
      serialNumber: 'GS0002000001',
      status: 'active_monitoring',
      deviceType: 'rollator_platform',
      walkerId: 'c7e589c0-eb65-4336-8757-e9182f60f5d5',
      owningClientId: 'dtc_demo01',
      patientId: 'pat_demo_jane',
      batteryPct: 0.94,
      lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
      firmware: 'rol-0.1.0-bench',
      rsrpDbm: -98,
      snrDb: 7,
    ),
    FleetDevice(
      serialNumber: 'GS0002000002',
      status: 'discontinued',
      deviceType: 'rollator_platform',
      walkerId: 'a1b2c3d4-0000-4444-8888-cccccccccccc',
      owningClientId: 'dtc_demo02',
      batteryPct: 0.61,
      lastSeen: DateTime.now().subtract(const Duration(hours: 26)),
      firmware: 'rol-0.1.0-bench',
      rsrpDbm: -112,
      wipePending: true, // stuck: wipe not acked → candidate for force-reset
    ),
    FleetDevice(
      serialNumber: 'GS0002000003',
      status: 'ready_to_provision',
      deviceType: 'rollator_platform',
      walkerId: 'd4e5f6a7-1111-4444-8888-dddddddddddd',
      owningClientId: 'dtc_demo02',
      batteryPct: 0.88,
      lastSeen: DateTime.now().subtract(const Duration(minutes: 41)),
      firmware: 'rol-0.1.0-bench',
      rsrpDbm: -101,
      wipeComplete: 'wipe_demo_abc',
    ),
    FleetDevice(
      serialNumber: 'GS0002000004',
      status: 'provisioned',
      deviceType: 'walker_cap',
      walkerId: 'f6a7b8c9-2222-4444-8888-eeeeeeeeeeee',
      owningClientId: 'dtc_demo03',
      patientId: 'pat_demo_bob',
      batteryPct: 0.12,
      lastSeen: DateTime.now().subtract(const Duration(minutes: 12)),
      firmware: 'wlk-1.2.0',
      rsrpDbm: -119,
      activationPending: true, // provisioned but not yet activated
    ),
  ];

  @override
  Future<List<FleetDevice>> listFleet() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return List.unmodifiable(_fleet);
  }

  int _idx(String serial) =>
      _fleet.indexWhere((d) => d.serialNumber == serial);

  void _replace(String serial, FleetDevice next) {
    final i = _idx(serial);
    if (i >= 0) _fleet[i] = next;
  }

  FleetDevice _base(String serial) => _fleet[_idx(serial)];

  @override
  Future<void> provision(String serial, String patientId) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: 'provisioned',
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: d.owningClientId, patientId: patientId,
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb, activationPending: true,
    ));
  }

  @override
  Future<void> endAssignment(String serial) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: 'discontinued',
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: d.owningClientId,
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb, wipePending: true,
    ));
  }

  @override
  Future<void> forceReset(String serial, String reason) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: 'ready_to_provision',
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: d.owningClientId,
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb,
    ));
  }

  @override
  Future<void> decommission(String serial, String reason) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: 'decommissioned',
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: d.owningClientId,
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb, decommissionReason: reason,
    ));
  }

  @override
  Future<void> recover(String serial) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: 'ready_to_provision',
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: d.owningClientId,
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb,
    ));
  }

  @override
  Future<void> release(String serial) async {
    final d = _base(serial);
    _replace(serial, FleetDevice(
      serialNumber: d.serialNumber, status: d.status,
      deviceType: d.deviceType, walkerId: d.walkerId,
      owningClientId: null, // released → claimable by a new household
      batteryPct: d.batteryPct, lastSeen: d.lastSeen, firmware: d.firmware,
      rsrpDbm: d.rsrpDbm, snrDb: d.snrDb, wipeComplete: d.wipeComplete,
    ));
  }
}
