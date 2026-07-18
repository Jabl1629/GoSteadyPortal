/// Response shapes for the D2C-specific endpoints: the unauthenticated
/// QR-landing lookup and the authenticated claim/bootstrap.
///
/// Per d2c-phase1-walker-activation.md §3.3 (`POST /api/v1/claim`) and
/// §3.4 (`GET /api/v1/public/walkers/{walkerId}`). Kept separate from the
/// shared `api_models.dart` so the consumer surface stays isolated from
/// the facility tier — mirrors the backend's deliberate D2C isolation
/// (d2c-phase1 §9, "keep D2C isolated from the deployed handlers").
///
/// Decoders are forgiving (`?? <default>`) — the server is the source of
/// truth on optionality. Field names match the live JSON contracts.
library;

// ── GET /api/v1/public/walkers/{walkerId} (unauthenticated) ────────

/// Landing state for a scanned QR / `/setup/{walkerId}` link. `unknown`
/// is the server's neutral response for a non-existent id — it does NOT
/// leak existence (d2c.md L6), so the UI treats it the same as a dead link.
enum PublicWalkerStatus {
  unclaimed('unclaimed'),

  /// Unowned but claim-bound to a specific recipient's phone
  /// (d2c-claim-binding.md §5.5). Claimable — but only that phone's
  /// verified account will pass the claim check.
  reserved('reserved'),
  claimed('claimed'),
  decommissioned('decommissioned'),
  unknown('unknown');

  final String wireValue;
  const PublicWalkerStatus(this.wireValue);

  static PublicWalkerStatus fromWire(Object? raw) {
    final s = raw?.toString() ?? 'unknown';
    return PublicWalkerStatus.values.firstWhere(
      (v) => v.wireValue == s,
      // Forward-compatible: an unrecognized status reads as `unknown`
      // rather than throwing on the public (unauthenticated) path.
      orElse: () => PublicWalkerStatus.unknown,
    );
  }
}

class PublicWalkerLookup {
  final PublicWalkerStatus status;

  /// Masked owner email (e.g. `"m•••@example.com"`), present only when
  /// [status] is [PublicWalkerStatus.claimed]. Drives the pre-claim race
  /// copy on the "already registered" landing (d2c-phase1 §3.4).
  final String? ownerMasked;

  /// Device type (`walker_cap` | `rollator_platform`) — drives device-
  /// appropriate /setup landing copy (DT-4). Null → walker_cap (D9).
  final String? deviceType;

  /// Masked intended-recipient phone (e.g. `"•••-1234"`), present only when
  /// [status] is [PublicWalkerStatus.reserved]. Drives the "Set up this
  /// walker for {mask}?" confirmation (claim-binding §5.5).
  final String? recipientMask;

  const PublicWalkerLookup({
    required this.status,
    this.ownerMasked,
    this.deviceType,
    this.recipientMask,
  });

  bool get isClaimable =>
      status == PublicWalkerStatus.unclaimed ||
      status == PublicWalkerStatus.reserved;

  factory PublicWalkerLookup.fromJson(Map<String, dynamic> json) {
    return PublicWalkerLookup(
      status: PublicWalkerStatus.fromWire(json['status']),
      ownerMasked: json['ownerMasked'] as String?,
      deviceType: json['deviceType'] as String?,
      recipientMask: json['recipientMask'] as String?,
    );
  }
}

// ── POST /api/v1/claim (authenticated, D2C JWT) ───────────────────

/// Result of claiming a device. 201 on first claim, 200 when the
/// caller already owns it ([alreadyClaimed] true — idempotent re-call).
class ClaimResponse {
  final ClaimedPatient patient;

  /// True when this user already owned the device (idempotent 200).
  /// False on a fresh 201 claim.
  final bool alreadyClaimed;

  const ClaimResponse({required this.patient, required this.alreadyClaimed});

  factory ClaimResponse.fromJson(Map<String, dynamic> json) {
    return ClaimResponse(
      patient: ClaimedPatient.fromJson(
        (json['patient'] as Map<String, dynamic>?) ?? const {},
      ),
      alreadyClaimed: (json['alreadyClaimed'] as bool?) ?? false,
    );
  }
}

// ── Care Circle (d2c-care-circle.md §5.2) ──────────────────────────

/// `GET /api/v1/household/members` — the roster. `pendingInvites` is
/// present only for Admin callers (the server omits it for plain members).
class CareCircleRoster {
  final List<RosterMember> members;
  final List<RosterInvite> pendingInvites;

  const CareCircleRoster({required this.members, required this.pendingInvites});

  factory CareCircleRoster.fromJson(Map<String, dynamic> json) {
    final rawMembers = (json['members'] as List<dynamic>?) ?? const [];
    final rawInvites = (json['pendingInvites'] as List<dynamic>?) ?? const [];
    return CareCircleRoster(
      members: rawMembers
          .map((e) => RosterMember.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      pendingInvites: rawInvites
          .map((e) => RosterInvite.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// One confirmed member row. `userId` is null for the synthesized
/// account-less walker entry (D10). Raw phone never crosses the API —
/// only `contactMask` (•••-1234).
class RosterMember {
  final String? userId;
  final String displayName;
  final String relationship;
  final String? role; // household_owner | family_viewer | null (walker entry)
  final bool isWalkerUser;
  final String contactMask;
  final String? joinedAt;
  final bool isViewer; // true for the signed-in caller's own row

  const RosterMember({
    required this.userId,
    required this.displayName,
    required this.relationship,
    required this.role,
    required this.isWalkerUser,
    required this.contactMask,
    required this.joinedAt,
    required this.isViewer,
  });

  factory RosterMember.fromJson(Map<String, dynamic> json) => RosterMember(
        userId: json['userId'] as String?,
        displayName: (json['displayName'] as String?) ?? '',
        relationship: (json['relationship'] as String?) ?? '',
        role: json['role'] as String?,
        isWalkerUser: (json['isWalkerUser'] as bool?) ?? false,
        contactMask: (json['contactMask'] as String?) ?? '',
        joinedAt: json['joinedAt'] as String?,
        isViewer: (json['isViewer'] as bool?) ?? false,
      );
}

/// One pending invite in the Admin roster view (and the send response).
class RosterInvite {
  final String inviteId;
  final String displayName;
  final String relationship;
  final String contactMask;
  final String role;
  final bool isWalkerUser;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const RosterInvite({
    required this.inviteId,
    required this.displayName,
    required this.relationship,
    required this.contactMask,
    required this.role,
    required this.isWalkerUser,
    required this.createdAt,
    required this.expiresAt,
  });

  factory RosterInvite.fromJson(Map<String, dynamic> json) => RosterInvite(
        inviteId: (json['inviteId'] as String?) ?? '',
        displayName: (json['displayName'] as String?) ?? '',
        relationship: (json['relationship'] as String?) ?? '',
        contactMask: (json['contactMask'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'family_viewer',
        isWalkerUser: (json['isWalkerUser'] as bool?) ?? false,
        createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? ''),
        expiresAt: DateTime.tryParse((json['expiresAt'] as String?) ?? ''),
      );
}

/// `GET /api/v1/invites/pending` — a live invite addressed to the CALLER's
/// verified phone, described from the invitee's side (which household
/// they'd be joining).
class JoinableInvite {
  final String inviteId;
  final String householdName;
  final String walkerName;
  final String inviterName;
  final String role;
  final bool isWalkerUser;
  final DateTime? expiresAt;

  const JoinableInvite({
    required this.inviteId,
    required this.householdName,
    required this.walkerName,
    required this.inviterName,
    required this.role,
    required this.isWalkerUser,
    required this.expiresAt,
  });

  factory JoinableInvite.fromJson(Map<String, dynamic> json) => JoinableInvite(
        inviteId: (json['inviteId'] as String?) ?? '',
        householdName: (json['householdName'] as String?) ?? '',
        walkerName: (json['walkerName'] as String?) ?? '',
        inviterName: (json['inviterName'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'family_viewer',
        isWalkerUser: (json['isWalkerUser'] as bool?) ?? false,
        expiresAt: DateTime.tryParse((json['expiresAt'] as String?) ?? ''),
      );
}

/// `POST /api/v1/invites/accept` result. After a fresh join the caller
/// must `refreshClaims()` so the next token carries the household —
/// `LiveD2CRepository.acceptInvite` does this automatically.
class AcceptInviteResult {
  final String clientId;
  final String householdName;
  final String walkerName;
  final String role;
  final bool isWalkerUser;
  final bool alreadyMember;

  const AcceptInviteResult({
    required this.clientId,
    required this.householdName,
    required this.walkerName,
    required this.role,
    required this.isWalkerUser,
    required this.alreadyMember,
  });

  factory AcceptInviteResult.fromJson(Map<String, dynamic> json) {
    final h = (json['household'] as Map<String, dynamic>?) ?? const {};
    return AcceptInviteResult(
      clientId: (h['clientId'] as String?) ?? '',
      householdName: (h['householdName'] as String?) ?? '',
      walkerName: (h['walkerName'] as String?) ?? '',
      role: (h['role'] as String?) ?? 'family_viewer',
      isWalkerUser: (h['isWalkerUser'] as bool?) ?? false,
      alreadyMember: (json['alreadyMember'] as bool?) ?? false,
    );
  }
}

/// The patient row created (or returned) by the claim. A subset of the
/// 2A-RD `PatientFull` shape, plus the D2C-only `isWalkerUser` flag. The
/// portal uses `patientId` to immediately fetch the full detail + render
/// the pre-activation dashboard.
class ClaimedPatient {
  final String patientId;
  final String displayName;
  final String status;
  final String? clientId;
  final String? facilityId;
  final String? censusId;
  final bool isWalkerUser;

  const ClaimedPatient({
    required this.patientId,
    required this.displayName,
    required this.status,
    this.clientId,
    this.facilityId,
    this.censusId,
    required this.isWalkerUser,
  });

  factory ClaimedPatient.fromJson(Map<String, dynamic> json) {
    return ClaimedPatient(
      patientId: (json['patientId'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'active',
      clientId: json['clientId'] as String?,
      facilityId: json['facilityId'] as String?,
      censusId: json['censusId'] as String?,
      isWalkerUser: (json['isWalkerUser'] as bool?) ?? false,
    );
  }
}

// ── QR re-login (d2c-qr-relogin) ───────────────────────────────────

/// One masked login target for a claimed device's QR re-login flow. No raw
/// phone or Cognito sub — `recipientId` is an opaque, walker-scoped handle
/// the client passes back to send/verify.
class WalkerRecipient {
  final String recipientId;
  final String mask; // •••-4566
  final String label; // "Registered user" | relationship | "Care Circle member"
  final bool isPrimary; // the "That's me" target

  const WalkerRecipient({
    required this.recipientId,
    required this.mask,
    required this.label,
    required this.isPrimary,
  });

  factory WalkerRecipient.fromJson(Map<String, dynamic> json) => WalkerRecipient(
        recipientId: (json['recipientId'] as String?) ?? '',
        mask: (json['mask'] as String?) ?? '',
        label: (json['label'] as String?) ?? '',
        isPrimary: (json['isPrimary'] as bool?) ?? false,
      );
}

/// Result of `POST .../login-code` — an opaque Cognito session + the masked
/// destination. The full phone is never returned here.
class LoginCodeChallenge {
  final String session;
  final String mask;
  const LoginCodeChallenge({required this.session, required this.mask});

  factory LoginCodeChallenge.fromJson(Map<String, dynamic> json) =>
      LoginCodeChallenge(
        session: (json['session'] as String?) ?? '',
        mask: (json['mask'] as String?) ?? '',
      );
}

/// Result of `POST .../login-code/verify`. `ok` → tokens + phone (the caller
/// proved possession) to adopt a signed-in session; `retry` → a fresh session
/// to try the code again.
class LoginCodeVerifyResult {
  final String status; // "ok" | "retry"
  final String idToken;
  final String accessToken;
  final String refreshToken;
  final String phone;
  final String session; // present on retry

  const LoginCodeVerifyResult({
    required this.status,
    this.idToken = '',
    this.accessToken = '',
    this.refreshToken = '',
    this.phone = '',
    this.session = '',
  });

  bool get isOk => status == 'ok';

  factory LoginCodeVerifyResult.fromJson(Map<String, dynamic> json) =>
      LoginCodeVerifyResult(
        status: (json['status'] as String?) ?? '',
        idToken: (json['idToken'] as String?) ?? '',
        accessToken: (json['accessToken'] as String?) ?? '',
        refreshToken: (json['refreshToken'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        session: (json['session'] as String?) ?? '',
      );
}
