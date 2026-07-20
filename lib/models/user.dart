/// Authenticated GoSteady user — full claim set from Phase 0A-rev
/// Pre-Token Lambda V2.
///
/// V1 UI collapses all customer roles to a single Care Staff role per
/// `phase-2b-portal-integration.md` L13; the data model carries the
/// full set so V2 role-gating is a UI-only change.
class GoSteadyUser {
  final String userId; // Cognito sub
  final String email;
  final String displayName;
  final UserRole role;

  /// `custom:clientId` claim. Null only for the demo's MockAuthService
  /// session (no real tenant) — every real Cognito user has one.
  final String? clientId;

  /// `custom:facilities` claim, split on comma. Empty list for
  /// `client_admin` (scope = all facilities) or for non-facility roles.
  final List<String> facilities;

  /// `custom:censuses` claim, split on comma. Empty list for
  /// `facility_admin` (scope = all censuses in scoped facilities).
  final List<String> censuses;

  /// `custom:mfa_enrolled` claim. Pre-Token Lambda enforces MFA for
  /// `facility_admin+` and all `internal_*` roles.
  final bool mfaEnrolled;

  /// `custom:isWalkerUser` claim (D2C pool only). True when THIS account is
  /// the walker/device user themselves — a solo `household_owner`, or a Care
  /// Circle member linked as the walker — vs a caregiver watching someone
  /// else. Drives walker-facing copy and the walker-only alert suppression
  /// (activity-judgment alerts are hidden from the walker's own view).
  /// Absent for facility / internal tokens and the mock/demo session → false.
  final bool isWalkerUser;

  const GoSteadyUser({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.role,
    this.clientId,
    this.facilities = const [],
    this.censuses = const [],
    this.mfaEnrolled = false,
    this.isWalkerUser = false,
  });

  /// Back-compat alias used by legacy screens (e.g. dashboard_screen.dart).
  String get name => displayName;

  /// Two-letter initials derived from [displayName] for avatar chips.
  /// Falls back to '?' if displayName is empty.
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  // ── Role helpers (V1 — all customer roles collapse to "Care Staff") ──

  /// True for any role that has read access to walker data — covers
  /// caregiver / facility_admin / client_admin / household_owner /
  /// family_viewer (per phase-0a-revision.md).
  ///
  /// Legacy callers that previously checked `isCaregiver` use this in
  /// the V1 single-role UI.
  bool get isCaregiver =>
      role == UserRole.caregiver ||
      role == UserRole.facilityAdmin ||
      role == UserRole.clientAdmin ||
      role == UserRole.householdOwner ||
      role == UserRole.familyViewer;

  /// True for the legacy "walker" role (D2C single-walker user) —
  /// retained for back-compat with the legacy D2C dashboard. V1's
  /// [UserRole.patient] is the modern equivalent.
  bool get isWalker => role == UserRole.walker || role == UserRole.patient;

  /// True for `internal_support` or `internal_admin` — internal GoSteady
  /// staff, signed in via the reserved `_internal` client.
  bool get isInternal =>
      role == UserRole.internalAdmin || role == UserRole.internalSupport;
}

/// Full role enum from Phase 0A-rev — 6 customer roles + 2 internal +
/// 1 legacy (`walker` is deprecated cruft; Cognito can't delete groups,
/// so the value stays but no V1 UI surfaces it).
enum UserRole {
  // ── Customer tier ─────────────────────────────────────────────
  patient,
  familyViewer,
  householdOwner,
  caregiver,
  facilityAdmin,
  clientAdmin,

  // ── Internal tier ─────────────────────────────────────────────
  internalSupport,
  internalAdmin,

  // ── Legacy (deprecated; retained for Cognito group back-compat) ──
  walker;

  /// Parse from the `custom:role` JWT claim. Falls back to `caregiver`
  /// on unknown values rather than rejecting the user — defensive
  /// posture for the V1 single-role UI per phase-2b L13.
  static UserRole fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'patient':
        return UserRole.patient;
      case 'family_viewer':
        return UserRole.familyViewer;
      case 'household_owner':
        return UserRole.householdOwner;
      case 'caregiver':
        return UserRole.caregiver;
      case 'facility_admin':
        return UserRole.facilityAdmin;
      case 'client_admin':
        return UserRole.clientAdmin;
      case 'internal_support':
        return UserRole.internalSupport;
      case 'internal_admin':
        return UserRole.internalAdmin;
      case 'walker':
        return UserRole.walker;
      default:
        return UserRole.caregiver;
    }
  }

  /// Display label for the role badge in the top bar.
  String get label {
    switch (this) {
      case UserRole.patient:
        return 'Patient';
      case UserRole.familyViewer:
        return 'Family';
      case UserRole.householdOwner:
        return 'Household';
      case UserRole.caregiver:
      case UserRole.facilityAdmin:
      case UserRole.clientAdmin:
        return 'Care Staff'; // V1 collapse per phase-2b L13
      case UserRole.internalSupport:
        return 'Internal · Support';
      case UserRole.internalAdmin:
        return 'Internal · Admin';
      case UserRole.walker:
        return 'Walker';
    }
  }

  /// Whether this role requires MFA per Pre-Token Lambda enforcement
  /// (Phase 0A-rev D5).
  bool get requiresMfa {
    switch (this) {
      case UserRole.facilityAdmin:
      case UserRole.clientAdmin:
      case UserRole.internalSupport:
      case UserRole.internalAdmin:
        return true;
      case UserRole.patient:
      case UserRole.familyViewer:
      case UserRole.householdOwner:
      case UserRole.caregiver:
      case UserRole.walker:
        return false;
    }
  }
}
