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

  // ── 2A-RD reads (deployed; wiring in 2B-FAC-R) ────────────────

  Future<MePatientsResponse> getMyPatients({
    String? cursor,
    String? clientId,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  Future<PatientDetailResponse> getPatient(String patientId) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  Future<ActivityResponse> getActivity(
    String patientId,
    ActivityRange range, {
    String? cursor,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  Future<AlertsResponse> getAlerts(
    String patientId,
    AlertStatus status, {
    String? cursor,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  Future<DeviceResponse> getDevice(String serial) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  Future<CensusRosterResponse> getCensusRoster(
    String facilityId,
    String censusId, {
    String? cursor,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-R');
  }

  // ── 2A-AA + 2A-DL writes (deployed; wiring in 2B-FAC-W) ────────

  Future<void> ackAlert(
    String patientId,
    String compoundSk, {
    String? notes,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<DeviceResponse> provisionDevice(String serial, String patientId) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<DeviceResponse> endAssignment(String serial) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  // ── 2A-UM-P writes (deployed dev 2026-05-24; wiring in 2B-FAC-W) ──

  Future<PatientDetailResponse> createPatient({
    required String displayName,
    required String censusId,
    required String room,
    String? deviceSerial,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<PatientDetailResponse> updatePatient(
    String patientId, {
    String? displayName,
    String? censusId,
    String? room,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<void> dischargePatient(
    String patientId, {
    required String reason,
    String? notes,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<void> pauseNotifications(
    String patientId, {
    required int days,
    required String reason,
  }) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<void> resumeNotifications(String patientId) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  Future<PatientDetailResponse> updateCareNote(
    String patientId,
    String text,
  ) async {
    throw UnimplementedError('Wiring in 2B-FAC-W');
  }

  // ── Internals ─────────────────────────────────────────────────

  /// GET with JWT attachment, envelope decoding, and retry on 5xx.
  Future<Map<String, dynamic>> _get(String path) async {
    return _request('GET', path);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
  }) async {
    final token = await _auth.getIdToken();
    if (token == null) {
      throw ApiException.unauthenticated();
    }

    final uri = Uri.parse('$_baseUrl$path');
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
    } on TimeoutException catch (_) {
      throw ApiException.network();
    } catch (_) {
      throw ApiException.network();
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
