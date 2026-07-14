import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service_interface.dart';
import 'api_exception.dart';
import 'api_models.dart';
import 'd2c_api_models.dart';

/// Single HTTP gateway for the GoSteady portal API.
///
/// Constructor takes an [AuthServiceInterface] (for token attachment)
/// and a `baseUrl` (from `--dart-define=API_BASE_URL=`). No widget
/// makes HTTP calls directly — all calls route through here so retry,
/// refresh-on-expiry, error-envelope decoding, and audit-failure
/// telemetry live in one place.
///
/// Per phase-2b-0-foundation.md L6 + §Interfaces > ApiClient.
///
/// Phase 2B-0 implements [getMe] (consumed by the smoke screen). The
/// remaining read + write methods are declared with full signatures
/// but throw [UnimplementedError] — 2B-FAC-R / 2B-FAC-W fill them in.
class ApiClient {
  final AuthServiceInterface _auth;
  final String _baseUrl;
  final http.Client _http;

  /// Path prefix for the authenticated patient-read endpoints
  /// (`/me/patients`, `/patients/{id}`, `.../activity`, `.../alerts`).
  /// Defaults to `/api/v1` (facility pool). The D2C consumer app passes
  /// `/api/v1/d2c` so those reads hit the routes bound to the **D2C** Cognito
  /// authorizer — the facility JWT authorizer rejects D2C-pool tokens (→ 401
  /// on the dashboard's first call; coord §C54). The `claim` +
  /// public-lookup routes are already D2C/unauthenticated and are NOT
  /// prefixed. See api-stack.ts (D2C section).
  final String _readPrefix;

  ApiClient({
    required AuthServiceInterface auth,
    required String baseUrl,
    String readPathPrefix = '/api/v1',
    http.Client? httpClient,
  })  : _auth = auth,
        // Strip trailing slash to make path concatenation predictable.
        _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _readPrefix = readPathPrefix,
        _http = httpClient ?? http.Client();

  void dispose() => _http.close();

  // ── Smoke (2A-0) ──────────────────────────────────────────────

  /// `GET /api/v1/me` — returns the JWT claims the handler received.
  /// Used by the 2B-0 smoke screen + by [AuthService] to independently
  /// re-validate claims after sign-in.
  Future<MeResponse> getMe() async {
    final body = await _get('/api/v1/me');
    return MeResponse.fromJson(body);
  }

  // ── 2A-RD reads (deployed; wired in 2B-FAC-R) ─────────────────

  Future<MePatientsResponse> getMyPatients({
    String? cursor,
    String? clientId,
    String? status,
  }) async {
    final query = <String, String>{};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    if (clientId != null && clientId.isNotEmpty) query['clientId'] = clientId;
    if (status != null && status.isNotEmpty) query['status'] = status;
    final body = await _get('$_readPrefix/me/patients', query: query);
    return MePatientsResponse.fromJson(body);
  }

  Future<PatientDetailResponse> getPatient(String patientId) async {
    final body = await _get('$_readPrefix/patients/$patientId');
    return PatientDetailResponse.fromJson(body);
  }

  Future<ActivityResponse> getActivity(
    String patientId,
    ActivityRange range, {
    String? cursor,
  }) async {
    final query = <String, String>{'range': range.wireValue};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final body =
        await _get('$_readPrefix/patients/$patientId/activity', query: query);
    return ActivityResponse.fromJson(body);
  }

  Future<AlertsResponse> getAlerts(
    String patientId,
    AlertStatus status, {
    String? cursor,
  }) async {
    final query = <String, String>{'status': status.wireValue};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final body = await _get('$_readPrefix/patients/$patientId/alerts', query: query);
    return AlertsResponse.fromJson(body);
  }

  /// `GET /api/v1/devices/{serial}` — device-centric detail: Device
  /// Registry view + live Shadow `telemetry` (battery / signal / firmware /
  /// lastSeen + diagnostics). The patient-detail device card uses the
  /// battery/signal/firmware subset; the full payload backs a future
  /// device-centric screen. Telemetry is best-effort server-side (a device
  /// that never connected has no `telemetry`).
  Future<DeviceResponse> getDevice(String serial) async {
    final body = await _get('/api/v1/devices/$serial');
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Future<CensusRosterResponse> getCensusRoster(
    String facilityId,
    String censusId, {
    String? cursor,
  }) async {
    final query = <String, String>{};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final body = await _get(
      '/api/v1/facilities/$facilityId/censuses/$censusId/patients',
      query: query,
    );
    return CensusRosterResponse.fromJson(body);
  }

  // ── 2A-AA writes (deployed 2026-05-23; wired in 2B-FAC-W) ───────

  /// `PATCH /api/v1/alerts/{patientId}/{compoundSk}` — caregiver ack.
  /// The compound SK is `{eventTs}#{alertType}` and contains `#` which
  /// must be percent-encoded for safe URL routing.
  Future<AckAlertResponse> ackAlert(
    String patientId,
    String compoundSk, {
    String? notes,
  }) async {
    final encoded = Uri.encodeComponent(compoundSk);
    final body = await _request(
      'PATCH',
      '/api/v1/alerts/$patientId/$encoded',
      body: {if (notes != null) 'notes': notes},
    );
    return AckAlertResponse.fromJson(body);
  }

  // ── 2A-DL writes (deployed; wired in 2B-FAC-W follow-ups) ──────

  Future<DeviceResponse> provisionDevice(String serial, String patientId) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/provision',
      body: {'patientId': patientId},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Future<DeviceResponse> endAssignment(String serial) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/end-assignment',
      body: const <String, dynamic>{},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  // ── Internal fleet ops (device-api /admin/devices + overrides) ──
  // internal_support + internal_admin may read the fleet; writes are
  // internal_admin (+ facility/client admins) per the device-api authz
  // matrix. The server is the enforcement point; the UI gates for UX.

  /// `GET /api/v1/admin/devices` — the whole fleet (registry + live Shadow
  /// telemetry + current assignment + derived flags). Internal-only.
  Future<FleetDevicesResponse> getAdminDevices({
    String? status,
    String? deviceType,
  }) async {
    final query = <String, String>{};
    if (status != null && status.isNotEmpty) query['status'] = status;
    if (deviceType != null && deviceType.isNotEmpty) {
      query['deviceType'] = deviceType;
    }
    final body = await _get('/api/v1/admin/devices', query: query);
    return FleetDevicesResponse.fromJson(body);
  }

  /// `POST /api/v1/devices/{serial}/force-reset` — admin override →
  /// ready_to_provision (bypasses the wipe predicate; heavily audited).
  /// Requires a `reason` (≥4 chars, enforced server-side).
  Future<DeviceResponse> forceReset(String serial, String reason) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/force-reset',
      body: {'reason': reason},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// `POST /api/v1/devices/{serial}/decommission` — retire a unit.
  /// `reason` ∈ {lost, broken, retired, end_of_life}; `lost` is recoverable.
  Future<DeviceResponse> decommissionDevice(String serial, String reason) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/decommission',
      body: {'reason': reason},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// `POST /api/v1/devices/{serial}/recover` — un-retire a lost-decommissioned
  /// unit back to ready_to_provision.
  Future<DeviceResponse> recoverDevice(String serial) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/recover',
      body: const <String, dynamic>{},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// `POST /api/v1/devices/{serial}/release` — internal_admin: release ownership
  /// (owningClientId/Facility → null) so the device is claimable by a NEW
  /// household via QR. For D2C rotation between households. Requires the device
  /// to be unassigned (ready_to_provision / discontinued) — end first.
  Future<DeviceResponse> releaseDevice(String serial) async {
    final body = await _request(
      'POST',
      '/api/v1/devices/$serial/release',
      body: const <String, dynamic>{},
    );
    return DeviceResponse.fromJson(
      (body['device'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// `GET /api/v1/patients/{id}/devices` — the patient's monitoring-session
  /// history (every DeviceAssignments row), most-recent-first, projected by
  /// `device-api._assignment_view`. Backs the "Monitoring history" modal.
  Future<List<MonitoringSession>> listPatientDevices(String patientId) async {
    final body = await _get('/api/v1/patients/$patientId/devices');
    final raw = (body['assignments'] as List<dynamic>?) ?? const [];
    return raw
        .map((e) => MonitoringSession.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  // ── 2A-UM-P writes (deployed dev 2026-05-24; wired in 2B-FAC-W) ──

  Future<PatientDetailResponse> createPatient({
    required String displayName,
    required String censusId,
    required String room,
    String? deviceSerial,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/patients',
      body: {
        'displayName': displayName,
        'censusId': censusId,
        'room': room,
        if (deviceSerial != null && deviceSerial.isNotEmpty)
          'deviceSerial': deviceSerial,
      },
    );
    return PatientDetailResponse.fromJson(body);
  }

  Future<PatientDetailResponse> updatePatient(
    String patientId, {
    String? displayName,
    String? censusId,
    String? room,
  }) async {
    final patch = <String, dynamic>{};
    if (displayName != null) patch['displayName'] = displayName;
    if (censusId != null) patch['censusId'] = censusId;
    if (room != null) patch['room'] = room;
    final body = await _request(
      'PATCH',
      '/api/v1/patients/$patientId',
      body: patch,
    );
    return PatientDetailResponse.fromJson(body);
  }

  Future<DischargeResponse> dischargePatient(
    String patientId, {
    String? reason,
    String? notes,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/patients/$patientId/discharge',
      body: {
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return DischargeResponse.fromJson(body);
  }

  /// `POST /api/v1/patients/{id}/resume` — "Start Monitoring Again". Flips a
  /// discontinued resident back to active under the same record + atomically
  /// re-provisions [deviceSerial]. Same response envelope as create.
  Future<PatientDetailResponse> resumeMonitoring(
    String patientId, {
    required String censusId,
    required String room,
    required String deviceSerial,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/patients/$patientId/resume',
      body: {
        'censusId': censusId,
        'room': room,
        'deviceSerial': deviceSerial,
      },
    );
    return PatientDetailResponse.fromJson(body);
  }

  Future<NotificationsPauseResponse> pauseNotifications(
    String patientId, {
    required int days,
    required String reason,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/patients/$patientId/notifications/pause',
      body: {'days': days, 'reason': reason},
    );
    return NotificationsPauseResponse.fromJson(body);
  }

  Future<NotificationsPauseResponse> resumeNotifications(
    String patientId,
  ) async {
    final body = await _request(
      'DELETE',
      '/api/v1/patients/$patientId/notifications/pause',
    );
    return NotificationsPauseResponse.fromJson(body);
  }

  Future<CareNoteResponse> updateCareNote(
    String patientId,
    String text,
  ) async {
    final body = await _request(
      'PATCH',
      '/api/v1/patients/$patientId/care-note',
      body: {'text': text},
    );
    return CareNoteResponse.fromJson(body);
  }

  // ── D2C claim + public lookup (d2c-phase1 §3.3 / §3.4) ─────────

  /// `GET /api/v1/public/walkers/{walkerId}` — UNAUTHENTICATED landing
  /// lookup for the scanned QR / `/setup/{walkerId}` link. Never attaches
  /// a token (the endpoint sits outside both authorizers). Returns the
  /// claimable state; an unknown id reads as [PublicWalkerStatus.unknown]
  /// (no existence leak per d2c.md L6).
  Future<PublicWalkerLookup> publicWalkerLookup(String walkerId) async {
    final body = await _request(
      'GET',
      '/api/v1/public/walkers/${Uri.encodeComponent(walkerId)}',
      authenticated: false,
    );
    return PublicWalkerLookup.fromJson(body);
  }

  /// `POST /api/v1/claim` — bootstrap the household + patient +
  /// role-assignment then provision the device (d2c-phase1 §3.3).
  /// Authenticated with the just-signed-up walker user's D2C JWT.
  /// Idempotent: re-claiming a device this user already owns returns
  /// 200 with `alreadyClaimed: true`.
  Future<ClaimResponse> claimDevice(
    String walkerId, {
    String? displayName,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/claim',
      body: {
        'walkerId': walkerId,
        if (displayName != null && displayName.isNotEmpty)
          'displayName': displayName,
      },
    );
    return ClaimResponse.fromJson(body);
  }

  // ── Internals ─────────────────────────────────────────────────

  /// GET with JWT attachment, envelope decoding, and retry on 5xx.
  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    return _request('GET', path, query: query);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    // D2C public lookup (d2c-phase1 §3.4) sits outside both authorizers
    // and must NOT carry a token. Defaults to true so every existing
    // facility + authenticated call is unchanged.
    bool authenticated = true,
  }) async {
    var uri = Uri.parse('$_baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (authenticated) {
      final token = await _auth.getIdToken();
      if (token == null) {
        throw ApiException.unauthenticated();
      }
      headers['Authorization'] = 'Bearer $token';
    }

    http.Response resp;
    try {
      switch (method) {
        case 'GET':
          resp = await _http.get(uri, headers: headers);
          break;
        case 'POST':
          resp = await _http.post(uri, headers: headers, body: jsonEncode(body));
          break;
        case 'PATCH':
          resp = await _http.patch(uri, headers: headers, body: jsonEncode(body));
          break;
        case 'DELETE':
          resp = await _http.delete(uri, headers: headers);
          break;
        default:
          throw StateError('Unsupported method: $method');
      }
    } on TimeoutException catch (e) {
      throw ApiException.network(detail: 'Timeout: ${e.duration}');
    } catch (e) {
      // Preserve underlying type/message so CORS / preflight / browser-
      // side sync errors aren't indistinguishable from real network
      // outages. Per coord §C34.3 lesson #1.
      throw ApiException.network(detail: '${e.runtimeType}: $e');
    }

    final status = resp.statusCode;
    if (status >= 200 && status < 300) {
      if (resp.body.isEmpty) return const {};
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }

    // Error envelope per 2A-0 L7: {error: {code, message, details}}
    Map<String, dynamic>? envelope;
    try {
      envelope = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      envelope = null;
    }
    final err = envelope?['error'] as Map<String, dynamic>?;
    throw ApiException(
      code: (err?['code'] as String?) ?? 'INTERNAL_ERROR',
      message: (err?['message'] as String?) ??
          'Request failed (${resp.statusCode}). Please retry.',
      httpStatus: status,
      details: err?['details'] as Map<String, dynamic>?,
    );
  }
}
