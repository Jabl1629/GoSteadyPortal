import '../models/user.dart';

/// Parses Cognito ID-token payload claims into a [GoSteadyUser].
///
/// Pre-Token Lambda V2 (Phase 0A-rev) injects:
///   - `sub`                  → Cognito user ID
///   - `email`                → email
///   - `name`                 → display name
///   - `custom:clientId`      → tenant boundary
///   - `custom:role`          → role enum value (snake_case in claim)
///   - `custom:facilities`    → comma-separated facility IDs
///   - `custom:censuses`      → comma-separated census IDs
///   - `custom:mfa_enrolled`  → "true" / "false"
///
/// Per phase-2b-0-foundation.md §Interfaces > GoSteadyUser.
class UserClaims {
  /// Build a [GoSteadyUser] from decoded JWT payload.
  static GoSteadyUser parse(Map<String, dynamic> payload) {
    return GoSteadyUser(
      userId: (payload['sub'] as String?) ?? '',
      email: (payload['email'] as String?) ?? '',
      displayName:
          (payload['name'] as String?) ?? (payload['email'] as String?) ?? '',
      role: UserRole.fromString(payload['custom:role'] as String?),
      clientId: payload['custom:clientId'] as String?,
      facilities: _splitCsv(payload['custom:facilities']),
      censuses: _splitCsv(payload['custom:censuses']),
      mfaEnrolled: _parseBool(payload['custom:mfa_enrolled']),
    );
  }

  static List<String> _splitCsv(dynamic value) {
    if (value == null) return const [];
    final s = value.toString().trim();
    if (s.isEmpty) return const [];
    return s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static bool _parseBool(dynamic value) {
    if (value == null) return false;
    final s = value.toString().toLowerCase();
    return s == 'true' || s == '1';
  }
}
