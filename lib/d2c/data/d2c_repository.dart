import '../../api/d2c_api_models.dart';
import 'd2c_mock_data.dart';

/// Data gateway for the D2C consumer portal. The screens in `lib/d2c/`
/// depend only on this abstraction so the demo build (mock) and the live
/// build (API-backed) share one widget tree — mirrors the facility
/// `FacilityRepository` split.
///
/// Phase 1 covers the **monitoring loop only**: QR landing → claim →
/// dashboard + history. Care Circle (Phase 5), notification prefs
/// (Phase 2), and the customer audit log have no Phase-1 backend, so
/// those screens stay on [D2CMockData] directly (or are hidden in the
/// live build) until their endpoints ship. See d2c.md §4/§5.
abstract class D2CRepository {
  /// `GET /public/walkers/{walkerId}` — unauthenticated QR-landing lookup.
  Future<PublicWalkerLookup> lookupWalker(String walkerId);

  // ── QR re-login (d2c-qr-relogin) — get back into a claimed device ──

  /// Masked login targets for a claimed device's QR (registered user +
  /// Care Circle members). No raw phones.
  Future<List<WalkerRecipient>> walkerLoginRecipients(String walkerId);

  /// Text a login code to a masked recipient; returns an opaque session.
  Future<LoginCodeChallenge> sendWalkerLoginCode(
      String walkerId, String recipientId);

  /// Verify the code; `ok` carries the tokens to adopt a session.
  Future<LoginCodeVerifyResult> verifyWalkerLoginCode(
      String walkerId, String recipientId, String session, String code);

  /// `POST /claim` — bootstrap household + patient then provision the
  /// device. Authenticated with the just-signed-up walker user's JWT.
  Future<ClaimResponse> claim(String walkerId, {String? displayName});

  /// The patientId of this household's walker, or null if nothing is
  /// claimed yet. V1: one household = one patient (`/me/patients` → first).
  Future<String?> myWalkerPatientId();

  /// The bundled dashboard snapshot for [patientId] (detail + today's +
  /// 7-day activity + open alerts), shaped for [D2CDashboardScreen].
  Future<D2CDashboardSnapshot> dashboard(String patientId);

  /// Daily history for the 30/90-day History view.
  Future<List<HistoryDay>> history(String patientId, {required int days});

  // ── Care Circle (d2c-care-circle.md §5.9) ──────────────────────

  /// The household roster + pending invites + viewer standing.
  Future<CareCircleData> careCircle();

  /// Admin sends a phone-first SMS invite; returns the created pending
  /// invite for optimistic list insertion.
  Future<PendingInvite> sendInvite({
    required String name,
    required String phone,
    String relationship = '',
    bool asAdmin = false,
    bool isWalkerUser = false,
  });

  /// Admin re-sends the invite SMS (re-arms the 14-day expiry).
  Future<void> resendInvite(String inviteId);

  /// Admin revokes a pending invite.
  Future<void> revokeInvite(String inviteId);

  /// Admin promotes/demotes a member. The server enforces the
  /// last-Admin guard.
  Future<void> setMemberAdmin(String userId, {required bool admin});

  /// Admin removes a member — or a member removes THEMSELVES (leave).
  /// Access ends on the member's next API call.
  Future<void> removeMember(String userId);

  /// Live invites addressed to the signed-in caller's verified phone
  /// (the organic path: got the text, signed up without tapping the link).
  Future<List<JoinableInvite>> pendingInvitesForMe();

  /// Accept an invite (server matches the caller's VERIFIED phone).
  /// The live implementation refreshes the token afterwards so
  /// `custom:clientId`/`custom:role` reflect the joined household.
  Future<AcceptInviteResult> acceptInvite(String inviteId);

  /// Acknowledge an open alert ("I called Mom") — 2A-AA first-write-wins,
  /// permitted for members per d2c-care-circle.md D3.
  Future<void> ackAlert(String patientId, String alertId, {String? notes});
}

/// Mock repository for the demo build — delegates to the static
/// [D2CMockData] wireframe seeds. Ignores [patientId] (one mock household).
class D2CMockRepository implements D2CRepository {
  const D2CMockRepository();

  @override
  Future<PublicWalkerLookup> lookupWalker(String walkerId) async =>
      const PublicWalkerLookup(status: PublicWalkerStatus.unclaimed);

  @override
  Future<List<WalkerRecipient>> walkerLoginRecipients(String walkerId) async =>
      const [
        WalkerRecipient(
            recipientId: 'mock_primary',
            mask: '•••-4566',
            label: 'Registered user',
            isPrimary: true),
        WalkerRecipient(
            recipientId: 'mock_member',
            mask: '•••-1234',
            label: 'Daughter',
            isPrimary: false),
      ];

  @override
  Future<LoginCodeChallenge> sendWalkerLoginCode(
          String walkerId, String recipientId) async =>
      const LoginCodeChallenge(session: 'mock-session', mask: '•••-4566');

  @override
  Future<LoginCodeVerifyResult> verifyWalkerLoginCode(String walkerId,
          String recipientId, String session, String code) async =>
      const LoginCodeVerifyResult(status: 'ok', phone: '+15125550100');

  @override
  Future<ClaimResponse> claim(String walkerId, {String? displayName}) async =>
      ClaimResponse(
        patient: ClaimedPatient(
          patientId: 'pat_d2c_susan',
          displayName: displayName ?? 'Susan Davis',
          status: 'active',
          clientId: 'dtc_mock',
          isWalkerUser: true,
        ),
        alreadyClaimed: false,
      );

  @override
  Future<String?> myWalkerPatientId() async => 'pat_d2c_susan';

  @override
  Future<D2CDashboardSnapshot> dashboard(String patientId) async =>
      D2CMockData.susanViewedBySarah();

  @override
  Future<List<HistoryDay>> history(
    String patientId, {
    required int days,
  }) async =>
      D2CMockData.history(days: days);

  // ── Care Circle (in-memory mock state so demo mutations stick) ──

  static List<CareCircleMember>? _members;
  static List<PendingInvite>? _invites;
  static List<AccessRequest>? _requests;

  static void _seed() {
    _members ??= List.of(D2CMockData.careCircle());
    _invites ??= List.of(D2CMockData.pendingInvites());
    _requests ??= List.of(D2CMockData.accessRequests());
  }

  @override
  Future<CareCircleData> careCircle() async {
    _seed();
    return CareCircleData(
      members: List.unmodifiable(_members!),
      invites: List.unmodifiable(_invites!),
      requests: List.unmodifiable(_requests!),
      walkerName: 'Susan',
      viewerIsAdmin: true,
      viewerUserId: 'user_sarah',
    );
  }

  @override
  Future<PendingInvite> sendInvite({
    required String name,
    required String phone,
    String relationship = '',
    bool asAdmin = false,
    bool isWalkerUser = false,
  }) async {
    _seed();
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    final tail = digits.length >= 4 ? digits.substring(digits.length - 4) : digits;
    final invite = PendingInvite(
      id: 'inv_mock_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      email: '',
      contactMask: '•••-$tail',
      relationship: relationship,
      invitedByName: 'Sarah',
      sentAt: DateTime.now(),
      asAdmin: asAdmin,
      expiresInDays: 14,
    );
    _invites!.add(invite);
    return invite;
  }

  @override
  Future<void> resendInvite(String inviteId) async {}

  @override
  Future<void> revokeInvite(String inviteId) async {
    _seed();
    _invites!.removeWhere((i) => i.id == inviteId);
  }

  @override
  Future<void> setMemberAdmin(String userId, {required bool admin}) async {
    _seed();
    final idx = _members!.indexWhere((m) => m.userId == userId);
    if (idx < 0) return;
    final m = _members![idx];
    _members![idx] = CareCircleMember(
      userId: m.userId,
      displayName: m.displayName,
      relationship: m.relationship,
      email: m.email,
      phoneE164: m.phoneE164,
      contactMask: m.contactMask,
      isAdmin: admin,
      isWalkerUser: m.isWalkerUser,
      isViewer: m.isViewer,
      lastActiveAt: m.lastActiveAt,
    );
  }

  @override
  Future<void> removeMember(String userId) async {
    _seed();
    _members!.removeWhere((m) => m.userId == userId);
  }

  @override
  Future<List<JoinableInvite>> pendingInvitesForMe() async => const [];

  @override
  Future<AcceptInviteResult> acceptInvite(String inviteId) async =>
      const AcceptInviteResult(
        clientId: 'dtc_mock',
        householdName: "Susan's household",
        walkerName: 'Susan',
        role: 'family_viewer',
        isWalkerUser: false,
        alreadyMember: false,
      );

  @override
  Future<void> ackAlert(String patientId, String alertId, {String? notes}) async {}
}
