import '../models/activity.dart';
import 'api_models.dart';

/// Converts 2A-RD's raw `ActivitySession` payloads into the demo's
/// existing `DailyActivity` + `HourlyActivity` shape so the charts +
/// trend widgets can render unchanged.
///
/// Per phase-2b-fac-r-facility-reads.md L7 — client-side aggregation
/// of sessions by `date` field (facility-local date string from
/// server) for daily; bucket by sessionStart hour for 24H view.
///
/// Gait fields are NOT present in the API response (per L8) — the
/// resulting HourlyActivity / DailyActivity have `avgGaitSpeedFts`,
/// `minGaitSpeedFts`, `maxGaitSpeedFts` set to 0. The screens that
/// render those are hidden in live mode.
class SessionAdapter {
  SessionAdapter._();

  /// Aggregate sessions by their `date` string into a list of
  /// [DailyActivity] (one entry per distinct date), oldest-first.
  /// Each day's `hours` list is bucketed from the sessions that
  /// occurred on that day.
  static List<DailyActivity> toDailyList(List<ActivitySession> sessions) {
    if (sessions.isEmpty) return const [];

    // Group sessions by their server-supplied date string.
    final Map<String, List<ActivitySession>> byDate = {};
    for (final s in sessions) {
      final key = s.date.isNotEmpty
          ? s.date
          : _formatDate(s.sessionStart);
      (byDate[key] ??= []).add(s);
    }

    final entries = byDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return entries.map((e) {
      final daySessions = e.value;
      final date = _parseDate(e.key) ?? daySessions.first.sessionStart;
      return DailyActivity(date: date, hours: _bucketByHour(daySessions, date));
    }).toList(growable: false);
  }

  /// Build the single [DailyActivity] for "today."
  ///
  /// "Today" is the CALENDAR day — the same `date` field that
  /// [toDailyList] groups the 7D/30D views on — NOT the rolling 24h
  /// window the API returns. `range=24h` spans two calendar days (last
  /// night + this morning); summing all of it made evening sessions from
  /// yesterday show on today's 0–23h clock (a 9pm bar at 10am) and
  /// inflated the Today's-Activity headline to ~24h of data. So we filter
  /// to the sessions whose `date` matches today before bucketing — which
  /// makes the headline + 24h chart consistent with the 7D "today" bar.
  ///
  /// `date` is facility-local (server-computed); `todayStr` is the
  /// viewer's local date. They align when the viewer is in the facility
  /// timezone (the common case); a cross-timezone viewer is a deeper fix
  /// that needs the facility tz threaded through (tracked separately).
  static DailyActivity toToday(
    List<ActivitySession> sessions, {
    DateTime? referenceDate,
  }) {
    final ref = (referenceDate ?? DateTime.now()).toLocal();
    final todayStr = _formatDate(ref);
    final todaySessions = sessions
        .where((s) =>
            (s.date.isNotEmpty ? s.date : _formatDate(s.sessionStart.toLocal())) ==
            todayStr)
        .toList(growable: false);
    if (todaySessions.isEmpty) {
      return DailyActivity(date: ref, hours: const []);
    }
    final hours = _bucketByLocalHour(todaySessions, ref);
    return DailyActivity(date: ref, hours: hours);
  }

  /// Aggregate the daily list into per-week buckets (used by the demo's
  /// 6M view). NOT called in live mode in V1 — the 6M tab is hidden
  /// pending Phase 1C-full daily rollups. Kept for API symmetry.
  static List<WeeklyActivity> toWeeklyList(List<ActivitySession> sessions) {
    if (sessions.isEmpty) return const [];
    final daily = toDailyList(sessions);

    final Map<DateTime, List<DailyActivity>> byWeek = {};
    for (final d in daily) {
      final weekStart = _weekStart(d.date);
      (byWeek[weekStart] ??= []).add(d);
    }

    final entries = byWeek.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return entries.map((e) {
      final weekStart = e.key;
      final days = e.value;
      final totalSteps = days.fold<int>(0, (s, d) => s + d.totalSteps);
      final totalDist = days.fold<double>(0, (s, d) => s + d.totalDistanceFt);
      final totalMin =
          days.fold<int>(0, (s, d) => s + d.totalTimeInMotionMinutes);
      return WeeklyActivity(
        weekStart: weekStart,
        totalSteps: totalSteps,
        totalDistanceFt: totalDist,
        totalTimeInMotionMinutes: totalMin,
      );
    }).toList(growable: false);
  }

  // ── Helpers ─────────────────────────────────────────────────────

  /// Bucket sessions into 24 hourly slots by **local hour-of-day** —
  /// ignores the date entirely. Used by [toToday] which gets all
  /// sessions from the server's 24h-windowed response.
  ///
  /// Each session's hours are derived from `sessionStart.toLocal().hour`
  /// (after Dart converts the UTC timestamp to system tz). Sessions
  /// spanning multiple local hours contribute proportionally by minute.
  static List<HourlyActivity> _bucketByLocalHour(
    List<ActivitySession> sessions,
    DateTime referenceDay,
  ) {
    final hoursSteps = List<double>.filled(24, 0);
    final hoursDist = List<double>.filled(24, 0);
    final hoursMin = List<double>.filled(24, 0);
    // Gait (ft/s), 0.16.0-gait+ — same accumulation as _bucketByHour: a
    // duration-weighted mean per hour + per-hour min/max across sessions.
    final hoursGaitNum = List<double>.filled(24, 0);
    final hoursGaitDen = List<double>.filled(24, 0);
    final hoursGaitMin = List<double>.filled(24, double.infinity);
    final hoursGaitMax = List<double>.filled(24, 0);

    for (final s in sessions) {
      final start = s.sessionStart.toLocal();
      final end = s.sessionEnd.toLocal();
      final totalMs = end.difference(start).inMilliseconds;
      if (totalMs <= 0) continue;

      final gait = s.gaitSpeedFts;
      final hasGait = gait != null && gait > 0;

      var cursor = start;
      while (cursor.isBefore(end)) {
        final h = cursor.hour;
        final nextBoundary = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour + 1,
        );
        final sliceEnd = nextBoundary.isBefore(end) ? nextBoundary : end;
        final sliceMs = sliceEnd.difference(cursor).inMilliseconds;
        final frac = sliceMs / totalMs;

        hoursSteps[h] += s.steps * frac;
        hoursDist[h] += s.distanceFt * frac;
        hoursMin[h] += s.activeMinutes * frac;

        if (hasGait) {
          hoursGaitNum[h] += gait * sliceMs;
          hoursGaitDen[h] += sliceMs;
          if (gait < hoursGaitMin[h]) hoursGaitMin[h] = gait;
          if (gait > hoursGaitMax[h]) hoursGaitMax[h] = gait;
        }

        cursor = sliceEnd;
      }
    }

    final dayMidnight = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day,
    );

    return List<HourlyActivity>.generate(24, (h) {
      final gaitAvg = hoursGaitDen[h] > 0 ? hoursGaitNum[h] / hoursGaitDen[h] : 0.0;
      return HourlyActivity(
        hour: dayMidnight.add(Duration(hours: h)),
        steps: hoursSteps[h].round(),
        distanceFt: hoursDist[h],
        timeInMotionMinutes: hoursMin[h].round(),
        avgGaitSpeedFts: gaitAvg,
        minGaitSpeedFts: hoursGaitMin[h].isFinite ? hoursGaitMin[h] : 0.0,
        maxGaitSpeedFts: hoursGaitMax[h],
      );
    });
  }

  /// Bucket sessions into 24 hourly slots for [dayStart]'s day.
  ///
  /// Per A4: sessions spanning multiple hours contribute proportionally
  /// by minute to each hour they touch.
  static List<HourlyActivity> _bucketByHour(
    List<ActivitySession> daySessions,
    DateTime dayReference,
  ) {
    final dayMidnight = DateTime(
      dayReference.year,
      dayReference.month,
      dayReference.day,
    );

    // Pre-allocate 24 buckets at zero.
    final hoursSteps = List<double>.filled(24, 0);
    final hoursDist = List<double>.filled(24, 0);
    final hoursMin = List<double>.filled(24, 0);
    // Gait (ft/s) — 0.16.0-gait+. Per-session avg; the firmware omits it
    // (null) when its on-device guards fail. The hour's avg is a duration-
    // weighted mean over the sessions overlapping it; min/max are the spread
    // of per-session gait across those sessions.
    final hoursGaitNum = List<double>.filled(24, 0); // Σ gait·sliceMs
    final hoursGaitDen = List<double>.filled(24, 0); // Σ sliceMs (gait present)
    final hoursGaitMin = List<double>.filled(24, double.infinity);
    final hoursGaitMax = List<double>.filled(24, 0);

    for (final s in daySessions) {
      final start = s.sessionStart.isBefore(dayMidnight)
          ? dayMidnight
          : s.sessionStart;
      final endCap = dayMidnight.add(const Duration(hours: 24));
      final end = s.sessionEnd.isAfter(endCap) ? endCap : s.sessionEnd;
      final totalMs = end.difference(start).inMilliseconds;
      if (totalMs <= 0) continue;

      final gait = s.gaitSpeedFts; // null when firmware omitted it
      final hasGait = gait != null && gait > 0;

      // Distribute steps/distance/minutes proportionally across the
      // hour buckets the session spans.
      var cursor = start;
      while (cursor.isBefore(end)) {
        final h = cursor.hour;
        final nextBoundary = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour + 1,
        );
        final sliceEnd = nextBoundary.isBefore(end) ? nextBoundary : end;
        final sliceMs = sliceEnd.difference(cursor).inMilliseconds;
        final frac = sliceMs / totalMs;

        hoursSteps[h] += s.steps * frac;
        hoursDist[h] += s.distanceFt * frac;
        hoursMin[h] += s.activeMinutes * frac;

        if (hasGait) {
          hoursGaitNum[h] += gait * sliceMs;
          hoursGaitDen[h] += sliceMs;
          if (gait < hoursGaitMin[h]) hoursGaitMin[h] = gait;
          if (gait > hoursGaitMax[h]) hoursGaitMax[h] = gait;
        }

        cursor = sliceEnd;
      }
    }

    return List<HourlyActivity>.generate(24, (h) {
      final gaitAvg = hoursGaitDen[h] > 0 ? hoursGaitNum[h] / hoursGaitDen[h] : 0.0;
      return HourlyActivity(
        hour: dayMidnight.add(Duration(hours: h)),
        steps: hoursSteps[h].round(),
        distanceFt: hoursDist[h],
        timeInMotionMinutes: hoursMin[h].round(),
        avgGaitSpeedFts: gaitAvg,
        minGaitSpeedFts: hoursGaitMin[h].isFinite ? hoursGaitMin[h] : 0.0,
        maxGaitSpeedFts: hoursGaitMax[h],
      );
    });
  }

  /// Server `date` field is "YYYY-MM-DD" facility-local.
  static DateTime? _parseDate(String s) {
    if (s.length < 10) return null;
    final y = int.tryParse(s.substring(0, 4));
    final m = int.tryParse(s.substring(5, 7));
    final d = int.tryParse(s.substring(8, 10));
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  static String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Week starts Monday (matches the demo's convention).
  static DateTime _weekStart(DateTime dt) {
    final wd = dt.weekday; // 1 = Monday
    return DateTime(dt.year, dt.month, dt.day).subtract(Duration(days: wd - 1));
  }
}
