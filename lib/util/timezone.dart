import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Browser timezone detection for D2C timezone capture
/// (docs/specs/d2c-timezone-capture.md).
///
/// Reads the IANA zone the browser is running in
/// (`Intl.DateTimeFormat().resolvedOptions().timeZone`, e.g.
/// `"America/Denver"`) — the exact format the backend's `ZoneInfo`
/// day-bucketing wants. Web-only (this is a Flutter web app); returns `null`
/// on any failure so callers treat it as "unknown" and leave the server's UTC
/// default in place. Never throws into the claim / dashboard-load path.
///
/// Uses the dynamic-interop API (`dart:js_interop_unsafe`) rather than
/// `extension type` bindings, which the repo's `sdk: '>=3.0.0'` constraint
/// does not enable.
String? detectIanaTimeZone() {
  try {
    final intl = globalContext.getProperty<JSObject>('Intl'.toJS);
    final ctor = intl.getProperty<JSFunction>('DateTimeFormat'.toJS);
    final fmt = ctor.callAsConstructor<JSObject>();
    final opts = fmt.callMethod<JSObject>('resolvedOptions'.toJS);
    final tz = opts.getProperty<JSString>('timeZone'.toJS).toDart;
    return tz.isEmpty ? null : tz;
  } catch (_) {
    return null;
  }
}
