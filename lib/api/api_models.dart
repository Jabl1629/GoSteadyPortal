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

  const CurrentDevice({
    required this.serialNumber,
    required this.status,
    this.lastSeen,
  });

  factory CurrentDevice.fromJson(Map<String, dynamic> json) {
    return CurrentDevice(
      serialNumber: (json['serialNumber'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'unknown',
      lastSeen: _parseTs(json['lastSeen']),
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
/// phase-2a-read.md §Response shapes. Note: gait fields are NOT
/// present in this API response (per phase-2b-fac-r L8 — V1 firmware
/// + 2A-RD don't emit per-session gait).
class ActivitySession {
  final DateTime sessionStart;
  final DateTime sessionEnd;
  final String date; // facility-local date string per L7
  final String? timezone;
  final int steps;
  final double distanceFt;
  final int activeMinutes;
  final String? deviceSerial;
  final double? roughnessR;
  final String? surfaceClass;
  final String? firmwareVersion;

  const ActivitySession({
    required this.sessionStart,
    required this.sessionEnd,
    required this.date,
    this.timezone,
    required this.steps,
    required this.distanceFt,
    required this.activeMinutes,
    this.deviceSerial,
    this.roughnessR,
    this.surfaceClass,
    this.firmwareVersion,
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
      roughnessR: _parseDouble(json['roughnessR']),
      surfaceClass: json['surfaceClass'] as String?,
      firmwareVersion: json['firmwareVersion'] as String?,
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
  final String alertType;
  final String severity;
  final String? source;
  final bool acknowledged;
  final Map<String, dynamic>? data;
  final String? deviceSerial;

  const AlertRow({
    required this.eventTimestamp,
    required this.eventTimestampRaw,
    required this.alertType,
    required this.severity,
    this.source,
    required this.acknowledged,
    this.data,
    this.deviceSerial,
  });

  /// Compound SK for `PATCH /alerts/{patientId}/{sk}` (2B-FAC-W).
  String get sk => '$eventTimestampRaw#$alertType';

  factory AlertRow.fromJson(Map<String, dynamic> json) {
    final tsRaw = json['eventTimestamp']?.toString() ?? '';
    return AlertRow(
      eventTimestamp: _parseTs(tsRaw) ?? DateTime.now(),
      eventTimestampRaw: tsRaw,
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
