/// Authenticated GoSteady user.
class GoSteadyUser {
  final String userId;
  final String email;
  final String name;
  final UserRole role;
  final String? idToken;

  const GoSteadyUser({
    required this.userId,
    required this.email,
    required this.name,
    required this.role,
    this.idToken,
  });

  bool get isCaregiver => role == UserRole.caregiver;
  bool get isWalker => role == UserRole.walker;
}

enum UserRole {
  walker,
  caregiver;

  static UserRole fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'caregiver':
        return UserRole.caregiver;
      case 'walker':
      default:
        return UserRole.walker;
    }
  }

  String get label {
    switch (this) {
      case UserRole.walker:
        return 'Walker';
      case UserRole.caregiver:
        return 'Caregiver';
    }
  }
}
