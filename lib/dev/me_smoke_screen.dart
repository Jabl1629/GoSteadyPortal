import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/api_models.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Renders the raw `GET /api/v1/me` response — exists only to validate
/// the sign-in → JWT → API Gateway → handler → claim mirror → UI render
/// pipeline end-to-end before any business UI lands. Removed in 2B-FAC-R.
///
/// Live mode only. Demo mode hides the route via [AppRouter] redirect.
///
/// Per phase-2b-0-foundation.md L10 + T1.
class MeSmokeScreen extends StatefulWidget {
  const MeSmokeScreen({super.key});

  @override
  State<MeSmokeScreen> createState() => _MeSmokeScreenState();
}

class _MeSmokeScreenState extends State<MeSmokeScreen> {
  Future<MeResponse>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<MeResponse> _load() {
    final api = AppState.of(context).apiClient;
    if (api == null) {
      throw StateError(
        'MeSmokeScreen rendered without ApiClient — this route is '
        'supposed to be live-mode-only.',
      );
    }
    return api.getMe();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AppState.of(context).auth;
    return Scaffold(
      appBar: AppBar(
        title: const Text('/api/v1/me — smoke'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _future = _load()),
            tooltip: 'Re-fetch',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => auth.signOut(),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: FutureBuilder<MeResponse>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            final err = snap.error;
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Error',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    err is ApiException
                        ? '${err.code} (${err.httpStatus}): ${err.message}'
                        : err.toString(),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Local session state',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  _claimPair('userId', auth.currentUser?.userId ?? '—'),
                  _claimPair('email', auth.currentUser?.email ?? '—'),
                  _claimPair(
                      'role', auth.currentUser?.role.name ?? '—'),
                  _claimPair(
                      'clientId', auth.currentUser?.clientId ?? '—'),
                ],
              ),
            );
          }
          final me = snap.data!;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '✅ /me round-trip succeeded',
                  style: TextStyle(
                    color: AppTheme.sage,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 16),
                Text('Claims', style: Theme.of(context).textTheme.titleMedium),
                _claimPair('userId', me.userId),
                _claimPair('clientId', me.clientId ?? '—'),
                _claimPair('role', me.role.name),
                _claimPair('facilities',
                    me.facilities.isEmpty ? '— (unrestricted)' : me.facilities.join(', ')),
                _claimPair('censuses',
                    me.censuses.isEmpty ? '— (unrestricted)' : me.censuses.join(', ')),
                _claimPair('internalAccess', me.internalAccess.toString()),
                const SizedBox(height: 24),
                Text('Raw payload',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F2EB),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(me.raw),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _claimPair(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(
                key,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Color(0xFF6B7280),
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
}
