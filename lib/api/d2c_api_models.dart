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
