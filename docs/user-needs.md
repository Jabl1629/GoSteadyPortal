# GoSteady Facility Portal — User Needs

> **Status:** V1 spec (post-decision). Generated from the live demo at
> [gosteady.co/facilitydemo](https://gosteady.co/facilitydemo/) and
> revised through working-session prep (2026-05) — the 12 original
> open questions are now resolved in §7. New requirements that
> emerged during prep (Care Note, Pause Notifications rename, smart
> debounce) are integrated into the relevant capability sections.
> Story IDs (US-xx) are stable references for downstream work.

---

## 1. Purpose

The GoSteady facility portal is a web dashboard for senior-living and
skilled-nursing staff. It surfaces, in one place, the activity and
mobility patterns of every resident using a GoSteady-equipped walker
(steps, active time, distance, gait speed, device health) and proactively
flags residents whose patterns suggest a problem before staff would
otherwise notice — a fall in baseline activity, declining gait speed, a
day without any movement. The portal turns a facility's walker fleet
into a passive monitoring layer the team can act on, without adding new
charting work for nurses.

---

## 2. Personas

### Primary portal users

- **Care Staff** (any authorized facility user — CNA, floor nurse,
  day-shift staff, DON, facility director). All Care Staff have the
  same permissions in V1: read everything, acknowledge notifications,
  pause notifications, add/edit/discharge residents, replace/discontinue
  devices. The Admin vs. Care Staff split is reserved for V2 once we
  see whether real customers want role-gating. The full forward-looking
  RBAC model — six customer roles + two internal — lives in
  **Appendix B**.

### Subject of monitoring (not a portal user)

- **Resident.** The walker user being monitored. Does not log in.
  Activity history follows the resident, not the device.

### Future / out of V1 scope

- **Family member / outside caregiver.** Read-only view of one
  resident's activity, opt-in alerts. Auth model already reserves
  the role (`isCaregiver` flag), but no UI yet.

---

## 3. Product Overview

A multi-tenant web app. One **Client** (corporate operator) owns one or
more **Facilities**. Each Facility has one or more **Units** (wing,
floor, ward — e.g., "Memory Care", "Rehab Wing", "Assisted Living —
West"). Each Unit houses zero or more **Residents**, each of whom may
have one **Device** (the GoSteady walker cap) assigned. Residents and
their activity history persist across device reassignment and across
unit transfers. Devices stream activity to AWS; the portal renders the
materialized views.

V1 emphasizes **read-only awareness** for Care Staff and **lifecycle
operations** for Administrators. It is not a charting system, an
alerting system that pages externally, or a clinical record.

---

## 4. User Stories

### 4.1 Sign-in & Session

**US-01.** As a portal user, I can sign in with my email and password
so that I can see the residents I'm authorized to monitor.

- Authentication is per-user, not per-facility shared
- Failed sign-in surfaces a clear error without revealing whether the
  email exists
- Forgot-password flow exists (not in demo)

**US-02.** As a signed-in user, I can sign out from the header so that
my session is secured when I step away from a shared workstation.

- Sign-out clears the auth token immediately
- The portal returns me to the sign-in screen
- Sign-out is reachable from any screen, not buried in a settings page

---

### 4.2 Daily At-a-Glance (Census)

**US-03.** As Care Staff, I can see every resident at my facility in a
single **Census view** so that I can quickly identify who needs
attention this shift.

- Default landing screen post-sign-in
- One row/tile per active resident
- Discharged residents are excluded by default

**US-04.** As Care Staff, I can switch between **List view** and **Tile
view** of the Census so that I can use the layout that fits my current
task.

- List view defaults on (data-dense scanning)
- Tile view available for visual triage / when projecting on a wall
  monitor
- Choice is sticky within a session

**US-05.** As Care Staff, I can **filter the Census by notification
status** — all / has notifications / critical only / no notifications —
so that I can focus on residents who need review.

- Filter persists while sorting changes
- "Critical only" surfaces just the highest-severity items
- Empty-state copy explains what's filtered out

**US-06.** As Care Staff, I can **sort the Census** by "Needs review
first", name (A–Z), most active, or least active so that I can scan in
the order most useful for what I'm doing.

- "Needs review first" sorts critical → has-notifications → none, then
  by name within each band
- Sort is independent of filter

**US-07.** As Care Staff, I can **filter the Census by Unit** so that
I only see the residents on the wing/floor I'm staffing today.

- Multi-select: I can choose one Unit, several Units, or all Units
- Selector label reflects current state ("All Units (10)",
  "Memory Care (3)", "2 units · 6 res.")
- Unit list spans all Facilities I have access to

**US-08.** As Care Staff, I can see the **count of residents shown**
("10 residents" or "3 of 10 residents") so that I know whether a filter
is in effect.

**US-09.** As Care Staff, I can see at-a-glance values in the **List
view** so that I can compare residents side-by-side without clicking in:

- Resident name + photo placeholder
- Location (Unit · Room)
- Notifications (icon + count + severity)
- Active minutes today
- Active minutes 7-day average
- Active minutes trend (↑↓ vs. prior period, % change)
- Steps today
- Step trend
- Gait Speed (ft/sec, 3-day average)
- Gait trend (vs. 30-day baseline)

**US-10.** As Care Staff, I can see **color-coded value tiers** on
numeric columns (low / moderate / high) so that I can spot outliers
without reading the numbers.

- Thresholds are calibrated for the senior population, not general
  fitness
- Tiering does not apply to gait (avoids implying a "good" or "bad"
  gait speed in absolute terms)

**US-11.** As Care Staff, I can **hover any column header** to see what
the metric means and how it's calculated so that I know what I'm
looking at without consulting a separate help doc.

**US-12.** As Care Staff, the Census table is **responsive to my
window width** so that I can use it on a phone, tablet, laptop, or
external monitor without horizontal scroll or truncation.

- Columns degrade gracefully on narrow widths (priority order: name,
  notifications, today's activity > trend columns)
- Column count adapts at sensible breakpoints

**US-13.** As Care Staff using **Tile view**, every tile is the same
size regardless of whether the resident has notifications so that the
visual grid stays rhythmic.

**US-14.** As Care Staff using **Tile view**, each tile shows a
**short-form notification summary** (e.g., "No activity today",
"Below typical") so that I know what the issue is without opening the
resident.

---

### 4.3 Resident Activity Deep-Dive

**US-15.** As Care Staff, I can click any resident from the Census to
open their **detail view** so that I can see their full activity
picture.

- Opens as an overlay on top of the Census on wide screens (keeps the
  list context behind it)
- Opens as a full-screen page on narrow/phone screens with a "← Back
  to Census" link

**US-16.** As Care Staff, I can see the resident's **name, unit, and
room number** prominently in the detail header so that I'm sure I'm
looking at the right person.

**US-17.** As Care Staff, I can see **today's activity** for the
resident (active time, step count, distance) in a glanceable headline
tile so that I know how they're doing right now.

- "Today" is anchored to the facility's local time
- If there's no data for today yet, the tile communicates that
  explicitly rather than rendering zeros

**US-18.** As Care Staff, I can see **trend charts** for active time,
distance, and steps across multiple time windows so that I can spot
changes over time.

- Window toggle: 24H (hourly bars), 7D (daily), 30D (daily),
  6M (weekly)
- All three trend charts share one window toggle (consistent context)
- Charts render even on partial data (empty days shown as zero)

**US-19.** As Care Staff, I can see a **gait speed chart** with average,
minimum, and maximum values so that I can monitor mobility quality, not
just quantity.

- Gait speed displayed in ft/sec (the unit US care staff are
  comfortable with) inside the table and in the chart's summary chip
- Min/max convey range of mobility within the window

**US-20.** As Care Staff, I can see **device health** (battery,
cellular signal, last data received, serial, firmware) inside the
resident detail so that I know whether the data I'm reading is fresh
and the hardware is healthy.

- Last-data-received timestamp is in absolute time (not "an hour ago")
  to avoid ambiguity across shifts
- Tapping the device-health card opens a detailed device screen

**US-21.** As Care Staff, I can **return to the Census** from a
resident detail (via a Back link or by closing the overlay) so that I
can move on to the next resident efficiently.

**US-44.** As Care Staff, I can read and edit a **Care Note** at the
top of a resident's detail view so that the team has context (e.g.,
"Back from hospital Feb 12 — slow start expected") when interpreting
that resident's activity numbers.

- **Single overwriteable text block**, not a feed of past notes —
  keeps it from drifting into a parallel charting system
- Max ~280 characters; forces brevity, fits one line on phone
- **Inline editable**: click to edit, save on blur or Enter; no modal
- Displays last-editor name and timestamp ("Updated by J. Blackburn ·
  2h ago")
- Empty state shows a subtle "+ Add care note" link
- Lives between the resident header and the notification review
  panel — first thing read after the name
- Edits are written to the audit log (§5)

---

### 4.4 Notifications & Alerts

**US-22.** As Care Staff, I see notifications **automatically generated**
for the following conditions so that I'm prompted to check in on
residents whose patterns suggest a problem:

- **No activity today** — the device hasn't reported any steps or
  motion since midnight, by an expected check-in time
- **Below typical activity** — today's step count is significantly
  below this resident's recent personal baseline
- **Declining trend** — the resident's multi-day average has been
  decreasing relative to their longer-term baseline
- **Debounce** — if a notification was already raised yesterday and
  the condition is unchanged (still no activity, still below typical),
  the rule does **not** raise a duplicate today. The original
  notification remains active until acknowledged. This prevents the
  daily-alert-pileup that drove "Pause Notifications" (§4.5 US-31).

**US-23.** As Care Staff, every notification carries a **severity**
(critical, standard) so that I can prioritize critical issues first.

- Severity rules are deterministic and documented (not a black-box ML
  call)
- Severity influences sort order, badge color, and icon

**US-24.** As Care Staff, I can see a **notification badge** on the
Census tile or list row so that I can spot residents needing review at
a glance without opening anyone.

- Badge shows count when there are multiple notifications
- Badge color matches severity (critical is red, standard is amber)

**US-25.** As Care Staff, I can **review notifications in a dedicated
panel** inside the resident detail so that I have context (their
trends, today's activity) while I review each one.

- Panel sits above the resident's activity dashboard
- Multiple notifications stack vertically in the panel

**US-26.** As Care Staff, I can **acknowledge a notification and save a
note** in the same action so that I document what I did about it in a
single click.

- "Acknowledge + Save Note" button is the primary action on each
  notification card
- Note is optional but recommended
- No separate "dismiss with X" action — every clear is intentional

**US-27.** As Care Staff, an acknowledged notification **clears from
the active list** so that I'm only ever shown what still needs review.

- Cleared notifications remain queryable for audit (not deleted)
- Re-triggering conditions (e.g., still no activity tomorrow) create a
  new notification, not a resurrection of the old one

---

### 4.5 Resident Lifecycle

**US-28.** As Care Staff, I can **register a new resident** in
the system with first name, last name, facility, unit, room, and device
ID so that they can start being monitored.

- The **device ID must match the format `GS` + 10 digits** (e.g.,
  `GS0000000123`); non-conforming input is rejected at the field level
- The **Unit dropdown is constrained by the Facility** I select; I
  cannot assign a resident to a unit that doesn't exist at their
  facility
- All fields are required
- Action is accessible from a primary "Add Resident" CTA in the top
  right of the Census header

**US-29.** As Care Staff, I can **edit a resident's name, unit,
and room** so that the record stays accurate as they move between
rooms or wings.

- Edit Resident Info is reached from a settings (gear) icon next to
  the resident's name on the detail view
- Unit dropdown includes units from all facilities (allowing
  cross-facility transfer in one operation)

**US-30.** As Care Staff, I can **transfer a resident from one
facility to another** via Edit Resident Info so that residents moving
between sister properties keep one continuous record.

- No separate "Transfer" action needed; Unit change covers it
- Activity history is unbroken across the transfer

**US-31.** As Care Staff, I can **pause notifications** for a
resident for N days (1–90) with a reason (in hospital, at rehab
elsewhere, family visit / off-site, on vacation, other) so that the
team isn't paged about expected absences while the resident is
off-site.

- Activity tracking continues normally — only **notifications** are
  paused (the name was renamed from "Pause Monitoring" to avoid
  implying we stop collecting data, which we don't)
- Default duration: 7 days
- Pause **auto-resumes early** if activity data starts streaming
  again before the timer expires (the reason for pausing is gone)
- Pause **auto-resumes** when the timer expires; staff can also
  manually unpause earlier
- **Census tile and list row** show a paused-bell icon so it's
  visible at a glance without opening the resident
- **Resident detail** shows a clear banner with the countdown
  (e.g., "Notifications paused — 4 days remaining · in hospital")
  and a button to unpause early
- Pause start, end, and reason are written to the audit log (§5)

**US-32.** As Care Staff, I can **discharge a resident** with a
reason (transferred / moved home / hospital admission / deceased /
other) and optional free-text notes so that their record is archived
cleanly.

- Discharge **preserves activity history** for compliance and family
  inquiries (default retention: 7 years, V2 configurable)
- Discharged resident is removed from the active Census
- **Assigned device is automatically released** to the unassigned
  pool — no need to discontinue the device first
- Discharged record stays in a **recoverable state for 7 days** —
  reachable via support-mediated restore; archived permanently after
  the 7-day window (no self-serve "Undo" button in the app)
- The destructive nature is communicated in the dialog ("This archives
  X and stops all monitoring. Activity history is preserved.")

**US-33.** As Care Staff, **destructive actions** (Discontinue
Device, Discharge Resident) are visually distinct (warn-red accent) and
require explicit confirmation so that I don't trigger them by accident.

- Action button is red; menu row label is red
- A reassurance line states what is preserved vs. what is lost
- No double-confirm modal needed (the confirm modal *is* the
  destructive page)

**US-34.** As Care Staff, all resident-lifecycle actions are
reached from **one consistent settings menu** (the gear icon next to
the resident name) so that I don't hunt for them across screens.

- Menu is grouped: Device actions on top, Resident actions below
- Each row shows icon + label + one-line subtitle + chevron

---

### 4.6 Device Management

> See **Appendix C** for the device's five-state lifecycle
> (`ready_to_provision` → `provisioned` → `active_monitoring` →
> `discontinued` → `decommissioned`) and how the user-facing actions
> below map onto state transitions.

**US-35.** As Care Staff, I can **replace a resident's device**
with a new one and a reason (damaged / battery worn / upgraded model /
lost or misplaced / other) so that I can continue to monitor their
mobility through a hardware change.

- Current device ID is shown as a read-only chip before the form
- New device ID must match `GS` + 10 digits
- Replacement is **transparent to the resident's activity history**
  (no gap, no duplicate, no rebaseline)
- Old device is automatically released and available for re-assignment

**US-36.** As Care Staff, I can **discontinue a resident's
device** without discharging the resident so that I can keep the
resident in the system while their walker is out for repair.

- Resident stays in the Census but is marked as without a device
- Notifications related to activity are suppressed (no data to
  notify on)
- I can assign a new device any time via Replace Device

**US-37.** As Care Staff, I can see the **device serial, battery
level, cellular signal, last data received, and firmware version** for
any resident's assigned device so that I can troubleshoot connectivity
issues without leaving the portal.

- Device-health card is on the resident detail view
- Tapping into the card opens a dedicated device screen with full
  diagnostics

---

### 4.7 Multi-Facility / Multi-Unit Organization

**US-38.** As an Administrator overseeing multiple facilities, I can
**see residents across all facilities or filter to just one** so that I
can audit at the corporate level or zoom into a single site.

- Default scope is "all facilities I have access to"
- Unit filter spans facilities; selecting a unit implicitly scopes to
  its facility

**US-39.** As Care Staff working across multiple units within a
facility, the **Unit selector** shows every unit I'm authorized for so
that I can switch context without re-logging in.

---

### 4.8 Responsive Use

**US-40.** As any user, I can use the portal on my **phone** (390–430
px width) so that I can triage from the hallway without going to a
workstation.

- All primary actions (filter, sort, open resident, acknowledge
  notification) are reachable without horizontal scroll
- The detail view drops into a full-screen page on phone (not an
  overlay)

**US-41.** As any user, I can use the portal on a **tablet** (~744 px)
so that I can carry it on rounds.

**US-42.** As any user, I can use the portal on **desktop** so that I
get the fullest information density during shift handoffs or
end-of-day reviews.

---

### 4.9 Identity & Personalization

**US-43.** As a signed-in user, I can see **my name and role indicator**
(care staff / caregiver) in the header so that I'm sure I'm logged into
the right account.

---

## 5. Cross-Cutting Requirements

### Performance
- Census loads within 2s at facility-typical sizes (50–100 residents)
- Resident detail loads within 1s once Census is loaded
- Time-range toggle (24H/7D/30D/6M) re-renders charts within 300 ms

### Privacy & data handling
- Resident PII is never embedded in URL parameters or query strings
- Historical activity is preserved across discharge for the retention
  window defined in §7
- The portal is not a HIPAA-covered system in V1 (no PHI other than
  identifying name + room); decision and BAA path tracked separately

### Accessibility
- Color is never the sole carrier of meaning (tier colors and severity
  always pair with text or icon)
- Text contrast meets WCAG AA against the warm-white background
- Census filters, sort, and resident rows are reachable via keyboard
  tab order
- Screen-reader labels exist for the gear icon, notification badges,
  and chart tooltips

### Data freshness & time
- "Today" / "now" comparisons use the **facility's local time zone**,
  not the user's browser time
- "Last data received" surfaces in absolute time on the device-health
  card to avoid ambiguity across shifts
- Trend computations document their windows (e.g., "Active minutes
  trend = 7-day mean vs. prior 7-day mean")

### Reliability
- Network failures during a write action (acknowledge, edit, discharge)
  show a retry, not a silent failure
- Refreshing the page returns me to the same Census state (filter,
  sort, view mode) when possible

### Auditability
- **Every lifecycle action is logged** to an immutable audit row in
  V1: who, when, what action, before/after values, originating IP
- Covered actions: Add Resident, Edit Resident Info, Pause/Resume
  Notifications, Discharge, Restore (support-mediated), Replace
  Device, Discontinue Device, Acknowledge Notification, edit Care Note
- **No UI in V1** — write-side only. V2 adds a per-resident
  audit view. Backfilling history later is impossible, so we start
  logging from day one.

### Forward compatibility
To keep V1 cheap and the V3 family-member portal cheap to add:
- The auth model retains the `isCaregiver` role flag (no UI yet)
- Resident-scoped views render correctly given a single-resident
  context — no implicit dependency on the Census being loaded
- The data layer does **not** assume "current user has access to
  every resident in the facility" — resident lookup is always
  permission-checked, even when the user is currently in V1's
  full-facility view

### Device identifier format
- All device serials are `GS` + 10 digits (e.g., `GS0000000123`).
  One format end-to-end: firmware, AWS data layer, portal forms,
  RMA/packing-slip systems. No bare 10-digit IDs anywhere.

---

## 6. Explicitly Out of Scope (V1)

The following are deliberately deferred to keep V1 focused; they're
tracked so we don't lose them.

- **Tip-over / fall-event alerts** (sensor + ML, V3)
- **Per-resident alert threshold customization** (defaults only in V1)
- **Care team / family contact management** (which staff member is the
  primary nurse for a resident, who gets paged)
- **External notification routing UI** — V1 is in-app only. V2 adds
  daily email digests at shift change; V3 adds push notifications
  (mobile app required) and critical-only SMS. See §7 #6.
- **Activity export** (CSV / PDF for medical records, V2)
- **Multi-resident comparison** view (side-by-side trend charts)
- **Audit log viewing UI** — V1 logs every lifecycle action silently
  (see §5 Auditability); a per-resident audit view ships in V2
- **Self-serve "Undo" for discharge** — V1 uses support-mediated
  restore within 7 days; no in-app undo button (see §7 #11)
- **Real-time device commands** (remote LED indicator, "find walker"
  alert)
- **Photo upload** for resident records
- **Clinical fields** (DOB, sex, medications, allergies, diagnoses,
  fall-risk score) — V1 carries only what the activity dashboard needs
- **Family member portal** (read-only resident view for outside
  caregivers) — V1 reserves three architectural guardrails so V3
  can add this cheaply; see §5 Forward Compatibility and §7 #10.

---

## 7. V1 Decisions Log

The original Open Questions were resolved in working-session prep
(2026-05). Decisions and rationale below. Bring these forward into
V2 planning when relevant.

1. **Permission model — single role for V1.** All authorized facility
   users (CNA, floor nurse, DON, facility director) are "Care Staff"
   and can perform every action: read, acknowledge, pause
   notifications, add / edit / discharge residents, replace /
   discontinue devices. Role gating (Admin vs. Care Staff) is reserved
   for V2 once real customer feedback justifies the split. **See
   Appendix B** for the full forward-looking role model (six customer
   roles + two internal) and a capability matrix mapping each action
   to the role(s) that will be permitted.

2. **Discharge data retention — 7 years default in V1.** Matches the
   SNF compliance window. V2 adds facility-configurable retention,
   overridable **upward only** (never below regulatory minimum).
   Activity history is preserved across discharge in all cases.

3. **Pause Notifications (renamed from "Pause Monitoring").** Monitoring
   continues; only notifications are paused. Auto-resumes when the
   timer expires **or** when activity data starts streaming again
   mid-pause (whichever comes first). Census tiles show a paused-bell
   icon; resident detail shows a countdown banner ("Notifications
   paused — 4 days remaining"). Smart debounce on the underlying
   "No activity" rule (§4.4 US-22) also reduces the noise this was
   primarily added to solve.

4. **Replace Device — continuous personal baseline.** A device swap
   never resets a resident's activity baseline. Their body and walking
   patterns don't change because the hardware changed. Prevents
   spurious "below typical" alerts on Day 1 of a new device.

5. **Discharge vs. Discontinue — Discharge auto-releases the device.**
   No two-step destructive flow. Discharging a resident with an
   assigned device automatically releases the device to the unassigned
   pool (transitions to `discontinued` per Appendix C). Discontinue
   Device remains as a separate action for "keep resident, retire the
   walker."

6. **Notification delivery channels.**
   - **V1**: in-app only (current demo behavior)
   - **V2**: daily email digest sent at start of shift
   - **V3**: push notifications (requires a mobile app) + SMS for
     critical-severity only
   Email-per-notification is rejected — too noisy.

7. **"Today" boundary — wall-clock midnight in facility local time.**
   Shift-aware boundaries (e.g., 06:00 to 06:00) were rejected: they
   create more confusion than they solve and break the meaning of
   "yesterday" for families and external auditors. A shift-aware view
   can be added separately if needed; it shouldn't redefine "today".

8. **Device ID format — `GS` + 10 digits everywhere.** Matches
   production firmware. Update the demo to enforce the `GS` prefix.
   One format end-to-end avoids data migration headaches when the live
   API comes online.

9. **Multi-tenancy / Clients — single Client per user in V1.** The
   Client tier exists in the data model (corporate operators owning
   multiple facilities) but the V1 portal assumes one Client per
   signed-in user. Corporate-admin (spans Clients) is a V2 feature
   once a real multi-property operator signs.

10. **Family-member portal — reserve the door, don't build.** Three
    architectural guardrails in V1 keep the V3 family portal cheap to
    add: (a) `isCaregiver` role flag stays in the auth model, (b)
    resident-scoped views render correctly given a single-resident
    context, (c) the data layer never assumes "user has access to all
    residents in their facility" — every resident fetch is permission-
    checked. See §5 Forward Compatibility.

11. **Soft-undo for discharge — support-mediated restore within 7 days.**
    No self-serve "Undo" button in the app (would make discharge too
    casual). The discharged record sits in a recoverable state for 7
    days; internal support tooling can restore. After 7 days, archived
    permanently per the retention policy.

12. **Audit log — yes, silently in V1.** No UI. Every lifecycle action
    writes an immutable audit row from day one. See §5 Auditability
    for the full list of covered actions. V2 adds a per-resident
    audit view. Backfilling history later is impossible, so we start
    logging now.

### Decisions still pending (raised during prep, defer to working session)

*None at the time of writing.*

### New requirements that emerged from prep

- **Care Note** at the top of resident detail (§4.3 US-44) —
  emerged from the Q3 discussion as a lighter-weight alternative to
  Pause Notifications for annotating activity gaps. Kept Pause and
  added the note.
- **Smart debounce** on the No-Activity rule (§4.4 US-22) — emerged
  as a complement to Pause Notifications to reduce day-over-day
  alert noise.

---

## Appendix A — Story Index

| ID | Title |
|----|-------|
| US-01 | Sign in |
| US-02 | Sign out |
| US-03 | See all residents (Census) |
| US-04 | Switch List ↔ Tile view |
| US-05 | Filter Census by notification status |
| US-06 | Sort Census |
| US-07 | Filter Census by Unit (multi-select) |
| US-08 | See resident count |
| US-09 | List view metrics (10 columns) |
| US-10 | Color-tiered values |
| US-11 | Column header tooltips |
| US-12 | Responsive Census table |
| US-13 | Consistent tile sizing |
| US-14 | Notification summary on tiles |
| US-15 | Open resident detail |
| US-16 | Resident header (name + unit + room) |
| US-17 | Today's activity tile |
| US-18 | Trend charts (24H / 7D / 30D / 6M) |
| US-19 | Gait speed chart |
| US-20 | Device health card |
| US-21 | Return to Census |
| US-22 | Notification generation (3 rules) |
| US-23 | Notification severity |
| US-24 | Notification badge on Census |
| US-25 | Notification review panel |
| US-26 | Acknowledge + Save Note |
| US-27 | Acknowledged clears from active |
| US-28 | Add Resident |
| US-29 | Edit Resident Info |
| US-30 | Cross-facility transfer via Edit |
| US-31 | Pause Notifications (renamed from Pause Monitoring) |
| US-32 | Discharge Resident |
| US-33 | Destructive actions visually distinct |
| US-34 | One settings menu for lifecycle |
| US-35 | Replace Device |
| US-36 | Discontinue Device |
| US-37 | Device diagnostics on detail view |
| US-38 | Multi-facility filtering |
| US-39 | Cross-unit access |
| US-40 | Phone responsive |
| US-41 | Tablet responsive |
| US-42 | Desktop responsive |
| US-43 | Identity in header |
| US-44 | Care Note on resident detail |

---

## Appendix B — User Roles & Access (forward-looking model)

> **V1 reminder.** In V1, all signed-in facility users share the same
> permissions (see §7 #1) — effectively the union of `caregiver` +
> `facility_admin` capabilities scoped to one client. The model below
> is the full RBAC defined in
> [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) §4 and
> [`specs/phase-0a-revision.md`](specs/phase-0a-revision.md), which V2
> will layer in. V1 architectural decisions (see §5 Forward
> Compatibility) keep this expansion cheap.

Access is modeled in two tiers:

- **Customer tier** — anyone tied to a Client (a facility chain or a
  D2C household). All access scoped to that Client.
- **Internal tier** — GoSteady staff. Operate outside any customer
  tenancy, in the reserved `_internal` Client. Always MFA-required;
  every action is elevated-audit.

### Customer roles

| Role | Typical persona | Scope of access | Write? | MFA | Self-signup |
|------|------------------|-----------------|--------|-----|-------------|
| `patient` | Walker user with their own login (rare in MVP) | Own activity only | Self-only edits (e.g., own care notes) | Optional | Yes (then needs household setup) |
| `family_viewer` | Grandson, daughter, family caregiver | Specific patient(s) listed in `linkedPatientIds` | None — read-only | Optional | No — invited by `household_owner` |
| `household_owner` | D2C primary signer (often a family member setting up for a relative; sometimes the patient themselves) | Full admin within their synthetic household client | Full | **Optional** (softer than enterprise — reduces D2C signup friction) | Yes (D2C path) |
| `caregiver` | CNA, aide, floor nurse | One or more **censuses** within one **facility** | Full within scope | Optional | No — admin-created |
| `facility_admin` | Director of Nursing, ED | All censuses in one **facility** + facility-wide admin actions | Full within facility | **Required** | No — admin-created |
| `client_admin` | Regional director, COO | All facilities in their **Client** + cross-facility moves | Full across client | **Required** | No — admin-created |

### Internal roles (GoSteady staff)

| Role | Persona | Scope | Write? | MFA | Tenancy |
|------|---------|-------|--------|-----|---------|
| `internal_support` | Support, sales, account management | Read-only across all clients | None | **Required** | `_internal` (reserved) |
| `internal_admin` | Ops, on-call engineering | Full across all clients (including cross-client device moves) | Full + elevated audit | **Required** | `_internal` (reserved) |

Notes on the model:

- **One role per user** (architecture invariant — no "staff also family"
  cases). User belongs to exactly one client.
- **MFA is TOTP only** (Authenticator app). No SMS. See
  `phase-0a-revision.md` D5.
- **Token lifetimes differ by tier**: Customer client = 15-min idle /
  30-day refresh. Internal client = 30-min idle / 4-hr absolute cap.
- **Tenancy boundary is enforced at JWT layer** via custom claims
  (`clientId`, `role`, `facilities`, `censuses`) injected by the
  Pre-Token-Generation Lambda.

### Capability matrix — who can do what

Read this as: in V2+, which role(s) can perform each action.
Greyed-out entries (—) indicate "not permitted."

| Action | `family_viewer` | `caregiver` | `household_owner` | `facility_admin` | `client_admin` | `internal_admin` |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|
| View Census dashboard | own patients | scoped censuses | own household | full facility | full client | any client |
| Acknowledge Notification | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Edit Care Note (US-44) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Pause Notifications (US-31) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Add Resident (US-28) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Edit Resident Info (US-29) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Discharge Resident (US-32) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Provision Device (assign serial) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Replace Device (US-35) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| End-Assignment / Discontinue (US-36) | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Mark Device Lost / Broken | — | ✓ (scope) | ✓ | ✓ | ✓ | ✓ |
| Mark Device Retired / End-of-Life | — | — | ✓ | ✓ | ✓ | ✓ |
| Recover Lost Device | — | — | ✓ | ✓ | ✓ | ✓ |
| Force-Reset Stuck Device | — | — | — | ✓ | ✓ | ✓ |
| Cross-Facility Device Move | — | — | — | — | ✓ | ✓ |
| Cross-Client Device Move | — | — | — | — | — | ✓ (only) |
| Manufacturer bulk device creation | — | — | — | — | — | ✓ (only) |
| View Audit Log (V2+ UI) | — | — | own household | own facility | own client | any client |

`internal_support` reads everything in this table; writes nothing.

### How V1 maps onto this model

V1's single "Care Staff" role is the union of `caregiver` +
`facility_admin` for one Client/Facility:

- Scope: all residents in the facility (no census-level sub-scoping yet)
- All write actions in the matrix above are open to V1 users **except**
  cross-facility moves, cross-client moves, and bulk device creation —
  those land with the role split in V2.
- MFA is not yet enforced (would only apply to `facility_admin` role,
  which doesn't formally exist in V1).
- Internal-tier actions (manufacturer bulk creation, cross-client
  move) aren't reachable from V1 portal — they require the separate
  internal admin tool.

---

## Appendix C — Device Lifecycle States

> Devices (GoSteady walker caps) move through a **five-state
> machine** defined in
> [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) §4 and detailed in
> [`specs/phase-2a-device-lifecycle.md`](specs/phase-2a-device-lifecycle.md).
> All device serial numbers follow `GS` + 10 digits (e.g.,
> `GS0000000123`).

### State machine

```
                  ┌──────────────────────┐
                  │  ready_to_provision  │ ◄──── reset (firmware-driven on
                  └──────────┬───────────┘        charger when discontinued)
                             │ assign
                             ▼
                     ┌──────────────┐
                     │ provisioned  │
                     └──────┬───────┘
                            │ first message from device
                            ▼
                  ┌─────────────────────┐
                  │ active_monitoring   │
                  └──────────┬──────────┘
                             │ end assignment
                             ▼                                ┌──── reset
                     ┌──────────────┐                         │
                     │ discontinued │ ────────────────────────┘
                     └──────┬───────┘
                            │ decommission (with reason)
                            ▼
                  ┌─────────────────────┐
                  │   decommissioned    │ — terminal
                  └─────────────────────┘    (only `lost` is recoverable)
```

### States

| State | What it means | How you enter | How you leave |
|-------|---------------|---------------|---------------|
| `ready_to_provision` | In inventory pool. Either fresh from manufacturer (no owner yet) or returned post-reset (owner preserved). Available to be claimed/assigned. | Manufacturer bulk creation (no owner); OR firmware reset-complete on charger from `discontinued`; OR admin `recover` from `decommissioned (lost)` | Provision to a patient → `provisioned` |
| `provisioned` | Assigned to a patient; cloud has issued an activation command and is waiting for the device's first message. | `provision` API call from `ready_to_provision` | First device heartbeat → `active_monitoring`; OR `end-assignment` → `discontinued`; OR `decommission` → `decommissioned` |
| `active_monitoring` | Assigned + cloud has received ≥1 message. The steady-state — this is what most devices look like most of the time. | First device heartbeat after provisioning | `end-assignment` → `discontinued`; OR `decommission` (with reason) → `decommissioned` |
| `discontinued` | Patient assignment ended; physical device awaits retrieval and reset by staff. | `end-assignment` from `provisioned` or `active_monitoring`; OR auto-cascade when a patient is discharged (§7 #5) | Firmware reset-complete on charger → `ready_to_provision`; OR `decommission` → `decommissioned`; OR admin `force-reset` if stuck → `ready_to_provision` |
| `decommissioned` | Terminal. Always paired with a `decommissionReason`. Will never be used again — except `lost`, which is recoverable. | `decommission` API call from any non-terminal state | Only `decommissioned (lost)` can be `recover`ed → `ready_to_provision`. All other reasons are permanent. |

### Decommission reasons

| Reason | Recoverable? | Who can set it | Use case |
|--------|--------------|----------------|----------|
| `lost` | **Yes** — admin can `recover` to `ready_to_provision` (audited) | `caregiver`+ | Cap missing from the facility; might turn up |
| `broken` | No — terminal | `caregiver`+ | Physically damaged beyond use |
| `retired` | No — terminal | `facility_admin`+ | Asset retired (fleet consolidation, etc.) |
| `end_of_life` | No — terminal | `facility_admin`+ | Beyond expected service life |

### Key invariants

These hold across V1, V2, and beyond.

- **Ownership is claimed at first provisioning.** A fresh
  manufacturer-side device record has `owningClientId` and
  `owningFacilityId` both NULL. The first provision call snaps
  ownership to the provisioning user's scope. Subsequent provisions
  re-use the existing owner.
- **Ownership persists through reset.** Reset clears the on-device
  patient cache and the cloud-side patient assignment **only** —
  never the ownership. To move a device between facilities you need
  `client_admin`; to move it between Clients you need `internal_admin`.
- **Patient discharge auto-ends device assignments.** Per §7 #5, the
  discharge cascade transitions any assigned devices to
  `discontinued`. Staff still physically retrieves and resets the cap.
- **No portal "reset" button.** The `discontinued → ready_to_provision`
  transition is firmware-driven, gated by the device being on its
  charger (the natural sanitization checkpoint). The closest portal
  action is `force-reset`, which is `facility_admin`+ only and
  elevated-audit; runbook in `docs/runbooks/force-reset-device.md`.
- **Every state transition writes an audit event** (§5 Auditability).
  Event types include: `device.claimed`, `device.assigned`,
  `device.activation_sent`, `device.activated`, `device.first_heartbeat`,
  `device.assignment_ended`, `device.decommissioned`, `device.recovered`,
  `device.reset_complete`, `device.force_reset`,
  `device.ownership_moved`. Internal-tier actions carry an
  `internal_access: true` tag at elevated severity.

### How V1 maps onto the lifecycle

V1's user-facing concepts collapse onto this model:

- **Add Resident → provision a device.** The Add Resident form's
  Device ID maps to a `provision` call: a `ready_to_provision` device
  is assigned to the new resident. (The demo is cosmetic; no actual
  device-registry call yet.)
- **Replace Device** = `end-assignment` on the old device + `provision`
  the new one. Activity history follows the resident, not the device
  (§7 #4 — continuous personal baseline).
- **Discontinue Device** = `end-assignment` (resident kept). Device
  goes to `discontinued`; staff physically retrieves it and the
  charger-driven reset cycles it back to `ready_to_provision`.
- **Discharge Resident** auto-cascades: any assigned device → `end-assignment` → `discontinued`. No two-step required (§7 #5).
- "Mark Lost / Broken / Retired / End-of-Life" surfaces as the
  **Decommission Device** action — not yet in V1 demo; planned for V2.
