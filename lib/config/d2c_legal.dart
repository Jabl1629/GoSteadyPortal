/// D2C legal / user-agreement constants.
///
/// The plain-language agreements shown at onboarding summarize and link to
/// the published legal pages; the version stamp is recorded server-side on
/// claim (walker) and accept (caregiver) so we can evidence who acknowledged
/// which version and when. See `docs/specs/d2c-user-agreement.md` +
/// `docs/specs/d2c-caregiver-agreement.md`.
class D2CLegal {
  D2CLegal._();

  /// Bump when the substance of either agreement changes. Sent to the API on
  /// claim/accept and stored as `agreementVersion`. Matches the draft date.
  static const String agreementVersion = '2026-07-18';

  /// Published legal pages (live at the marketing domain). `sms-consent.html`
  /// is intentionally omitted until it's deployed there — the live Terms +
  /// Privacy pages 200; the SMS page currently 404s at gosteady.co (the
  /// signup/join copy carries "reply STOP" inline in the meantime).
  static const String termsUrl = 'https://gosteady.co/terms.html';
  static const String privacyUrl = 'https://gosteady.co/privacy.html';
}
