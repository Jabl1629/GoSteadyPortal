import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../data/facility_mock_data.dart';
import '../services/mock_facility_auth.dart';
import '../state/facility_selection.dart';
import 'facility_selector_dropdown.dart';

/// Top app bar for the facility shell. Contains the brand mark, the
/// facility/unit selector dropdown, and the signed-in admin chip.
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
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: AppTheme.border.withOpacity(0.6)),
        ),
      ),
      child: Row(
        children: [
          _BrandMark(),
          const SizedBox(width: 24),
          FacilitySelectorDropdown(data: data, selection: selection),
          const Spacer(),
          ListenableBuilder(
            listenable: FacilityMockAuthService.instance,
            builder: (context, _) => _UserChip(
              user: FacilityMockAuthService.instance.currentUser,
            ),
          ),
          const SizedBox(width: 4),
          _SignOutButton(),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
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
        const SizedBox(width: 10),
        Text(
          'GoSteady',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _UserChip extends StatelessWidget {
  const _UserChip({required this.user});
  final FacilityUser? user;

  @override
  Widget build(BuildContext context) {
    if (user == null) return const SizedBox.shrink();
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
