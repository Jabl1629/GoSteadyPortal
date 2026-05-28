import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service_interface.dart';
import 'api_exception.dart';
import 'api_models.dart';

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

  ApiClient({
    required AuthServiceInterface auth,
    required String baseUrl,
    http.Client? httpClient,
  })  : _auth = auth,
        // Strip trailing slash to make path concatenation predictable.
        _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
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
  }) async {
    final query = <String, String>{};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    if (clientId != null && clientId.isNotEmpty) query['clientId'] = clientId;
    final body = await _get('/api/v1/me/patients', query: query);
    return MePatientsResponse.fromJson(body);
  }

  Future<PatientDetailResponse> getPatient(String patientId) async {
    final body = await _get('/api/v1/patients/$patientId');
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
        await _get('/api/v1/patients/$patientId/activity', query: query);
    return ActivityResponse.fromJson(body);
  }

  Future<AlertsResponse> getAlerts(
    String patientId,
    AlertStatus status, {
    String? cursor,
  }) async {
    final query = <String, String>{'status': status.wireValue};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final body = await _get('/api/v1/patients/$patientId/alerts', query: query);
    return AlertsResponse.fromJson(body);
  }

  Future<DeviceResponse> getDevice(String serial) async {
    // NOTE: 2A-RD spec doesn't ship /devices/{serial}; per
    // phase-2b-fac-r Q5 we surface this stub for follow-on. V1 patient-
    // detail card uses /patients/{id}.currentDevice fields.
    throw UnimplementedError(
      'GET /devices/{serial} not in 2A-RD; see phase-2b-fac-r Q5',
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
    required String reason,
    String? notes,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/patients/$patientId/discharge',
      body: {
        'reason': reason,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return DischargeResponse.fromJson(body);
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
  }) async {
    final token = await _auth.getIdToken();
    if (token == null) {
      throw ApiException.unauthenticated();
    }

    var uri = Uri.parse('$_baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

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
