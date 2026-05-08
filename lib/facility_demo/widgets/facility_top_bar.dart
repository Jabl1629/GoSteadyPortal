import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../services/mock_facility_auth.dart';
import '../state/facility_selection.dart';
import 'facility_selector_dropdown.dart';

/// Top app bar for the facility shell. Contains the brand mark, the
/// facility/unit selector dropdown, and the signed-in admin chip. The
/// inner contents collapse at narrow widths so everything stays visible
/// down to ~360px.
class FacilityTopBar extends StatelessWidget {
  const FacilityTopBar({
    super.key,
    required this.data,
    required this.selection,
  });

  final FacilityMockData data;
  final FacilitySelection selection;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Below ~720 the user chip collapses to just its initials avatar.
        // Below ~530 the wordmark drops to just the brand icon. Tuned so
        // every component fits at iPhone-min (~360) up through tablet.
        final isCompact = width < 720;
        final isVeryCompact = width < 530;

        return Container(
          height: 64,
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 14 : 24,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: AppTheme.border.withOpacity(0.6)),
            ),
          ),
          child: Row(
            children: [
              _BrandMark(showWordmark: !isVeryCompact),
              SizedBox(width: isCompact ? 10 : 24),
              Flexible(
                child: FacilitySelectorDropdown(
                  data: data,
                  selection: selection,
                ),
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: FacilityMockAuthService.instance,
                builder: (context, _) => _UserChip(
                  user: FacilityMockAuthService.instance.currentUser,
                  collapsed: isCompact,
                ),
              ),
              SizedBox(width: isCompact ? 0 : 4),
              _SignOutButton(),
            ],
          ),
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.showWordmark});
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.sage,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.accessibility_new_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
        if (showWordmark) ...[
          const SizedBox(width: 10),
          Text(
            'GoSteady',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ],
    );
  }
}

class _UserChip extends StatelessWidget {
  const _UserChip({required this.user, required this.collapsed});
  final FacilityUser? user;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (user == null) return const SizedBox.shrink();
    if (collapsed) {
      // Avatar only — name + title are dropped on phone-sized layouts.
      return Tooltip(
        message: '${user!.displayName} · ${user!.title}',
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppTheme.sage,
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.sage.withOpacity(0.25), width: 1),
          ),
          child: Center(
            child: Text(
              user!.initials,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 14, 5),
      decoration: BoxDecoration(
        color: AppTheme.sage.withOpacity(0.06),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppTheme.sage.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppTheme.sage,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                user!.initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user!.displayName,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              Text(
                user!.title,
                style: const TextStyle(
                  color: AppTheme.textSoft,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Sign out',
      icon: const Icon(Icons.logout_rounded, size: 18),
      onPressed: () => FacilityMockAuthService.instance.signOut(),
      style: IconButton.styleFrom(
        foregroundColor: AppTheme.textSoft,
      ),
    );
  }
}
