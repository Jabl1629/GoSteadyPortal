import '../models/user.dart';

/// Response shapes for the GoSteady portal API.
///
/// Phase 2B-0 ships only [MeResponse] (consumed by the smoke screen).
/// The remaining models are declared as empty stubs that subsequent
/// 2B subsets fill in:
///   - 2B-FAC-R: MePatientsResponse, PatientDetailResponse,
///     ActivityResponse, AlertsResponse, DeviceResponse,
///     CensusRosterResponse
///   - 2B-FAC-W: write-response shapes
///
/// Per phase-2b-0-foundation.md §Interfaces > ApiClient.

/// Decoded payload of `GET /api/v1/me`.
///
/// Phase 2A-0 returns the JWT claims the handler received, mirrored
/// back — used by the smoke screen + the live-mode `AuthService` to
/// re-validate claims independent of the SDK-side ID-token parse.
class MeResponse {
  final String userId;
  final String? clientId;
  final UserRole role;
  final List<String> facilities;
  final List<String> censuses;
  final bool internalAccess;

  /// The full raw claim map — useful for the dev smoke screen which
  /// renders the payload verbatim.
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

// ── 2B-FAC-R stubs ────────────────────────────────────────────────
// Filled in when the live data layer wires per-screen.
class MePatientsResponse {
  const MePatientsResponse();
}

class PatientDetailResponse {
  const PatientDetailResponse();
}

class ActivityResponse {
  const ActivityResponse();
}

class AlertsResponse {
  const AlertsResponse();
}

class DeviceResponse {
  const DeviceResponse();
}

class CensusRosterResponse {
  const CensusRosterResponse();
}

/// Time range for activity queries — 2A-RD `?range=` enum.
enum ActivityRange {
  h24('24h'),
  d7('7d'),
  d30('30d');

  final String wireValue;
  const ActivityRange(this.wireValue);
}

/// Alert filter for `/alerts?status=` — 2A-RD enum.
enum AlertStatus {
  unacknowledged('unacknowledged'),
  acknowledged('acknowledged'),
  all('all');

  final String wireValue;
  const AlertStatus(this.wireValue);
}
