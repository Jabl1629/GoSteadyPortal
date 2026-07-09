import 'dart:async';
import 'dart:convert';

import 'package:amazon_cognito_identity_dart_2/cognito.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [CognitoStorage] backed by [SharedPreferences] (which is `localStorage` on
/// web), so the Cognito session — id / access / **refresh** tokens — survives a
/// page reload. Without it, `CognitoUserPool` defaults to in-memory storage and
/// every refresh forces a fresh SMS-OTP sign-in (D2C) / re-login (facility).
///
/// With this, `getSession()` restores from the persisted tokens and, once the
/// short-lived id/access token expires, silently refreshes using the
/// 30-day refresh token — so a signed-in user stays signed in across reloads
/// until the refresh token itself lapses.
///
/// Values are JSON-encoded (the Cognito SDK stores a mix of strings + ints);
/// keys are namespaced so they never clash with the app's own prefs.
class PrefsCognitoStorage extends CognitoStorage {
  PrefsCognitoStorage(this._prefs, {String namespace = 'cognito'})
      : _prefix = 'gs_$namespace.';

  final SharedPreferences _prefs;
  final String _prefix;

  @override
  Future<dynamic> getItem(String key) async {
    final raw = _prefs.getString('$_prefix$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw; // tolerate a legacy/plain value
    }
  }

  @override
  Future<dynamic> setItem(String key, value) async {
    await _prefs.setString('$_prefix$key', jsonEncode(value));
    return value;
  }

  @override
  Future<dynamic> removeItem(String key) async {
    final prev = await getItem(key);
    await _prefs.remove('$_prefix$key');
    return prev;
  }

  @override
  Future<void> clear() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await _prefs.remove(k);
    }
  }
}
