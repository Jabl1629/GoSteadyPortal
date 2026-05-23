import 'package:flutter/foundation.dart';

/// Demo-only signed-in user. Lightweight; mirrors the fields we actually
/// render in the facility shell. Phase 2B's real `GoSteadyUser` will carry
/// JWT claims (`clientId`, `role`, `facilities`, `censuses`) per
/// ARCHITECTURE.md §4 — those slots are noted here so the swap is mechanical.
class FacilityUser {
  final String displayName;
  final String title;
  final String clientId; // matches the architecture's tenancy boundary
  final String role; // "facility_admin" — demo only ever uses this

  const FacilityUser({
    required this.displayName,
    required this.title,
    required this.clientId,
    required this.role,
  });

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

/// Mock authentication for the demo build. Public surface mirrors the real
/// `AuthService` (`init()` / `signIn()` / `signOut()` / `currentUser` /
/// `isSignedIn` + `ChangeNotifier`) so screens written against it port to
/// real Cognito with a constructor change.
class FacilityMockAuthService extends ChangeNotifier {
  FacilityMockAuthService._();
  static final FacilityMockAuthService instance = FacilityMockAuthService._();

  FacilityUser? _user;

  FacilityUser? get currentUser => _user;
  bool get isSignedIn => _user != null;

  /// Match the real `AuthService.init()` signature. Demo always starts
  /// logged out — we want investors to see the login screen, not a
  /// pre-authenticated dashboard.
  Future<void> init() async {}

  /// Signs in the canned demo persona. Inputs ignored — they exist only so
  /// future swap to the real `AuthService.signIn(email, password)` is a
  /// signature match.
  Future<FacilityUser> signIn({String? email, String? password}) async {
    _user = const FacilityUser(
      displayName: 'Dana Chen',
      title: 'Director of Nursing',
      clientId: 'demo_client_001',
      role: 'facility_admin',
    );
    notifyListeners();
    return _user!;
  }

  Future<void> signOut() async {
    if (_user == null) return;
    _user = null;
    notifyListeners();
  }
}
