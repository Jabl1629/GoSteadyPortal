import '../models/user.dart';

/// Response shapes for the GoSteady portal API.
///
/// Per phase-2b-0-foundation.md §Interfaces > ApiClient + phase-2a-read.md
/// §Response shapes. Field names match the 2A-RD JSON contracts exactly.
///
/// Decoders are forgiving (`?? null`, `?? const []`) — server is the
/// source of truth on what's optional vs required, so we don't enforce
/// strict required-field semantics client-side.

// ── /me/patients ──────────────────────────────────────────────────

class MePatientsResponse {
  final List<MePatientSummary> patients;
  final String? nextCursor;
  final MeScope? scope;

  const MePatientsResponse({
    required this.patients,
    this.nextCursor,
    this.scope,
  });

  factory MePatientsResponse.fromJson(Map<String, dynamic> json) {
    return MePatientsResponse(
      patients: ((json['patients'] as List?) ?? const [])
          .map((e) => MePatientSummary.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
      scope: json['scope'] == null
          ? null
          : MeScope.fromJson(json['scope'] as Map<String, dynamic>),
    );
  }
}

class MePatientSummary {
  final String patientId;
  final String displayName;
  final String status;
  final String? facilityId; // not in spec but useful for client-side filtering
  final String? facilityName;
  final String? censusId; // same — derived client-side from the response
  final String? censusName;
  final String? currentDeviceSerial;
  final DateTime? lastActivityAt;
  // When monitoring ended (status != active) — drives the "Discontinued <date>"
  // row in the Show-discontinued view.
  final DateTime? dischargedAt;
  final int openAlertCount;
  // US-31: active-only; null when not currently paused. Server projects
  // the same shape as the detail view so client deserialization is
  // symmetric across tiers.
  final NotificationsPaused? notificationsPaused;

  const MePatientSummary({
    required this.patientId,
    required this.displayName,
    required this.status,
    this.facilityId,
    this.facilityName,
    this.censusId,
    this.censusName,
    this.currentDeviceSerial,
    this.lastActivityAt,
    this.dischargedAt,
    required this.openAlertCount,
    this.notificationsPaused,
  });

  factory MePatientSummary.fromJson(Map<String, dynamic> json) {
    final paused = json['notificationsPaused'] as Map<String, dynamic>?;
    return MePatientSummary(
      patientId: (json['patientId'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'active',
      facilityId: json['facilityId'] as String?,
      facilityName: json['facilityName'] as String?,
      censusId: json['censusId'] as String?,
      censusName: json['censusName'] as String?,
      currentDeviceSerial: json['currentDeviceSerial'] as String?,
      lastActivityAt: _parseTs(json['lastActivityAt']),
      dischargedAt: _parseTs(json['dischargedAt']),
      openAlertCount: _parseInt(json['openAlertCount']) ?? 0,
      notificationsPaused:
          paused == null ? null : NotificationsPaused.fromJson(paused),
    );
  }
}

class MeScope {
  final String role;
  final int facilityCount;
  final int censusCount;

  const MeScope({
    required this.role,
    required this.facilityCount,
    required this.censusCount,
  });

  factory MeScope.fromJson(Map<String, dynamic> json) {
    return MeScope(
      role: (json['role'] as String?) ?? 'caregiver',
      facilityCount: _parseInt(json['facilityCount']) ?? 0,
      censusCount: _parseInt(json['censusCount']) ?? 0,
    );
  }
}

// ── /patients/{id} ────────────────────────────────────────────────

class PatientDetailResponse {
  final PatientFull patient;

  const PatientDetailResponse({required this.patient});

  factory PatientDetailResponse.fromJson(Map<String, dynamic> json) {
    return PatientDetailResponse(
      patient: PatientFull.fromJson(
        (json['patient'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}

class PatientFull {
  final String patientId;
  final String displayName;
  final String status;
  final String? timezone;
  final String? clientId;
  final String? facilityId;
  final String? facilityName;
  final String? censusId;
  final String? censusName;
  final String? room;
  final CurrentDevice? currentDevice;
  // 2A-UM-P additions — both fields are absent for patients without
  // a note / pause; null is the "unset" sentinel.
  final CareNote? careNote;
  final NotificationsPaused? notificationsPaused;

  const PatientFull({
    required this.patientId,
    required this.displayName,
    required this.status,
    this.timezone,
    this.clientId,
    this.facilityId,
    this.facilityName,
    this.censusId,
    this.censusName,
    this.room,
    this.currentDevice,
    this.careNote,
    this.notificationsPaused,
  });

  factory PatientFull.fromJson(Map<String, dynamic> json) {
    final dev = json['currentDevice'] as Map<String, dynamic>?;
    final note = json['careNote'] as Map<String, dynamic>?;
    final paused = json['notificationsPaused'] as Map<String, dynamic>?;
    return PatientFull(
      patientId: (json['patientId'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'active',
      timezone: json['timezone'] as String?,
      clientId: json['clientId'] as String?,
      facilityId: json['facilityId'] as String?,
      facilityName: json['facilityName'] as String?,
      censusId: json['censusId'] as String?,
      censusName: json['censusName'] as String?,
      room: json['room'] as String?,
      currentDevice: dev == null ? null : CurrentDevice.fromJson(dev),
      careNote: note == null ? null : CareNote.fromJson(note),
      notificationsPaused:
          paused == null ? null : NotificationsPaused.fromJson(paused),
    );
  }
}

class CareNote {
  final String text;
  final String updatedBy;
  final String? updatedByName;
  final DateTime updatedAt;

  const CareNote({
    required this.text,
    required this.updatedBy,
    this.updatedByName,
    required this.updatedAt,
  });

  factory CareNote.fromJson(Map<String, dynamic> json) {
    return CareNote(
      text: (json['text'] as String?) ?? '',
      updatedBy: (json['updatedBy'] as String?) ?? '',
      updatedByName: json['updatedByName'] as String?,
      updatedAt: _parseTs(json['updatedAt']) ?? DateTime.now(),
    );
  }
}

class NotificationsPaused {
  final DateTime until;
  final String reason;
  final DateTime? pausedAt;
  final String? pausedBy;

  const NotificationsPaused({
    required this.until,
    required this.reason,
    this.pausedAt,
    this.pausedBy,
  });

  factory NotificationsPaused.fromJson(Map<String, dynamic> json) {
    // Server stores `until` / `pausedAt` as Unix epoch seconds (see
    // patient-mgmt _shared/pause_check.compute_until_epoch). DDB
    // serializes Numbers as JSON strings, so we may get either a
    // numeric or a string-of-digits. `_parseEpochOrTs` handles both
    // alongside ISO 8601 for forward compat.
    return NotificationsPaused(
      until: _parseEpochOrTs(json['until']) ?? DateTime.now(),
      reason: (json['reason'] as String?) ?? 'other',
      pausedAt: _parseEpochOrTs(json['pausedAt']),
      pausedBy: json['pausedBy'] as String?,
    );
  }

  bool get isActive => until.isAfter(DateTime.now());
}

class CurrentDevice {
  final String serialNumber;
  final String status;
  final DateTime? lastSeen;

  /// Device type (`walker_cap` | `rollator_platform`); null → walker_cap per
  /// DT-0 D9. Drives which per-type widget set the D2C dashboard renders,
  /// including before the patient's first session (DT-4).
  final String? deviceType;

  const CurrentDevice({
    required this.serialNumber,
    required this.status,
    this.lastSeen,
    this.deviceType,
  });

  factory CurrentDevice.fromJson(Map<String, dynamic> json) {
    return CurrentDevice(
      serialNumber: (json['serialNumber'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'unknown',
      lastSeen: _parseTs(json['lastSeen']),
      deviceType: json['deviceType'] as String?,
    );
  }
}

// ── /patients/{id}/activity ───────────────────────────────────────

class ActivityResponse {
  final List<ActivitySession> sessions;
  final ActivityRange range;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final String? nextCursor;

  const ActivityResponse({
    required this.sessions,
    required this.range,
    this.windowStart,
    this.windowEnd,
    this.nextCursor,
  });

  factory ActivityResponse.fromJson(Map<String, dynamic> json) {
    return ActivityResponse(
      sessions: ((json['sessions'] as List?) ?? const [])
          .map((e) => ActivitySession.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      range: _parseRange(json['range']),
      windowStart: _parseTs(json['windowStart']),
      windowEnd: _parseTs(json['windowEnd']),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

/// One walking session emitted by the firmware on session-stop. Per
/// phase-2a-read.md §Response shapes. `gaitSpeedFts` (ft/s, session-avg
/// walking speed) is present as of firmware 0.16.0-gait + 2A-RD gait
/// plumbing (spec 2026-06-07-gait-speed.md); null when the firmware
/// omitted it (on-device guards failed) or pre-0.16.0 cohorts.
class ActivitySession {
  final DateTime sessionStart;
  final DateTime sessionEnd;
  final String date; // facility-local date string per L7
  final String? timezone;
  final int steps;
  final double distanceFt;
  final int activeMinutes;
  final String? deviceSerial;

  /// Device type (`walker_cap` | `rollator_platform`) denormalized onto the
  /// row (DT-0); null on pre-DT-0 rows → readers treat as walker_cap (D9).
  /// The D2C dashboard keys per-type rendering on this (DT-4).
  final String? deviceType;
  final double? roughnessR;
  final String? surfaceClass;
  final String? firmwareVersion;
  final double? gaitSpeedFts;

  const ActivitySession({
    required this.sessionStart,
    required this.sessionEnd,
    required this.date,
    this.timezone,
    required this.steps,
    required this.distanceFt,
    required this.activeMinutes,
    this.deviceSerial,
    this.deviceType,
    this.roughnessR,
    this.surfaceClass,
    this.firmwareVersion,
    this.gaitSpeedFts,
  });

  factory ActivitySession.fromJson(Map<String, dynamic> json) {
    return ActivitySession(
      sessionStart: _parseTs(json['sessionStart']) ?? DateTime.now(),
      sessionEnd: _parseTs(json['sessionEnd']) ?? DateTime.now(),
      date: (json['date'] as String?) ?? '',
      timezone: json['timezone'] as String?,
      steps: _parseInt(json['steps']) ?? 0,
      distanceFt: _parseDouble(json['distanceFt']) ?? 0.0,
      activeMinutes: _parseInt(json['activeMinutes']) ?? 0,
      deviceSerial: json['deviceSerial'] as String?,
      deviceType: json['deviceType'] as String?,
      roughnessR: _parseDouble(json['roughnessR']),
      surfaceClass: json['surfaceClass'] as String?,
      firmwareVersion: json['firmwareVersion'] as String?,
      gaitSpeedFts: _parseDouble(json['gaitSpeedFts']),
    );
  }
}

/// Time range for activity queries — 2A-RD `?range=` enum.
enum ActivityRange {
  h24('24h'),
  d7('7d'),
  d30('30d');

  final String wireValue;
  const ActivityRange(this.wireValue);
}

ActivityRange _parseRange(Object? raw) {
  final s = raw?.toString() ?? '24h';
  return ActivityRange.values.firstWhere(
    (r) => r.wireValue == s,
    orElse: () => ActivityRange.h24,
  );
}

// ── /patients/{id}/alerts ─────────────────────────────────────────

class AlertsResponse {
  final List<AlertRow> alerts;
  final AlertStatus filter;
  final String? nextCursor;

  const AlertsResponse({
    required this.alerts,
    required this.filter,
    this.nextCursor,
  });

  factory AlertsResponse.fromJson(Map<String, dynamic> json) {
    return AlertsResponse(
      alerts: ((json['alerts'] as List?) ?? const [])
          .map((e) => AlertRow.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      filter: _parseAlertStatus(json['filter']),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

class AlertRow {
  final DateTime eventTimestamp;
  /// Raw ISO-8601 string as the server sent it. Preserves the
  /// timezone offset of the original `{eventTs}#{alertType}` SK so
  /// 2B-FAC-W's `PATCH /alerts/{patientId}/{sk}` round-trips
  /// correctly. (Some rows were written with facility-local offsets
  /// like `-06:00`; converting to UTC would produce a different SK
  /// that doesn't match the stored row.)
  final String eventTimestampRaw;

  /// When the row was written, per the server. Null on rows predating the
  /// projection (and on any producer that omits it).
  ///
  /// Prefer this over [eventTimestamp] for "how long ago was this raised?".
  /// The daily-cadence behavioral rules (`no_activity_today`,
  /// `below_typical_activity`, `declining_trend`) anchor [eventTimestamp] to
  /// facility-local midnight — that is the day the alert is ABOUT and the
  /// sort key that makes it once-per-day — so an alert raised at 11:00
  /// local would otherwise render as "Triggered 11h ago" the moment it
  /// appeared. Use [raisedAt].
  final DateTime? createdAt;
  final String alertType;
  final String severity;
  final String? source;
  final bool acknowledged;
  final Map<String, dynamic>? data;
  final String? deviceSerial;

  const AlertRow({
    required this.eventTimestamp,
    required this.eventTimestampRaw,
    this.createdAt,
    required this.alertType,
    required this.severity,
    this.source,
    required this.acknowledged,
    this.data,
    this.deviceSerial,
  });

  /// Compound SK for `PATCH /alerts/{patientId}/{sk}` (2B-FAC-W).
  String get sk => '$eventTimestampRaw#$alertType';

  /// When this alert was raised — the timestamp to age against for display.
  /// Falls back to [eventTimestamp] on rows with no [createdAt], which is
  /// correct for the real-time producers (threshold-detector, offline rules,
  /// firmware) where the two coincide anyway.
  DateTime get raisedAt => createdAt ?? eventTimestamp;

  factory AlertRow.fromJson(Map<String, dynamic> json) {
    final tsRaw = json['eventTimestamp']?.toString() ?? '';
    return AlertRow(
      eventTimestamp: _parseTs(tsRaw) ?? DateTime.now(),
      eventTimestampRaw: tsRaw,
      createdAt: _parseTs(json['createdAt']?.toString() ?? ''),
      alertType: (json['alertType'] as String?) ?? 'unknown',
      severity: (json['severity'] as String?) ?? 'standard',
      source: json['source'] as String?,
      acknowledged: (json['acknowledged'] as bool?) ?? false,
      data: json['data'] as Map<String, dynamic>?,
      deviceSerial: json['deviceSerial'] as String?,
    );
  }
}

/// Alert filter for `/alerts?status=` — 2A-RD enum.
enum AlertStatus {
  unacknowledged('unacknowledged'),
  acknowledged('acknowledged'),
  all('all');

  final String wireValue;
  const AlertStatus(this.wireValue);
}

AlertStatus _parseAlertStatus(Object? raw) {
  final s = raw?.toString() ?? 'unacknowledged';
  return AlertStatus.values.firstWhere(
    (a) => a.wireValue == s,
    orElse: () => AlertStatus.unacknowledged,
  );
}

// ── /facilities/{f}/censuses/{c}/patients ─────────────────────────

class CensusRosterResponse {
  final CensusInfo census;
  final List<MePatientSummary> patients; // same row shape as /me/patients
  final String? nextCursor;

  const CensusRosterResponse({
    required this.census,
    required this.patients,
    this.nextCursor,
  });

  factory CensusRosterResponse.fromJson(Map<String, dynamic> json) {
    return CensusRosterResponse(
      census: CensusInfo.fromJson(
        (json['census'] as Map<String, dynamic>?) ?? const {},
      ),
      patients: ((json['patients'] as List?) ?? const [])
          .map((e) => MePatientSummary.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

class CensusInfo {
  final String facilityId;
  final String facilityName;
  final String censusId;
  final String censusName;

  const CensusInfo({
    required this.facilityId,
    required this.facilityName,
    required this.censusId,
    required this.censusName,
  });

  factory CensusInfo.fromJson(Map<String, dynamic> json) {
    return CensusInfo(
      facilityId: (json['facilityId'] as String?) ?? '',
      facilityName: (json['facilityName'] as String?) ?? '',
      censusId: (json['censusId'] as String?) ?? '',
      censusName: (json['censusName'] as String?) ?? '',
    );
  }
}

// ── /devices/{serial} (stub — endpoint not in 2A-RD per FAC-R Q5) ─

class DeviceResponse {
  final String serialNumber;
  final String? status;
  final String? firmwareVersion;
  final DateTime? lastSeen;
  final double? batteryPct;
  final int? batteryMv;
  final int? rsrpDbm;
  final int? snrDb;

  const DeviceResponse({
    required this.serialNumber,
    this.status,
    this.firmwareVersion,
    this.lastSeen,
    this.batteryPct,
    this.batteryMv,
    this.rsrpDbm,
    this.snrDb,
  });

  factory DeviceResponse.fromJson(Map<String, dynamic> json) {
    // `GET /devices/{serial}` nests live (Shadow-sourced) values under
    // `telemetry`; device-lifecycle responses (provision / end-assignment)
    // carry only the registry view with no telemetry. Read nested-first,
    // fall back to top-level for compat.
    final t = json['telemetry'] as Map<String, dynamic>?;
    return DeviceResponse(
      serialNumber: (json['serialNumber'] as String?) ?? '',
      status: json['status'] as String?,
      firmwareVersion:
          (t?['firmware'] as String?) ?? json['firmwareVersion'] as String?,
      lastSeen: _parseTs(t?['lastSeen'] ?? json['lastSeen']),
      batteryPct: _parseDouble(t?['batteryPct'] ?? json['batteryPct']),
      batteryMv: _parseInt(t?['batteryMv'] ?? json['batteryMv']),
      rsrpDbm: _parseInt(t?['rsrpDbm'] ?? json['rsrpDbm']),
      snrDb: _parseInt(t?['snrDb'] ?? json['snrDb']),
    );
  }
}

// ── /api/v1/admin/devices (internal fleet board) ──────────────────

/// One row of the internal fleet board (`GET /api/v1/admin/devices`,
/// device-api `_fleet_row`). Registry lifecycle fields + a flattened live
/// Shadow telemetry read + the current assignment's patient + the derived
/// lifecycle flags a fleet operator needs. Internal-only; mirrors the
/// `tools/fleet.py` row shape so the screen and CLI agree.
class FleetDevice {
  final String serialNumber;
  final String? status;
  final String? deviceType;
  final String? walkerId;
  final String? owningClientId;

  // From the joined active assignment (null unless provisioned/monitoring).
  final String? patientId;

  // Flattened from the nested `telemetry` object (live Shadow read).
  final double? batteryPct;
  final DateTime? lastSeen;
  final String? firmware;
  final int? rsrpDbm;
  final int? snrDb;
  final String? wipeComplete; // reported.wipe_complete — the wipe-verified signal

  // Derived lifecycle flags.
  final bool activationPending;
  final bool wipePending;
  final String? decommissionReason;

  /// Masked intended-recipient phone (`•••-1234`) when the device is
  /// claim-bound (reserved) — d2c-claim-binding.md §5.4. Never the raw
  /// phone or the HMAC.
  final String? claimBoundPhoneMask;

  const FleetDevice({
    required this.serialNumber,
    this.status,
    this.deviceType,
    this.walkerId,
    this.owningClientId,
    this.patientId,
    this.batteryPct,
    this.lastSeen,
    this.firmware,
    this.rsrpDbm,
    this.snrDb,
    this.wipeComplete,
    this.activationPending = false,
    this.wipePending = false,
    this.decommissionReason,
    this.claimBoundPhoneMask,
  });

  factory FleetDevice.fromJson(Map<String, dynamic> json) {
    final t = json['telemetry'] as Map<String, dynamic>?;
    final a = json['currentAssignment'] as Map<String, dynamic>?;
    return FleetDevice(
      serialNumber: (json['serialNumber'] as String?) ?? '',
      status: json['status'] as String?,
      deviceType: (json['deviceType'] as String?) ?? 'walker_cap',
      walkerId: json['walkerId'] as String?,
      owningClientId: json['owningClientId'] as String?,
      patientId: a?['patientId'] as String?,
      batteryPct: _parseDouble(t?['batteryPct']),
      lastSeen: _parseTs(t?['lastSeen']),
      firmware: t?['firmware'] as String?,
      rsrpDbm: _parseInt(t?['rsrpDbm']),
      snrDb: _parseInt(t?['snrDb']),
      wipeComplete: t?['wipeComplete']?.toString(),
      activationPending: (json['activationPending'] as bool?) ?? false,
      wipePending: (json['wipePending'] as bool?) ?? false,
      decommissionReason: json['decommissionReason'] as String?,
      claimBoundPhoneMask: json['claimBoundPhoneMask'] as String?,
    );
  }

  /// True once the device has ever reported a Shadow (has live telemetry).
  bool get hasConnected => lastSeen != null;
}

class FleetDevicesResponse {
  final List<FleetDevice> devices;
  final int count;

  const FleetDevicesResponse({required this.devices, required this.count});

  factory FleetDevicesResponse.fromJson(Map<String, dynamic> json) {
    final devices = ((json['devices'] as List?) ?? const [])
        .map((e) => FleetDevice.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return FleetDevicesResponse(
      devices: devices,
      count: _parseInt(json['count']) ?? devices.length,
    );
  }
}

// ── /api/v1/me (existing from 2B-0) ───────────────────────────────

class MeResponse {
  final String userId;
  final String? clientId;
  final UserRole role;
  final List<String> facilities;
  final List<String> censuses;
  final bool internalAccess;
  final Map<String, dynamic> raw;

  const MeResponse({
    required this.userId,
    required this.clientId,
    required this.role,
    required this.facilities,
    required this.censuses,
    required this.internalAccess,
    required this.raw,
  });

  factory MeResponse.fromJson(Map<String, dynamic> json) {
    return MeResponse(
      userId: (json['userId'] as String?) ?? '',
      clientId: json['clientId'] as String?,
      role: UserRole.fromString(json['role'] as String?),
      facilities: _csv(json['facilities']),
      censuses: _csv(json['censuses']),
      internalAccess: (json['internalAccess'] as bool?) ?? false,
      raw: json,
    );
  }

  static List<String> _csv(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value.map((e) => e.toString()).toList(growable: false);
    }
    final s = value.toString().trim();
    if (s.isEmpty) return const [];
    return s.split(',').map((e) => e.trim()).toList(growable: false);
  }
}

// ── Helpers ───────────────────────────────────────────────────────

DateTime? _parseTs(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// Accepts Unix epoch (seconds or ms, int or stringified-int) AND ISO
/// 8601. Useful for DDB-sourced timestamps that round-trip through
/// `Decimal -> JSON string`. Tries ISO first; falls back to epoch
/// interpretation. 10-digit values are treated as seconds, 13-digit as
/// milliseconds — sufficient for all realistic timestamps.
DateTime? _parseEpochOrTs(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final n = raw.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      n.abs() < 100000000000 ? n * 1000 : n,
      isUtc: true,
    );
  }
  final s = raw.toString();
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso;
  final asInt = int.tryParse(s);
  if (asInt == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    asInt.abs() < 100000000000 ? asInt * 1000 : asInt,
    isUtc: true,
  );
}

/// Tolerant int parser — handles raw int, num, AND JSON-string-encoded
/// numbers (the patient-api Lambda serializes DDB Decimals as strings).
int? _parseInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final s = raw.toString();
  if (s.isEmpty) return null;
  // Decimal-as-string can come through as "0", "27", "1.04" — toInt
  // any double form by truncation (we don't care about fractional steps).
  return int.tryParse(s) ?? double.tryParse(s)?.toInt();
}

/// Tolerant double parser — same rationale.
double? _parseDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is double) return raw;
  if (raw is num) return raw.toDouble();
  final s = raw.toString();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

// ── 2A-AA + 2A-UM-P write responses (consumed by 2B-FAC-W) ────────

/// `PATCH /alerts/{patientId}/{ts}` response shape.
class AckAlertResponse {
  final AlertRow alert;
  final bool wasAlreadyAcknowledged;

  const AckAlertResponse({
    required this.alert,
    required this.wasAlreadyAcknowledged,
  });

  factory AckAlertResponse.fromJson(Map<String, dynamic> json) {
    return AckAlertResponse(
      alert: AlertRow.fromJson(
        (json['alert'] as Map<String, dynamic>?) ?? const {},
      ),
      wasAlreadyAcknowledged:
          (json['wasAlreadyAcknowledged'] as bool?) ?? false,
    );
  }
}

/// `POST /patients/{id}/discharge` response shape.
class DischargeResponse {
  final PatientFull patient;
  final DischargeCascadeInfo cascade;

  const DischargeResponse({required this.patient, required this.cascade});

  factory DischargeResponse.fromJson(Map<String, dynamic> json) {
    return DischargeResponse(
      patient: PatientFull.fromJson(
        (json['patient'] as Map<String, dynamic>?) ?? const {},
      ),
      cascade: DischargeCascadeInfo.fromJson(
        (json['cascade'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}

class DischargeCascadeInfo {
  final int devicesEnded;
  final List<String> deviceSerials;
  final bool wipeRequested;

  const DischargeCascadeInfo({
    required this.devicesEnded,
    required this.deviceSerials,
    required this.wipeRequested,
  });

  factory DischargeCascadeInfo.fromJson(Map<String, dynamic> json) {
    final serials =
        (json['deviceSerials'] as List?)?.map((e) => e.toString()).toList() ??
            const [];
    return DischargeCascadeInfo(
      devicesEnded: (json['devicesEnded'] as int?) ?? 0,
      deviceSerials: serials,
      wipeRequested: (json['wipeRequested'] as bool?) ?? false,
    );
  }
}

/// `POST/DELETE /patients/{id}/notifications/pause` response shape.
class NotificationsPauseResponse {
  final NotificationsPaused? notificationsPaused;

  const NotificationsPauseResponse({this.notificationsPaused});

  factory NotificationsPauseResponse.fromJson(Map<String, dynamic> json) {
    final p = json['notificationsPaused'] as Map<String, dynamic>?;
    return NotificationsPauseResponse(
      notificationsPaused: p == null ? null : NotificationsPaused.fromJson(p),
    );
  }
}

/// `PATCH /patients/{id}/care-note` response shape.
class CareNoteResponse {
  final CareNote? careNote;

  const CareNoteResponse({this.careNote});

  factory CareNoteResponse.fromJson(Map<String, dynamic> json) {
    final n = json['careNote'] as Map<String, dynamic>?;
    return CareNoteResponse(careNote: n == null ? null : CareNote.fromJson(n));
  }
}

/// Pause-notifications reasons per 2A-UM-P L6 enum.
enum PauseReason {
  inHospital('in_hospital'),
  atRehab('at_rehab'),
  familyVisitOffsite('family_visit_offsite'),
  onVacation('on_vacation'),
  other('other');

  final String wireValue;
  const PauseReason(this.wireValue);

  String get label {
    switch (this) {
      case PauseReason.inHospital:
        return 'In hospital';
      case PauseReason.atRehab:
        return 'At rehab';
      case PauseReason.familyVisitOffsite:
        return 'Family visit (off-site)';
      case PauseReason.onVacation:
        return 'On vacation';
      case PauseReason.other:
        return 'Other';
    }
  }
}

// DischargeReason enum removed 2026-06-03 — "End Monitoring" (the renamed
// discharge action) collects no reason. The backend still accepts an optional
// free-text `reason` if one is ever sent.

// ── /patients/{id}/devices — monitoring-session history ────────────

/// One monitoring period from `GET /api/v1/patients/{id}/devices` — a
/// projected DeviceAssignments row (device-api `_assignment_view`). Each row
/// is the device + when monitoring started/ended ([endedAt] null = ongoing).
/// Backs the patient-detail "Monitoring history" modal.
class MonitoringSession {
  final String serialNumber;
  final DateTime? startedAt;
  final DateTime? endedAt; // null = currently ongoing
  final bool ongoing;
  final int? durationSeconds; // null when ongoing / unparseable
  final String? facilityId;
  final String? censusId;

  const MonitoringSession({
    required this.serialNumber,
    required this.startedAt,
    required this.endedAt,
    required this.ongoing,
    this.durationSeconds,
    this.facilityId,
    this.censusId,
  });

  factory MonitoringSession.fromJson(Map<String, dynamic> json) {
    final ended = _parseTs(json['endedAt']);
    return MonitoringSession(
      serialNumber: (json['serialNumber'] as String?) ?? '',
      startedAt: _parseTs(json['startedAt']),
      endedAt: ended,
      // Trust the server's `ongoing` flag; fall back to endedAt == null.
      ongoing: (json['ongoing'] as bool?) ?? (ended == null),
      durationSeconds: _parseInt(json['durationSeconds']),
      facilityId: json['facilityId'] as String?,
      censusId: json['censusId'] as String?,
    );
  }
}

// ── Internal user analytics (docs/specs/user-analytics.md) ──────────────

/// One (label, count) point — an offload-per-day date or an offload-per-hour
/// hour-of-day bucket.
class AnalyticsBucket {
  final String label;
  final int count;
  const AnalyticsBucket({required this.label, required this.count});
}

/// #3 OTP funnel. `abandonmentRate` is 0-1, or null when nothing was requested.
class OtpFunnel {
  final int requested;
  final int completed;
  final int abandoned;
  final int verifyFailed;
  final double? abandonmentRate;

  const OtpFunnel({
    required this.requested,
    required this.completed,
    required this.abandoned,
    required this.verifyFailed,
    this.abandonmentRate,
  });

  factory OtpFunnel.fromJson(Map<String, dynamic> json) => OtpFunnel(
        requested: _parseInt(json['requested']) ?? 0,
        completed: _parseInt(json['completed']) ?? 0,
        abandoned: _parseInt(json['abandoned']) ?? 0,
        verifyFailed: _parseInt(json['verifyFailed']) ?? 0,
        abandonmentRate: _parseDouble(json['abandonmentRate']),
      );
}

/// #1 offloads — total + per-day time series + per-hour-of-day histogram.
class OffloadBuckets {
  final int total;
  final List<AnalyticsBucket> perDay;
  final List<AnalyticsBucket> perHour;

  const OffloadBuckets({
    required this.total,
    required this.perDay,
    required this.perHour,
  });

  factory OffloadBuckets.fromJson(Map<String, dynamic> json) {
    List<AnalyticsBucket> buckets(Object? raw, String labelKey) =>
        ((raw as List?) ?? const [])
            .map((e) => AnalyticsBucket(
                  label: (e as Map)[labelKey].toString(),
                  count: _parseInt(e['count']) ?? 0,
                ))
            .toList(growable: false);
    return OffloadBuckets(
      total: _parseInt(json['total']) ?? 0,
      perDay: buckets(json['perDay'], 'date'),
      perHour: buckets(json['perHour'], 'hour'),
    );
  }
}

/// Population overview (`GET /admin/analytics/overview`).
class AnalyticsOverview {
  final String range;
  final int loginsTotal;
  final Map<String, int> loginsByMethod;
  final OtpFunnel otp;
  final int activeUsers;
  final double avgSessionMinutes;
  final OffloadBuckets offloads;
  final int coachTurns;
  final int coachActiveUsers;
  final String insightsStatus;
  final bool offloadTruncated;

  const AnalyticsOverview({
    required this.range,
    required this.loginsTotal,
    required this.loginsByMethod,
    required this.otp,
    required this.activeUsers,
    required this.avgSessionMinutes,
    required this.offloads,
    required this.coachTurns,
    required this.coachActiveUsers,
    required this.insightsStatus,
    required this.offloadTruncated,
  });

  factory AnalyticsOverview.fromJson(Map<String, dynamic> json) {
    final logins = (json['logins'] as Map?) ?? const {};
    final byMethod = <String, int>{};
    ((logins['byMethod'] as Map?) ?? const {}).forEach((k, v) {
      byMethod[k.toString()] = _parseInt(v) ?? 0;
    });
    final coach = (json['coach'] as Map?) ?? const {};
    final meta = (json['meta'] as Map?) ?? const {};
    return AnalyticsOverview(
      range: (json['range'] as String?) ?? '',
      loginsTotal: _parseInt(logins['total']) ?? 0,
      loginsByMethod: byMethod,
      otp: OtpFunnel.fromJson(
          ((json['otp'] as Map?) ?? const {}).cast<String, dynamic>()),
      activeUsers: _parseInt(json['activeUsers']) ?? 0,
      avgSessionMinutes: _parseDouble(json['avgSessionMinutes']) ?? 0.0,
      offloads: OffloadBuckets.fromJson(
          ((json['offloads'] as Map?) ?? const {}).cast<String, dynamic>()),
      coachTurns: _parseInt(coach['turns']) ?? 0,
      coachActiveUsers: _parseInt(coach['activeUsers']) ?? 0,
      insightsStatus: (meta['insightsStatus'] as String?) ?? '',
      offloadTruncated: (meta['offloadTruncated'] as bool?) ?? false,
    );
  }
}

/// One row of the per-user analytics table.
class AnalyticsUserRow {
  final String userId;
  final String clientId;
  final String role;

  /// True when this user IS the walker/device user (the authoritative
  /// `isWalkerUser` flag); false for non-walker Care Circle members
  /// (family viewers, caregiver-owners) and facility/internal users. Drives
  /// the walker-vs-care-circle segment toggle.
  final bool isWalkerUser;
  final String deviceSerial;

  /// The device's REAL last-seen — Device Registry `lastSeen` (last heartbeat).
  /// Distinct from [lastActive] (the user's last in-app activity). Null when the
  /// user has no device or it has never reported.
  final DateTime? deviceLastSeen;
  final int logins;
  final int otpAbandoned;
  final int otpVerifyFailed;
  final int activeMinutes;
  final int offloads;
  final int coachTurns;

  /// The USER's last in-app activity (login / dashboard read / coach turn) — NOT
  /// the device. See [deviceLastSeen] for device health.
  final DateTime? lastActive;

  const AnalyticsUserRow({
    required this.userId,
    required this.clientId,
    required this.role,
    this.isWalkerUser = false,
    required this.deviceSerial,
    this.deviceLastSeen,
    required this.logins,
    required this.otpAbandoned,
    required this.otpVerifyFailed,
    required this.activeMinutes,
    required this.offloads,
    required this.coachTurns,
    this.lastActive,
  });

  factory AnalyticsUserRow.fromJson(Map<String, dynamic> json) => AnalyticsUserRow(
        userId: (json['userId'] as String?) ?? '',
        clientId: (json['clientId'] as String?) ?? '',
        role: (json['role'] as String?) ?? '',
        isWalkerUser: json['isWalkerUser'] == true,
        deviceSerial: (json['deviceSerial'] as String?) ?? '',
        deviceLastSeen: _parseTs(json['deviceLastSeen']),
        logins: _parseInt(json['logins']) ?? 0,
        otpAbandoned: _parseInt(json['otpAbandoned']) ?? 0,
        otpVerifyFailed: _parseInt(json['otpVerifyFailed']) ?? 0,
        activeMinutes: _parseInt(json['activeMinutes']) ?? 0,
        offloads: _parseInt(json['offloads']) ?? 0,
        coachTurns: _parseInt(json['coachTurns']) ?? 0,
        lastActive: _parseTs(json['lastActive']),
      );
}

/// Per-user table response (`GET /admin/analytics/users`).
class AnalyticsUsersResponse {
  final List<AnalyticsUserRow> users;
  final int count;
  final int unattributedOffloads;
  final String insightsStatus;

  const AnalyticsUsersResponse({
    required this.users,
    required this.count,
    required this.unattributedOffloads,
    required this.insightsStatus,
  });

  factory AnalyticsUsersResponse.fromJson(Map<String, dynamic> json) {
    final users = ((json['users'] as List?) ?? const [])
        .map((e) => AnalyticsUserRow.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    final meta = (json['meta'] as Map?) ?? const {};
    return AnalyticsUsersResponse(
      users: users,
      count: _parseInt(json['count']) ?? users.length,
      unattributedOffloads: _parseInt(meta['unattributedOffloads']) ?? 0,
      insightsStatus: (meta['insightsStatus'] as String?) ?? '',
    );
  }
}

/// One row of the internal "Pilot residents" roster (GET /admin/residents).
/// Cross-tenant view of an active D2C participant + their device + last walk.
/// docs/specs/user-analytics.md §pilot view.
class ResidentRow {
  final String patientId;
  final String displayName;
  final String clientId;
  final String status;
  final String deviceSerial;
  final String deviceStatus;
  final DateTime? deviceLastSeen; // device heartbeat (registry lastSeen)
  final DateTime? lastActivityAt; // last offload / "last walk"

  const ResidentRow({
    required this.patientId,
    required this.displayName,
    required this.clientId,
    required this.status,
    required this.deviceSerial,
    required this.deviceStatus,
    this.deviceLastSeen,
    this.lastActivityAt,
  });

  factory ResidentRow.fromJson(Map<String, dynamic> json) => ResidentRow(
        patientId: (json['patientId'] as String?) ?? '',
        displayName: (json['displayName'] as String?) ?? '',
        clientId: (json['clientId'] as String?) ?? '',
        status: (json['status'] as String?) ?? '',
        deviceSerial: (json['deviceSerial'] as String?) ?? '',
        deviceStatus: (json['deviceStatus'] as String?) ?? '',
        deviceLastSeen: _parseTs(json['deviceLastSeen']),
        lastActivityAt: _parseTs(json['lastActivityAt']),
      );
}

class ResidentsResponse {
  final List<ResidentRow> residents;
  final int count;
  final bool truncated;

  const ResidentsResponse({
    required this.residents,
    required this.count,
    required this.truncated,
  });

  factory ResidentsResponse.fromJson(Map<String, dynamic> json) {
    final residents = ((json['residents'] as List?) ?? const [])
        .map((e) => ResidentRow.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return ResidentsResponse(
      residents: residents,
      count: _parseInt(json['count']) ?? residents.length,
      truncated: json['truncated'] == true,
    );
  }
}
