import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_theme.dart';
import '../data/d2c_mock_data.dart';

/// Account-tier screens for the signed-in D2C user:
///   - Account settings (name / email / phone / relationship + sign out)
///   - Notification preferences (the {alertType} × {SMS, email} matrix)
///   - Customer audit log ("who's accessed Susan's data")
///   - Device settings (serial, show QR, transfer)
///
/// All share [_AccountScaffold]: a back-arrow app bar + centered 640
/// column. Mobile-first.

class _AccountScaffold extends StatelessWidget {
  const _AccountScaffold({
    required this.title,
    required this.child,
    this.backTo = '/d2c/preview/dashboard',
  });

  final String title;
  final Widget child;
  final String backTo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.warmWhite,
      appBar: AppBar(
        backgroundColor: AppTheme.warmWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textDark),
          onPressed: () => context.go(backTo),
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.textDark,
              ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Account settings
// ─────────────────────────────────────────────────────────────────────

class D2CAccountSettingsScreen extends StatelessWidget {
  const D2CAccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'Account',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const _SettingsGroup(
            label: 'Your details',
            children: [
              _SettingsRow(label: 'Name', value: 'Sarah Davis'),
              _SettingsRow(label: 'Email', value: 'sarah.davis@gmail.com'),
              _SettingsRow(
                  label: 'Mobile', value: '(415) 555-1234', trailing: 'Verified'),
              _SettingsRow(label: 'Relationship to Susan', value: 'Daughter'),
            ],
          ),
          const SizedBox(height: 20),
          _SettingsGroup(
            label: 'Preferences',
            children: [
              _SettingsNav(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                onTap: () => context.go('/d2c/preview/account/notifications'),
              ),
              _SettingsNav(
                icon: Icons.devices_other_outlined,
                label: 'Device',
                onTap: () => context.go('/d2c/preview/account/device'),
              ),
              _SettingsNav(
                icon: Icons.shield_outlined,
                label: 'Who can see Susan\'s data',
                onTap: () => context.go('/d2c/preview/account/audit'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Center(
            child: TextButton.icon(
              onPressed: () => context.go('/d2c/preview/onboarding/sign-in'),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign out',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(foregroundColor: AppTheme.statusAlert),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppTheme.textSoft,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.value, this.trailing});
  final String label;
  final String value;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: AppTheme.textSoft, fontSize: 12.5)),
                const SizedBox(height: 3),
                Text(value,
                    style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 15,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          if (trailing != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.sage.withOpacity(0.10),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(trailing!,
                  style: const TextStyle(
                      color: AppTheme.sage,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            )
          else
            Icon(Icons.edit_outlined,
                size: 16, color: AppTheme.textSoft.withOpacity(0.7)),
        ],
      ),
    );
  }
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.sage),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 15,
                      fontWeight: FontWeight.w500)),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppTheme.textSoft.withOpacity(0.7)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Notification preferences matrix
// ─────────────────────────────────────────────────────────────────────

class D2CNotificationPrefsScreen extends StatefulWidget {
  const D2CNotificationPrefsScreen({super.key});

  @override
  State<D2CNotificationPrefsScreen> createState() =>
      _D2CNotificationPrefsScreenState();
}

class _D2CNotificationPrefsScreenState
    extends State<D2CNotificationPrefsScreen> {
  late List<NotificationPref> _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = D2CMockData.notificationPrefs();
  }

  @override
  Widget build(BuildContext context) {
    final activity = _prefs.where((p) => !p.deviceOperational).toList();
    final device = _prefs.where((p) => p.deviceOperational).toList();
    return _AccountScaffold(
      title: 'Notifications',
      backTo: '/d2c/preview/account',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            'Choose how you want to hear about each kind of update. '
            'Texts are best for urgent things.',
            style: const TextStyle(
                color: AppTheme.textSoft, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 20),
          _PrefHeaderRow(),
          const SizedBox(height: 8),
          _PrefGroup(
            label: 'Activity',
            prefs: activity,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          _PrefGroup(
            label: 'Device health',
            prefs: device,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text(
            'Standard text and data rates may apply. Reply STOP to any text '
            'to turn off SMS alerts.',
            style: TextStyle(
                color: AppTheme.textSoft.withOpacity(0.85),
                fontSize: 11.5,
                height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _PrefHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        children: [
          const Expanded(child: SizedBox()),
          SizedBox(
            width: 52,
            child: Text('Text',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            width: 52,
            child: Text('Email',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textSoft,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _PrefGroup extends StatelessWidget {
  const _PrefGroup(
      {required this.label, required this.prefs, required this.onChanged});
  final String label;
  final List<NotificationPref> prefs;
  final ValueChanged<NotificationPref> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.textSoft,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Column(
            children: [
              for (var i = 0; i < prefs.length; i++) ...[
                _PrefRow(pref: prefs[i], onChanged: onChanged),
                if (i < prefs.length - 1)
                  Divider(height: 1, color: AppTheme.border.withOpacity(0.5)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({required this.pref, required this.onChanged});
  final NotificationPref pref;
  final ValueChanged<NotificationPref> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pref.label,
                    style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(pref.description,
                    style: const TextStyle(
                        color: AppTheme.textSoft, fontSize: 12, height: 1.3)),
              ],
            ),
          ),
          SizedBox(
            width: 52,
            child: Center(
              child: _MiniCheck(
                value: pref.sms,
                onChanged: (v) {
                  pref.sms = v;
                  onChanged(pref);
                },
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Center(
              child: _MiniCheck(
                value: pref.email,
                onChanged: (v) {
                  pref.email = v;
                  onChanged(pref);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniCheck extends StatelessWidget {
  const _MiniCheck({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: value ? AppTheme.sage : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: value ? AppTheme.sage : AppTheme.border,
            width: 1.5,
          ),
        ),
        child: value
            ? const Icon(Icons.check_rounded, size: 17, color: Colors.white)
            : null,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Customer audit log
// ─────────────────────────────────────────────────────────────────────

class D2CAuditScreen extends StatelessWidget {
  const D2CAuditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = D2CMockData.auditLog();
    return _AccountScaffold(
      title: "Who's accessed Susan's data",
      backTo: '/d2c/preview/account',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            'Every time someone in the Care Team views activity or takes an '
            'action, it shows up here. This is for your peace of mind — you '
            'always know who\'s looking.',
            style: const TextStyle(
                color: AppTheme.textSoft, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.cardShadow,
            ),
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  _AuditRow(entry: entries[i]),
                  if (i < entries.length - 1)
                    Divider(height: 1, color: AppTheme.border.withOpacity(0.5)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});
  final AuditEntry entry;

  String _ago() {
    final d = DateTime.now().difference(entry.at);
    if (d.inDays >= 1) return '${d.inDays}d ago';
    if (d.inHours >= 1) return '${d.inHours}h ago';
    if (d.inMinutes >= 1) return '${d.inMinutes} min ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.cream,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.visibility_outlined,
                size: 16, color: AppTheme.textSoft.withOpacity(0.8)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                    color: AppTheme.textDark, fontSize: 14, height: 1.35),
                children: [
                  TextSpan(
                      text: entry.actorName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(
                      text: ' ${entry.action}',
                      style: const TextStyle(color: AppTheme.textSoft)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(_ago(),
              style: TextStyle(
                  color: AppTheme.textSoft.withOpacity(0.8), fontSize: 12)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Device settings (serial, show QR, transfer)
// ─────────────────────────────────────────────────────────────────────

class D2CDeviceSettingsScreen extends StatelessWidget {
  const D2CDeviceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _AccountScaffold(
      title: 'Device',
      backTo: '/d2c/preview/account',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          // Status card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: AppTheme.cardShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          color: AppTheme.statusOk, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    const Text('Connected',
                        style: TextStyle(
                            color: AppTheme.textDark,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const Text('Battery 12%',
                        style: TextStyle(
                            color: AppTheme.statusWarn,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('GoSteady Walker Cap',
                    style: TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('Serial GS0000004421',
                    style: TextStyle(
                        color: AppTheme.textSoft.withOpacity(0.9),
                        fontSize: 12.5,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Show QR
          _DeviceActionCard(
            icon: Icons.qr_code_2_rounded,
            title: 'Show device QR code',
            subtitle: 'Pull this up to add someone in person',
            onTap: () => _showQrSheet(context),
          ),
          const SizedBox(height: 12),
          // Transfer
          _DeviceActionCard(
            icon: Icons.swap_horiz_rounded,
            title: 'Transfer to someone else',
            subtitle: 'Giving this walker to another person? Contact support '
                'to move it safely.',
            onTap: () {},
          ),
        ],
      ),
    );
  }

  void _showQrSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.warmWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppTheme.border,
                      borderRadius: BorderRadius.circular(100)),
                ),
              ),
              const SizedBox(height: 24),
              const Text('Scan to join the Care Team',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600,
                      color: AppTheme.textDark)),
              const SizedBox(height: 6),
              const Text('Have them point their phone camera here.',
                  style: TextStyle(color: AppTheme.textSoft, fontSize: 14)),
              const SizedBox(height: 24),
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Icon(Icons.qr_code_2_rounded,
                    size: 150, color: AppTheme.textDark),
              ),
              const SizedBox(height: 16),
              Text('GS0000004421',
                  style: TextStyle(
                      color: AppTheme.textSoft.withOpacity(0.9),
                      fontSize: 12.5,
                      fontFamily: 'monospace')),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceActionCard extends StatelessWidget {
  const _DeviceActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppTheme.cardShadow,
            color: Colors.white,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.sage.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: AppTheme.sage, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppTheme.textDark,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: const TextStyle(
                            color: AppTheme.textSoft,
                            fontSize: 12.5,
                            height: 1.35)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppTheme.textSoft.withOpacity(0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
