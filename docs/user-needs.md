# GoSteady Facility Portal — User Needs

> **Status:** V1 working draft, generated from the live demo at
> [gosteady.co/facilitydemo](https://gosteady.co/facilitydemo/).
> Bring this to the cloud working session to confirm coverage,
> challenge assumptions, and resolve the open questions in §7.
> Story IDs (US-xx) are stable references for the working session.

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

- **Care Staff** (CNA, floor nurse, day-shift staff). Lives in the
  Census view; triages notifications; checks individual residents
  during rounds. Read-heavy.
- **Administrator** (Director of Nursing, facility director, fleet
  manager). All Care Staff capabilities plus resident lifecycle (add,
  edit, transfer, discharge) and device fleet (replace, discontinue,
  diagnose). Write-heavy at lower frequency.

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

**US-28.** As an Administrator, I can **register a new resident** in
the system with first name, last name, facility, unit, room, and device
ID so that they can start being monitored.

- The **device ID must be exactly 10 digits**; non-numeric input is
  rejected at the field level
- The **Unit dropdown is constrained by the Facility** I select; I
  cannot assign a resident to a unit that doesn't exist at their
  facility
- All fields are required
- Action is accessible from a primary "Add Resident" CTA in the top
  right of the Census header

**US-29.** As an Administrator, I can **edit a resident's name, unit,
and room** so that the record stays accurate as they move between
rooms or wings.

- Edit Resident Info is reached from a settings (gear) icon next to
  the resident's name on the detail view
- Unit dropdown includes units from all facilities (allowing
  cross-facility transfer in one operation)

**US-30.** As an Administrator, I can **transfer a resident from one
facility to another** via Edit Resident Info so that residents moving
between sister properties keep one continuous record.

- No separate "Transfer" action needed; Unit change covers it
- Activity history is unbroken across the transfer

**US-31.** As an Administrator, I can **pause monitoring** for a
resident for N days (1–90) with a reason (in hospital, at rehab
elsewhere, family visit / off-site, on vacation, other) so that the
team isn't paged about expected no-data days while the resident is
off-site.

- Activity tracking continues; only **alerts** are paused
- Default duration: 7 days
- Pause auto-expires (open question — see §7)

**US-32.** As an Administrator, I can **discharge a resident** with a
reason (transferred / moved home / hospital admission / deceased /
other) and optional free-text notes so that their record is archived
cleanly.

- Discharge **preserves activity history** for compliance and family
  inquiries
- Discharged resident is removed from the active Census
- The destructive nature is communicated in the dialog ("This archives
  X and stops all monitoring. Activity history is preserved.")

**US-33.** As an Administrator, **destructive actions** (Discontinue
Device, Discharge Resident) are visually distinct (warn-red accent) and
require explicit confirmation so that I don't trigger them by accident.

- Action button is red; menu row label is red
- A reassurance line states what is preserved vs. what is lost
- No double-confirm modal needed (the confirm modal *is* the
  destructive page)

**US-34.** As an Administrator, all resident-lifecycle actions are
reached from **one consistent settings menu** (the gear icon next to
the resident name) so that I don't hunt for them across screens.

- Menu is grouped: Device actions on top, Resident actions below
- Each row shows icon + label + one-line subtitle + chevron

---

### 4.6 Device Management

**US-35.** As an Administrator, I can **replace a resident's device**
with a new one and a reason (damaged / battery worn / upgraded model /
lost or misplaced / other) so that I can continue to monitor their
mobility through a hardware change.

- Current device ID is shown as a read-only chip before the form
- New device ID must be exactly 10 digits
- Replacement is **transparent to the resident's activity history**
  (no gap, no duplicate, no rebaseline)
- Old device is automatically released and available for re-assignment

**US-36.** As an Administrator, I can **discontinue a resident's
device** without discharging the resident so that I can keep the
resident in the system while their walker is out for repair.

- Resident stays in the Census but is marked as without a device
- Notifications related to activity are suppressed (no data to
  notify on)
- I can assign a new device any time via Replace Device

**US-37.** As an Administrator, I can see the **device serial, battery
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

---

## 6. Explicitly Out of Scope (V1)

The following are deliberately deferred to keep V1 focused; they're
tracked so we don't lose them.

- **Tip-over / fall-event alerts** (sensor + ML, V3)
- **Per-resident alert threshold customization** (defaults only in V1)
- **Care team / family contact management** (which staff member is the
  primary nurse for a resident, who gets paged)
- **External notification routing** (email, SMS, push) — the portal
  alerts you in-app only
- **Activity export** (CSV / PDF for medical records, V2)
- **Multi-resident comparison** view (side-by-side trend charts)
- **Audit log** of administrative actions (who discharged whom, who
  replaced what device)
- **Soft-undo / restore** for discharged residents
- **Real-time device commands** (remote LED indicator, "find walker"
  alert)
- **Photo upload** for resident records
- **Clinical fields** (DOB, sex, medications, allergies, diagnoses,
  fall-risk score) — V1 carries only what the activity dashboard needs
- **Family member portal** (read-only resident view for outside
  caregivers)

---

## 7. Open Questions for the Working Session

Bring these to the working session — each one is a decision that
materially shapes V1.

1. **Permission model.** Confirm the Care Staff vs. Administrator split:
   which roles can Add Resident, Edit Info, Replace Device, Discontinue
   Device, Discharge Resident, Pause Monitoring? The demo doesn't gate
   any of these.
2. **Discharge data retention.** How long do we preserve activity
   history after discharge — indefinitely, the compliance window
   (typically 7 years for SNF), or facility-configurable?
3. **Pause Monitoring auto-resume.** Does monitoring auto-resume after
   the N days elapse, or stay paused until manually unpaused? What if
   data starts streaming again mid-pause?
4. **Replace Device baseline.** When a device is replaced, does the
   activity baseline carry over (continuous personal baseline) or
   reset (treat as a re-baseline event)? Affects all "below typical"
   notifications immediately after a swap.
5. **Discharge vs. Discontinue ordering.** Can I discharge a resident
   while a device is still assigned, or do I have to discontinue
   first? UX should not require two destructive operations to remove
   a resident.
6. **Notification delivery.** V1 is in-app only. When and how do we
   add email/SMS/push? Does that need to be in V1 to be useful?
7. **"Today" boundary.** Is "today" wall-clock midnight in facility
   time, or a shift-aware boundary (e.g., 06:00 to 06:00)? Affects
   "No activity today" sensitivity.
8. **Device ID format.** Demo accepts a 10-digit numeric ID. Production
   serials are `GS` + 10 digits. Pick one and make the data model
   consistent.
9. **Multi-tenancy / Clients.** The architecture supports a Client
   tier above Facility (corporate operators owning multiple
   facilities). V1 portal: do users see one client only, or can a
   corporate admin span clients?
10. **Family-member portal.** Even though out of scope for V1, do we
    want to constrain V1 decisions to keep the door open? (auth model,
    read-only scoping, opt-in alert routing)
11. **Soft-undo for discharge.** Is the destructive flow truly
    one-way, or do we need an "undo within 24 hours" path?
12. **Audit log.** Compliance review needs this eventually. Should it
    start in V1 as background logging (even without a UI) so we have
    the data when we need it?

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
| US-31 | Pause Monitoring |
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
