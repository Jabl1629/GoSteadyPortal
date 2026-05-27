/// Typed exception decoded from a non-2xx response per the Phase 2A-0
/// error envelope: `{error: {code, message, details}}`.
///
/// Network failures (no envelope; raw timeout / DNS / 0-byte response)
/// surface as `ApiException(code: 'NETWORK', httpStatus: 0)`.
///
/// Per phase-2b-0-foundation.md L7.
class ApiException implements Exception {
  /// Stable error code — e.g. `TENANCY_VIOLATION`, `INVALID_REQUEST`,
  /// `MFA_REQUIRED`, `NETWORK`, `INTERNAL_ERROR`. Catalog lives in
  /// `phase-2a-foundation.md` §Scope > Error code catalog.
  final String code;

  /// User-facing message safe to render in a SnackBar.
  final String message;

  /// Optional structured payload (validation failures often surface
  /// per-field error lists here).
  final Map<String, dynamic>? details;

  /// HTTP status code; `0` for network failures (no response was received).
  final int httpStatus;

  const ApiException({
    required this.code,
    required this.message,
    required this.httpStatus,
    this.details,
  });

  /// Network-class failure (no HTTP response received). Optional
  /// [detail] preserves the underlying error string so CORS / preflight
  /// / sync exceptions don't all collapse to "Connection lost" in the
  /// UI — surfaces as `details: {inner: <detail>}` and is included in
  /// [toString] for log diagnosis. Per coord §C34.3 lesson #1.
  factory ApiException.network({String? detail}) => ApiException(
        code: 'NETWORK',
        message: 'Connection lost. Retry?',
        httpStatus: 0,
        details: detail == null ? null : {'inner': detail},
      );

  factory ApiException.unauthenticated() => const ApiException(
        code: 'UNAUTHENTICATED',
        message: 'Your session has expired. Please sign in again.',
        httpStatus: 401,
      );

  @override
  String toString() {
    final inner = details?['inner'];
    final suffix = inner == null ? '' : ' [inner: $inner]';
    return 'ApiException($code, $httpStatus): $message$suffix';
  }
}
