# Adversarial code review — Office Daze

**Branch** `claude/desk-app-icon` · **Reviewed** 7 August 2026 · Swift 6.0, strict concurrency `Complete`, iOS 26.0, SwiftUI + SwiftData, Swift Testing.

**Method.** Ten independent reviewers, one per dimension, each required to open the actual files and produce a concrete failure scenario rather than a suspicion. Every finding was then handed to a separate adversarial agent whose brief was to *refute* it — default to refuted when uncertain. 67 findings were raised, **3 were refuted and dropped**, 64 survived. A final completeness critic swept for cross-layer defects the single-layer reviewers structurally could not see, and contributed 4 of the survivors. The four high-severity findings were re-verified by hand against the source.

---

## Verdict

The domain and store layers are genuinely good: 96.6% and 94.3% line coverage, dense design-rationale comments, a schema whose invariants are mostly thought through. There is no logging of any kind, `.gitignore` is correct, and there are no force-casts in production code. That is a better starting point than most.

The defects cluster in three places, and they are the three places the tests do not reach:

1. **Time.** `Day` is pinned to UTC by design, but four separate call sites bridge it to a local-timezone API — `DatePicker`, `UNCalendarNotificationTrigger`, `EKEvent`. Each bridge is an off-by-one-day or off-by-one-hour bug for someone.
2. **Write paths that don't tell anyone.** Saving an office doesn't refresh the geofence. Saving a booking doesn't reschedule the nudge. Eight `try? context.save()` calls discard the error and report success.
3. **Everything the tests can't see.** `Screens/` is 25.6% covered and holds 4,964 of 8,163 executable lines. `BookingScanner` and `Keychain` are at literal zero.

**The coverage requirement is not met: 45.33% against a ≥80% bar.**

---

## Measured facts

From an instrumented run (`xcodebuild test -enableCodeCoverage YES`), not estimates.

| Metric | Value |
|---|---|
| Tests | 220 in 21 suites, **all passing**, 4.75s |
| App target line coverage | **45.33%** (3,700 / 8,163) |
| Excluding `Screens/` | 75.9% (2,427 / 3,199) |
| Coverage measured in the scheme | **No** — `codeCoverageEnabled` absent from `OfficeDaze.xcscheme` |
| Compiler warnings | 8 × `result of 'try?' is unused`, 2 × deprecated `CLGeocoder` |

### Coverage by layer

| Layer | Covered | Lines | % |
|---|---:|---:|---:|
| Domain | 373 | 386 | 96.6% |
| Store | 467 | 495 | 94.3% |
| App root | 86 | 94 | 91.5% |
| DesignSystem | 425 | 530 | 80.2% |
| Arrival | 489 | 633 | 77.3% |
| Capture | 546 | 979 | 55.8% |
| Handoff | 41 | 82 | 50.0% |
| **Screens** | 1,273 | 4,964 | **25.6%** |
| **Total** | **3,700** | **8,163** | **45.3%** |

### Files at or near zero

`BookingScanner.swift` 0% (243 lines) · `Keychain.swift` 0% (45) · `CameraPicker.swift` 0% (33) · `Geocoding.swift` 0% (12) · `BookingDetailScreen` 0% (390) · `OfficeEditorScreen` 0% (468) · `ArrivalPreviewScreen` 0% (367) · `LeaveScreen` 0% (307) · `AttendanceEditorScreen` 0% (157) · `CaptureSheet` 0.9% (797) · `SettingsScreen` 2.2% (602) · `BookingEditorScreen` 9.6% (272) · **`ArrivalMonitor` 25.6%** (156) · `CalendarWriter` 50% (82) · `HaikuClient` 59.2% (179)

Two of those are not view code. `BookingScanner` is the live camera path and `Keychain` is where the Anthropic API key lives; both are untested. `ArrivalMonitor` at 25.6% is the geofence engine.

---

## Test lenience — the `any()` / `lenient()` audit

There is no Mockito in Swift, so the reviewers hunted the behavioural equivalents. **Seven instances found.** The headline one is a true `any()`:

**`OfficeDazeTests/CaptureCoordinatorTests.swift:28` — argument-blind stub.** The fake extractor returns its canned bookings regardless of *which image* and *which date* it is handed. Two of three arguments are unchecked. Concretely: change `CaptureCoordinator.receive` to pass the original camera bytes instead of the prepared/downscaled ones, and the entire 462-line suite stays green while the app ships full-resolution images to a paid API.

**`OfficeDazeTests/QuotaTests.swift:291` — a literal tautology.** `#expect(early.shortfall == early.shortfall)`. The cross-month invariant it claims to check is never checked; the assertion is true by construction.

**`OfficeDazeTests/CaptureTests.swift:371` — vacuous test.** `heicIsTranscoded` returns early when its fixture comes back empty, having asserted nothing, and stays green forever.

The other four are over-broad assertions (`!= nil` where the exact bytes are knowable), partial-model coverage in the wipe tests, and locale-dependent hardcoded decimal points that would go red on a French CI runner. Full detail below.

**Non-determinism forcing lenience:** several suites use the real `Calendar.current` / `TimeZone`, which is exactly what makes the timezone family of bugs invisible to them.

---

## Refuted — raised, then dropped

Recorded so they are not re-raised. Each was killed by the adversarial pass.

- **No schema versioning behind `try!`** (`Store.swift:10`, `OfficeDazeApp.swift:23`) — raised twice. Refuted because the failure is contingent on a code change not yet made, the `try!` is documented as deliberate and staged (`OfficeDazeApp.swift:6`), and every stored property in `Models.swift` carries a default value, which is the SwiftData idiom that keeps lightweight migration viable. The residual risk (a corrupt store traps at launch) is real but rare and consciously accepted. **Worth revisiting before the first App Store update, not now.**
- **Capture sheet presented while `fullScreenCover` is still dismissing** (`HomeScreen.swift:162`) — the code is as described, but the presentation race could not be demonstrated.

---

## Recommended order of work

1. The four **high** findings — all are wrong-data-the-user-acts-on, all verified by hand.
2. The timezone family (`Day.swift:44`, `SettingsScreen.swift:144`, `CalendarWriter.swift:62`, `BookingEditorScreen.swift:84`) — one root cause, four call sites.
3. Turn on `codeCoverageEnabled` in the scheme so the number stops being invisible.
4. Fix the seven lenient tests *before* writing new ones — a suite that cannot fail is worse than no suite, and adding coverage on top of argument-blind fakes inflates the number without adding safety.
5. Cover `BookingScanner`, `Keychain`, `ArrivalMonitor`, `HaikuClient`. These four alone are ~620 uncovered lines of non-view logic and are the shortest path toward 80%.

---

# All findings

64 unique findings, ordered by severity. Duplicates found by two reviewers are merged.


## HIGH

### 1. The evening nudge repeats daily with frozen content, so "I was there" records attendance against the wrong day

**`OfficeDaze/Arrival/EveningNudge.swift:132`** — correctness — found by: robustness-misc — confidence: certain

`EveningNudge.request` bakes the decision's *content* into a `UNCalendarNotificationTrigger(repeats: true)` — including the literal day (`unconfirmed.day.description`) in `userInfo`, the office name, the desk id, and the shortfall/date strings in the body. iOS then redelivers that identical notification every day at the chosen time for as long as it stays pending. The only thing that re-bakes it is `NudgeScheduler.refresh`, and every one of its call sites requires the app to be awake: `OfficeDazeApp`'s `.task` (which runs once per *process launch* — there is no `scenePhase` observer anywhere in the app, I grepped), the Settings toggles, `HomeScreen.answered()`, and the notification-response handler. An iOS app that stays resident goes days without re-running that `.task`. So the pending nudge outlives its facts. The `confirmToday` branch is the dangerous one: its buttons feed `ArrivalMonitor.didReceive`, which reads the *baked* `UserInfo.day` and passes it to `ledger.confirmAttendance(officeID:day:bookingID:)`, and `BookingStore.recordAttendance` only guards `day <= today` — a stale past day sails through. The `bookTomorrow` branch is merely wrong rather than destructive: it will announce a date in the past, on a Saturday, with a shortfall figure from last week. The file's own doc comment anticipates the *decision* going stale and says the app re-evaluates on launch; it does not anticipate the *content* going stale, and 'on launch' is far rarer than the comment assumes.

**Failure scenario.** Monday 08:00 the user opens the app; `refresh` sees an unconfirmed Coleman booking for Monday and schedules the nudge with `userInfo[day] = "2026-08-10"`, title "Were you at Coleman today?". The user ignores Monday's 18:00 alert and does not reopen the app. Tuesday 18:00 the identical notification fires again — same title, same "Desk 3C-114 was booked for today" body, same frozen `day` value. The user, who was at Coleman on Tuesday, taps "I was there". `confirmAttendance` writes an `AttendanceDay` for **Monday 10 August**, a day they were not there; Tuesday is still unrecorded. Attendance is described throughout this codebase as the only record that a day was worked, with no other copy.

```swift
trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
```

**Fix.** Do not repeat a request whose content is day-specific. Either (a) schedule a non-repeating `UNCalendarNotificationTrigger` for the next occurrence only and re-arm it from the response handler and from a `scenePhase == .active` observer, or (b) keep the repeating trigger but strip every day-specific fact from it — no baked date string, no baked `bookingID`/`day` in `userInfo`, no shortfall number — and have the response handler resolve "the unconfirmed day" from the store at tap time rather than from `userInfo`. At minimum, add a `scenePhase` observer that calls `NudgeScheduler.refresh` on every foreground, not just on process launch.

**Verifier's correction.** One scope note worth adding, not a change to the verdict: NudgeScheduler.isEnabled reads UserDefaults.standard.bool, which defaults to false, so this only reaches users who have deliberately turned the evening reminder on in Settings. That narrows the blast radius but does not change the failure — and the notification-response handler does call NudgeScheduler.refresh (ArrivalMonitor.swift:199) *after* the bad write, so the app self-corrects going forward while leaving the wrong AttendanceDay in place.

---
### 2. The evening nudge repeats daily with frozen content, so "I was there" records attendance against the wrong date

**`OfficeDaze/Arrival/NudgeScheduler.swift:92`** — correctness — found by: arrival-handoff — confidence: certain

`EveningNudge.request` builds a `UNCalendarNotificationTrigger(repeats: true)` under one fixed identifier, and the `.confirmToday` branch bakes a specific `day` and `bookingID` into `content.userInfo`. The trigger repeats; the payload does not. The header comment acknowledges the decision must be re-made at fire time "which is why the app re-evaluates and withdraws on launch" — but the same file argues the schedule repeats precisely because "the app is not running most evenings". Those two things cannot both be true: on any evening the app was not opened, iOS re-delivers yesterday's question, still worded "today", still carrying yesterday's day in userInfo. `ArrivalMonitor.userNotificationCenter(_:didReceive:)` reads that stale `day` and passes it straight to `ledger.confirmAttendance(officeID:day:bookingID:)`, and `BookingStore.recordAttendance`'s only date guard is `day <= today`, which a stale past day passes. The `.bookTomorrow` branch has the same defect in a benign form: it re-delivers a fixed shortfall and a fixed date string ("Mon 10 August is a working day") on every subsequent evening.

**Failure scenario.** Wed 5 Aug 2026: user opens the app; a Coleman desk is booked for the 5th with no attendance, so `refresh` schedules "Were you at Coleman today?" with `userInfo[day] = "2026-08-05"`, `bookingID = B`. The nudge fires at 18:00 and the user swipes it away without answering, and does not open the app. Thu 6 Aug 18:00: the same pending request fires again, unchanged — "Were you at Coleman today?" The user was in fact at Coleman on the 6th, so they tap "I was there". The handler calls `confirmAttendance(officeID: coleman, day: 2026-08-05, bookingID: B)`; `recordAttendance` passes `2026-08-05 <= 2026-08-06`, finds no existing row, and inserts an `AttendanceDay` for **5 August**. Thursday the 6th — the day actually worked and actually answered for — is recorded nowhere. One tap puts two days of the monthly count wrong, in the record the app itself describes as "the only copy there is".

```swift
case .confirmToday(let unconfirmed):
            let message = EveningNudge.confirmMessage(unconfirmed)
            schedule(EveningNudge.request(
                at: time, title: message.title, body: message.body,
                answering: unconfirmed
            ))
            return true
```

**Fix.** A repeating trigger cannot carry day-specific state. Two options, both cheap:
1. Keep the repeat only for the generic `.bookTomorrow` copy (which names no day), and schedule `.confirmToday` as a one-shot `UNCalendarNotificationTrigger(repeats: false)` for tonight only — a question about a specific day should not outlive that day.
2. Whatever the trigger, make the handler refuse a stale answer. `ArrivalMonitor.didReceive` already has the day; gate it: `guard day == Day.today || day == Day.today.adding(days: -1) else { NudgeScheduler.refresh(in: context); return }` — the previous day is worth allowing because the nudge can be tapped after midnight, but nothing older is an answer to the question being displayed.
Option 2 alone stops the data corruption; both together also stop the misleading copy.

---
### 3. `Quota.attended` sums per-row fractions while the same function treats attendance as a set of days, so one day worked at two offices counts as two days

**`OfficeDaze/Domain/Quota.swift:166`** — correctness — found by: domain-logic — confidence: certain

`attended` is `reduce` over `input.attendance`, one term per row, with no collapse by `Day`. Three lines later the same function builds `attendedDays = Set(input.attendance.map(\.day))` and uses it to de-duplicate `forecast` and `daysAvailable` — so inside a single function attendance is a *sum of rows* in one place and a *set of days* in the other, and the two disagree the moment a day carries more than one row. The code takes explicit care about exactly this elsewhere (`deskBookingDays.union(plannedDays)`, documented as "a day both booked and planned is one day rather than two"); the same care is not applied to attendance.

More than one row per day is a supported store state, not a corruption. `BookingStore.recordAttendance` (OfficeDaze/Store/BookingStore.swift:234) rejects a duplicate only on the `(day, officeID)` pair, and `AttendanceEditorScreen.alreadyRecorded` (OfficeDaze/Screens/AttendanceEditorScreen.swift:39) checks the same pair, so nothing anywhere blocks a second row for the same date at a different office. `QuotaService.snapshot` (OfficeDaze/Store/QuotaService.swift:40) maps every fetched row straight into a `DayFraction` with no grouping. `ArrivalLedger` already knows the invariant should be day-level — it suppresses its notification with `snapshot?.attendedDays.contains(day)` (OfficeDaze/Arrival/ArrivalLedger.swift:96) — but the store below it does not enforce it.

**Failure scenario.** User has two offices configured (the seeded shape: Coleman London and Brussels). On 5 August 2026 they open "Day in the office", pick Coleman and 5 August, save. Realising they picked the wrong office, they open it again, pick Brussels and 5 August, and save. `alreadyRecorded` is false both times (different `officeID`), the footer says "A day you were there counts toward the month...", and `recordAttendance`'s duplicate guard does not fire. Two `AttendanceDay` rows now exist for 5 August, fraction 1.0 each. `Quota.calculate` returns `attended == 2.0` for one day on prem, `shortfall` one day too low, and `attendedDays.count == 1` so `daysAvailable` only gives back one day. The gauge draws two solid days and the label reads "2 of 8". With seven real days on prem plus one double-counted day, `attended == 8 >= target` and `standing` returns `.met` — the strip says "Target met" on seven days worked, which is the precise conflation the AttendanceDay/DeskBooking split and the four-state `Standing` enum were built to prevent.

```swift
let attended = input.attendance
            .filter { month.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }
        let attendedDays = Set(input.attendance.map(\.day))
```

**Fix.** Collapse to one fraction per day before summing, and cap it at a whole day, so `attended` and `attendedDays` can never disagree:

```swift
let perDay = input.attendance
    .filter { month.contains($0.day) }
    .reduce(into: [Day: Double]()) { $0[$1.day, default: 0] += $1.fraction }
let attended = perDay.values.reduce(0) { $0 + min(1, $1) }
let attendedDays = Set(input.attendance.map(\.day))
```

(Whether two half-days at two offices should sum to one whole day or be capped is a product call, but summing two whole days into 2.0 is not defensible either way.) Independently, `BookingStore.recordAttendance` should key its duplicate guard on `day` alone, matching `ArrivalLedger`'s day-level `alreadyRecorded` check.

**Verifier's correction.** Two corrections to the statement, neither of which changes the verdict.

(1) The reviewer's implied fix — collapse attendance to `Set(day)` the way `forecast` does — would itself be wrong. Two 0.5 rows on the same day at two different offices (morning at one site, afternoon at another) currently sum to 1.0, which is correct; a set-of-days collapse would make that day worth 0.5. The actual invariant is that the total fraction *per day* must be clamped to 1.0 (e.g. group by day, sum, then `min(1.0, ...)`), not that a day contributes exactly one.

(2) The most reachable trigger is not the manual editor but the arrival notification: arrive at a second office on a day already recorded, tap "I'm here", and `attended` gains a whole extra day — while ArrivalNotifications.swift:59-60 explicitly tells the reader the button "will no longer move it". Cite that path as the primary failure scenario.

---
### 4. An attendance record for a day that has a desk booking can never be deleted, because the row that carries the delete is filtered out

**`OfficeDaze/Screens/HomeScreen.swift:93`** — correctness — found by: cross-cutting-critic — confidence: certain

`BookingStore.deleteAttendance` has exactly one caller in the whole app: `HomeScreen.delete(_:)` case `.attended` (HomeScreen.swift:761). That case can only fire for an `Entry.attended`, and `entries(...)` only produces an `.attended` entry when `!isBooked($0.day, $0.officeID)` — i.e. when no `DeskBooking` exists for the same day and office. So the moment a day has both a booking and an attendance record, the attendance row disappears from the list and its delete goes with it. Every other surface is read-only about it: `BookingDetailScreen` renders a non-interactive `StatusStrip("Attended — confirmed …")` when `attended != nil` and offers no removal; `RowMenu` on the booking row offers Edit (the booking) and Delete (the booking); `BookingStore.recordAttendance` refuses a second row for the same day+office, so it cannot even be re-recorded with a different `fraction`. This is precisely the common case — a booked day is exactly the day the geofence alert fires with a desk on it and an "I'm here" button, so a mis-tap lands here rather than on an unbooked day. The only escape is destructive and undiscoverable: delete the desk booking (which makes the `.attended` entry reappear), delete the attendance, then re-create the booking by hand.

**Failure scenario.** Seeded store, 5 August 2026: DeskBooking 3C-114 at Coleman plus an AttendanceDay for Coleman on 5 August. The user decides that day should not have counted (they mis-tapped "I'm here" on the arrival alert, or only dropped in for ten minutes). `entries(bookings:attendance:planned:in:)` computes `isBooked(5 Aug, colemanID) == true`, so the AttendanceDay is dropped from `attended` and never becomes an `Entry.attended`. The list shows one row — the booking, status "Attended". Long-press gives Edit and Delete, both of which act on the DeskBooking. The detail screen shows a static green strip. `deleteAttendance` is unreachable. The gauge goes on counting 5 August as a day on prem, against the number the whole app exists to report, with no way in the UI to correct it.

```swift
let attended = attendance.filter {
            month.contains($0.day) && !isBooked($0.day, $0.officeID)
        }
```

**Fix.** Give the booking row the same answer affordance the deskless rows have. Either add a `.attended`-aware action to `RowMenu` on a `.booking` entry ("Remove attendance" when `isAttended(booking)`), or put a destructive row on `BookingDetailScreen` beside the "Attended — confirmed …" strip that calls `BookingStore.deleteAttendance(attended, in: context)`. The same route also fixes the un-correctable `fraction`: deleting then re-recording is the only way to turn a half day into a whole one, and today the delete half of that does not exist.

---
### 5. Adding, moving or deleting an office never refreshes the monitored regions, so a new office's perimeter is not watched until the next cold launch

**`OfficeDaze/Screens/OfficeEditorScreen.swift:226`** — correctness — found by: arrival-handoff, robustness-misc — confidence: certain

`ArrivalMonitor.refreshRegions()` has exactly three call sites: `OfficeDazeApp`'s `.task` (once per cold launch — `.task` on the WindowGroup root does not re-run on foreground), `SettingsScreen.wipe`, and `didChangeAuthorization`. `OfficeEditorScreen.save()` and `delete()` are not among them, even though they are the only places offices are created, re-geocoded, re-radiused, or removed. `SettingsScreen.wipe` carries the comment "iOS goes on monitoring a perimeter for a deleted office until something tells it not to" — the hazard is understood, it is just not wired into the editor. Meanwhile `SettingsScreen.willFire(_:)` returns `alertEnabled && arrival.canMonitor && office.isLocated`, none of which consults `manager.monitoredRegions`, so the row confidently prints "Alert on · 50m" in the reassuring green for a perimeter CoreLocation has never been told about.

**Failure scenario.** User already has one office and has granted Always (so no authorization callback will fire again). They tap Settings › Add office, enter the second building, save; geocoding succeeds and `isLocated` is true. `refreshRegions()` is never called, so `CLLocationManager` is monitoring one region, not two. The Settings row for the new office reads "Alert on · 50m" in green. The user walks into that building the next morning and gets no alert. The same shape with an edit: correcting an office's address at 21:00 writes new coordinates but leaves the old `CLCircularRegion` in place, so until the app is cold-launched the alert fires at the previous building's perimeter and not the corrected one. Deleting an office leaves iOS waking the app on a perimeter that no longer belongs to anything (`handleEntry` returns `.disabled` on the missing office, so it is silent, but the wake-ups continue).

```swift
if editing == nil {
            context.insert(target)
            // Held, so a second Save after the not-located alert corrects this
            // office rather than inserting another one beside it.
            created = target
        }
        try? context.save()
```

**Fix.** Inject the monitor and refresh on both exits, exactly as `SettingsScreen.wipe` does:
```swift
@Environment(ArrivalMonitor.self) private var arrival
// ...end of save(), after try? context.save():
arrival.refreshRegions()
// ...end of delete(), after try? context.save():
arrival.refreshRegions()
```
`refreshRegions()` is already a wholesale rebuild and cheap at six offices, so calling it on every save is safe. Separately, `SettingsScreen.willFire` would be more honest if it also required the office id to appear in `manager.monitoredRegions`, which would have made this visible.

**Verifier's correction.** Same defect, slightly wider: OfficeEditorScreen.save() also changes `alertEnabled` and `radiusMetres`, both of which refreshRegions consumes (ArrivalMonitor.swift:91, :99), so turning an office's alert *off* in the editor likewise leaves iOS monitoring it until the next cold launch.

---
### 6. Evening reminder time is written in UTC but fired in local time, so it goes off an hour early all summer

**`OfficeDaze/Screens/SettingsScreen.swift:144`** — correctness — found by: arrival-handoff, robustness-misc — confidence: certain

`Day.calendar` is pinned to UTC (Day.swift:31). Extracting `[.hour, .minute]` from the DatePicker's `Date` with that calendar yields the UTC hour, not the hour the user saw. `EveningNudge.request` then hands those bare components to `UNCalendarNotificationTrigger(dateMatching:repeats:)`, which — with no `calendar`/`timeZone` set on the components — matches against the user's current calendar and time zone. So the number is captured in UTC and interpreted as local. The reload path in `.task` (lines 181-185) makes it invisible: it converts back through the same UTC calendar, so the picker redisplays the value the user typed even though the trigger will fire an hour off. Worse, the two ends disagree about the untouched default: `NudgeScheduler.time`'s fallback is `DateComponents(hour: 18)`, which fires at 18:00 local, but `.task` renders it through UTC and shows 19:00 — so a UK user opening Settings during BST sees a time an hour later than the reminder actually fires, and "correcting" it to 18:00 is what breaks it.

**Failure scenario.** UK user, 7 August 2026 (BST, UTC+1). Settings opens and the picker shows 19:00 even though the default fires at 18:00. The user drags it to 18:00. `Day.calendar.dateComponents([.hour,.minute], from:)` returns hour 17 (verified by running the exact arithmetic: "user picked 18:00 local -> stored hour 17"). `UNCalendarNotificationTrigger(dateMatching: DateComponents(hour:17, minute:0))` fires at 17:00 local. Reopening Settings redisplays 18:00, so nothing on screen ever admits the reminder is arriving at 17:00. Every user outside UTC is affected by their own offset; UK users are affected from late March to late October.

```swift
.onChange(of: nudgeTime) { _, new in
                        NudgeScheduler.time = Day.calendar.dateComponents(
                            [.hour, .minute], from: new
                        )
                        NudgeScheduler.refresh(in: context)
                    }
```

**Fix.** The nudge time is a wall-clock time in the user's own zone, not a Day-domain value, so it must not go through `Day.calendar`. Use `Calendar.current` on both the read and the write:

```swift
NudgeScheduler.time = Calendar.current.dateComponents([.hour, .minute], from: new)
```
and in `.task`:
```swift
nudgeTime = Calendar.current.date(from: components) ?? Date()
```
A regression test can assert the round trip without a device: `Calendar.current.dateComponents([.hour,.minute], from: picked).hour` must equal the hour the trigger will match. Belt and braces, set `time.calendar = .current` in `EveningNudge.request` so the trigger's interpretation is stated rather than inferred.

---


## MEDIUM

### 7. Notification authorization is requested only from the location permission row and its result is discarded, so the nudge can be silently dead with the UI claiming otherwise

**`OfficeDaze/Arrival/ArrivalMonitor.swift:51`** — correctness — found by: arrival-handoff — confidence: certain

This is the app's only call to `UNUserNotificationCenter.requestAuthorization` (verified by grep across OfficeDaze/ and OfficeDazeTests/). It discards both the granted flag and the error, and nothing anywhere reads `notificationSettings`. `requestAuthorization()` is reachable from exactly one place — `SettingsScreen.permissionRow` — which is rendered only when `!arrival.canMonitor && !offices.isEmpty`. So the notification prompt is coupled to the location prompt and to owning at least one office, while the evening reminder depends on neither. `NudgeScheduler.schedule` uses `UNUserNotificationCenter.add(_:)` without a completion handler, so a scheduling failure is not observable either. The result is a feature that can be fully switched on in the UI and completely inert.

**Failure scenario.** Two reachable paths. (a) A user who tracks attendance by hand and has added no offices opens Settings and turns on "Evening reminder". `permissionRow` is suppressed by `!offices.isEmpty`, so `requestAuthorization()` is never called and notification authorization stays `.notDetermined`. `NudgeScheduler.refresh` happily returns true and `add(_:)` swallows the outcome; no reminder ever arrives, and the toggle stays on forever with nothing on screen explaining it. (b) A user with offices taps "Allow", grants Always location but taps "Don't Allow" on the notification prompt that appears alongside it. `canMonitor` is now true, so `permissionRow` disappears and `alertText` prints "Alert on · 50m" in `Palette.met` green for every office — but no arrival alert can ever be delivered, and there is no longer any surface in the app that mentions notifications at all.

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        escalate()
```

**Fix.** Store the notification authorization status alongside `authorization` and let the UI read it:
```swift
private(set) var notificationsAllowed = false

func refreshNotificationStatus() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notificationsAllowed = settings.authorizationStatus == .authorized
              || settings.authorizationStatus == .provisional
}

func requestNotificationAuthorization() async {
    let granted = (try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])) ?? false
    notificationsAllowed = granted
}
```
Then (1) call `requestNotificationAuthorization()` when the Evening reminder toggle is switched on, independent of offices and location, and (2) fold `notificationsAllowed` into `SettingsScreen.willFire`/`alertText` so "Alert on" is not printed in green for an alert iOS will not deliver.

**Verifier's correction.** Uphold at medium rather than high. The strongest concrete instance is path (b): grant Always location, deny the notification prompt, and SettingsScreen.willFire (SettingsScreen.swift:240-242) still returns true so every office row prints "Alert on · <radius>m" in Palette.met green, with no surface anywhere in the app mentioning notification permission. Path (a) is reachable but requires an office-less user.

---
### 8. Files arriving through the share sheet are copied into Documents/Inbox and never deleted

**`OfficeDaze/Capture/CaptureCoordinator.swift:91`** — privacy — found by: security — confidence: likely

`Info.plist` declares `CFBundleDocumentTypes` for `public.image` and `com.adobe.pdf` but does not declare `LSSupportsOpeningDocumentsInPlace`. Without that key iOS always *copies* the shared document into the app's `Documents/Inbox/` before calling `onOpenURL` — and the documented contract is that the app owns those copies and must delete them. `receive(url:)` reads the bytes with `Data(contentsOf:)` and returns; there is no `removeItem`. I grepped all of `OfficeDaze/` for `FileManager`, `removeItem` and `Inbox` — zero hits, so nothing anywhere in the app cleans up. That means a second, unmanaged copy of every shared booking document accumulates in `Documents/`, which is exactly the directory that goes into iCloud/iTunes backups, and which `Store.wipe` ("Delete data…") does not reach either. The `startAccessingSecurityScopedResource` call at line 84 suggests the author expected out-of-container URLs; for the declared document-types path they are in-container and are the app's to remove.

**Failure scenario.** User shares 30 booking screenshots to Office Daze over a few months. `~/Documents/Inbox/` accumulates 30 files (`IMG_4021.PNG`, `IMG_4021-1.PNG`, … — iOS uniquifies rather than overwrites), each a picture of their employer's booking system, each in every iCloud backup, none removed by Settings → Delete data → Everything, and none visible or removable from inside the app. Share a 200MB PDF once and 200MB of it is permanently resident in the container.

```swift
func receive(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            phase = .failed(.unsupportedFile((url.pathExtension.isEmpty ? "file" : url.pathExtension)))
            return
        }
        await receive(data: data, filename: url.lastPathComponent)
    }
```

**Fix.** Delete the inbox copy once the bytes are in hand, on every exit path:

```swift
func receive(url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if url.isFileURL, url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }
    …
}
```

(Guarding on the Inbox path keeps it from deleting a genuinely in-place document should `LSSupportsOpeningDocumentsInPlace` ever be added.) A one-off sweep of `Documents/Inbox` at launch would clear what existing installs have already accumulated.

**Verifier's correction.** Narrow the exposure claim. With no UIFileSharingEnabled and no document browser, the Inbox copies are not reachable by other apps or by Finder — the demonstrable harm is unbounded growth of the app container, inclusion in every iCloud/iTunes backup, and survival of Settings → Delete data → Everything. Fix is one line in receive(url:) (try? FileManager.default.removeItem(at: url) after the read), or declaring LSSupportsOpeningDocumentsInPlace so iOS stops copying.

---
### 9. Abort during image preparation is not honoured: the cancelled capture re-arms itself, re-presents the sheet, and spends an API call

**`OfficeDaze/Capture/CaptureCoordinator.swift:121`** — concurrency — found by: capture-pipeline, concurrency-swift6 — confidence: certain

`run()` is carefully generation-guarded across both of its suspension points, and the comment on `generation` states exactly the bug it exists to prevent: "Cancel, then half a second later the sheet reappears holding bookings from a capture the user has already dismissed." But `receive(image:unreadableAs:)` has a *third* suspension point — `await Task.detached { PhotoImport.prepare(data) }.value` — and it is not guarded at all. `phase = .parsing(step: .received)` is set *before* that await, so the sheet is on screen and its Cancel button is live while the decode runs off-actor. `abort()` sets `generation += 1`, `phase = .idle`, `lastInput = nil`. When `prepare` then resumes, it unconditionally writes `lastInput = (prepared.data, prepared.mediaType)` and calls `await run()`, which reads the freshly-restored `lastInput`, bumps `generation` itself (so the abort's bump is irrelevant), and sets `phase = .parsing(step: .finding)`. Because `OfficeDazeApp` presents the sheet from `.sheet(isPresented: .init(get: { capture.isActive }, ...))`, `isActive` flipping back to true re-presents the sheet the user just dismissed. The existing regression test `abortDuringTheFloorStaysAborted` only holds the *extractor* at its suspension point, so it exercises the guarded path and passes while this one is open.

**Failure scenario.** User taps the camera button, `BookingScanner` hands back a 12MP JPEG, `receive(photo:)` -> `receive(image:)` sets `phase = .parsing(.received)` and the sheet animates in. `PhotoImport.prepare` (decode + 1568px downscale + JPEG re-encode of a ~5700px frame) runs off-actor for a few hundred milliseconds. The user taps Cancel in that window: `abort()` runs, `phase = .idle`, `lastInput = nil`, sheet dismisses. `prepare` then returns; `lastInput` is set again, `run()` fires, an ~0.4p Claude call goes out for an image the user cancelled, `phase` becomes `.parsing(.finding)` so the sheet slides back up, and on success it lands on `.review` holding bookings the user has already walked away from — which they may then save. `canRetry` is also true again after an abort that set it false.

```swift
phase = .parsing(step: .received)
        do {
            let prepared = try await Task.detached { try PhotoImport.prepare(data) }.value
            lastInput = (prepared.data, prepared.mediaType)
            await run()
```

**Fix.** Capture and re-check the generation across the preparation await, the same way `run()` does:

    private func receive(image data: Data, unreadableAs ext: String?) async {
        generation += 1
        let run = generation
        phase = .parsing(step: .received)
        do {
            let prepared = try await Task.detached { try PhotoImport.prepare(data) }.value
            guard run == generation else { return }
            lastInput = (prepared.data, prepared.mediaType)
            await self.run()
        } catch {
            guard run == generation else { return }
            phase = .failed(...)
        }
    }

(`run()` bumping the counter again is harmless — it only needs to be monotonic.) Add a test that holds `PhotoImport.prepare` rather than the extractor, e.g. by injecting the preparer the way `extractor` is injected.

**Verifier's correction.** Uphold as written on mechanism and reachability; downgrade severity from high to medium. The window is one off-actor image decode (~100-500ms) that opens while the sheet is still presenting, so the Cancel tap has to land inside it; the consequences are a wasted API call, a re-presented sheet, and `canRetry` flipping back to true — not data loss. The fix is the same one `run()` already uses: capture `generation` before the `await Task.detached { ... }.value` and `guard run == generation else { return }` before writing `lastInput` and calling `run()`.

---
### 10. A failed booking write during capture is swallowed and the sheet still marks the booking saved and advances

**`OfficeDaze/Capture/CaptureCoordinator.swift:265`** — error-handling — found by: robustness-misc — confidence: certain

`BookingStore.upsert` is declared `throws` precisely because `context.save()` can fail, but the capture path discards that with `try?` and then unconditionally executes `saved.insert(booking.id)` and `advance()`. The `saved` set is what drives the green segments in `CaptureSheet.header` and what `segments` reports, so a write that never landed is rendered to the user as a completed one, and the sheet moves on to the next booking with no way back. This is the sharpest instance of a repo-wide pattern — `try?` around every store mutation in `HomeScreen.answerYes/answerNo/delete`, `BookingEditorScreen.save/delete`, `AttendanceEditorScreen.save`, `OfficeEditorScreen.save/delete`, `LeaveScreen.toggle`, `SettingsScreen.wipe`, `ArrivalLedger.confirmAttendance` — such that there is no path in the app on which a failed persist produces any user-visible signal at all. `Keychain.write` has the same shape: the `SecItemAdd` return code is discarded, so a key that fails to store reports itself as saved.

**Failure scenario.** Device is out of storage (or SwiftData rejects the write for any reason) during a three-booking capture. The user taps "Save and next" on booking 1: `upsert` throws, `try?` eats it, the first progress capsule turns green, and the sheet advances to booking 2. The user finishes all three, sees three green segments and the sheet dismiss, and returns to a home screen with none of the three bookings on it — with nothing having told them anything went wrong.

```swift
try? BookingStore.upsert(
            BookingMerge.Candidate(
```

**Fix.** Make the failure visible where the user is already looking. `do { try BookingStore.upsert(...) } catch { phase = .failed(...) ; return }` — or add a `.saveFailed` case to the sheet — so `saved.insert`/`advance()` only run on a write that actually landed. Apply the same treatment at least to the destructive/irreversible mutations elsewhere (`Store.wipe`, `BookingStore.delete`, `recordAttendance`); a silently-dropped attendance write loses the one record with no other copy.

**Verifier's correction.** The claimed end-state is wrong and should be corrected. BookingStore.upsert calls context.insert(booking) *before* the throwing context.save() (BookingStore.swift:38-39), and SwiftData fetches — including @Query on the same mainContext — include pending unsaved changes. So the user does not "return to a home screen with none of the three bookings on it"; the bookings appear normally for the rest of the session and the loss only surfaces after the process is relaunched (or never, if a later successful save flushes the same pending changes). The defect is therefore silent, deferred data loss with no user-visible signal at any point, rather than an immediately visible disappearance — which is arguably worse to diagnose but less obvious than stated.

---
### 11. `day(from:)` accepts impossible calendar dates, which silently roll forward and defeat the one-desk-per-office-per-day rule

**`OfficeDaze/Capture/CapturedBooking.swift:172`** — correctness — found by: capture-pipeline — confidence: certain

The doc comment calls this parser "Strict", and it does validate the month against `1...12` — but the day is only checked against `1...31`, with no reference to the month's actual length. `Day` performs no validation of its own, and `Day.startOfDayUTC` is `Day.calendar.date(from: DateComponents(...))!` — `Calendar.date(from:)` is lenient, so out-of-range components roll forward rather than returning nil. I verified this against a Gregorian/UTC calendar: `(2026, 2, 30)` produces `2026-03-02T00:00:00Z` and `(2026, 4, 31)` produces `2026-05-01T00:00:00Z`. Nothing crashes; the day is silently a different day. The damage is in the store: `DeskBooking` persists `date = day.startOfDayUTC` and reads back `Day(of: date)`, so a booking saved as `Day(2026, 2, 30)` comes back as `Day(2026, 3, 2)`. Both `CaptureCoordinator.existingBooking(day:officeID:)` and `BookingStore.upsert` find the row to merge with by `$0.day == incoming.day`, comparing the round-tripped stored `Day` against the un-normalised in-memory one. They never match, so the dedupe rule `BookingMerge` documents as load-bearing ("Get this wrong and re-sharing the same screenshot doubles the month") silently fails.

**Failure scenario.** The model returns `"date": "2026-02-30"` for a row (a hallucinated or misread day — precisely the failure this file exists to defend against). `day(from:)` accepts it: month 2 is in `1...12`, day 30 is in `1...31`. `Day(2026, 2, 30)` reaches the review sheet, whose `longText` renders `startOfDayUTC` and therefore reads "Monday 2 March". The office already has a real booking on 2 March, but `existingBooking(day: Day(2026,2,30), ...)` compares against the stored booking's `Day(2026,3,2)` and finds nothing — so no clash strip and no Replace dialog. The user taps "Save and finish"; `BookingStore.upsert`'s `first { $0.day == incoming.day }` misses for the same reason and inserts a **second** `DeskBooking` for the same office on 2 March 2026. The month now counts that day twice in the gauge, and the bookings list shows two desks for one day.

```swift
let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return Day(year, month, day)
```

**Fix.** Reject any date the calendar would have to move. Either validate here:

    let components = DateComponents(year: year, month: month, day: day)
    guard Day.calendar.date(from: components).map({
        Day.calendar.dateComponents([.year, .month, .day], from: $0)
    }) == components else { return nil }   // 30 February is not a date we read
    return Day(year, month, day)

or, better, make `Day.init` itself refuse to construct a non-existent date (a failable init), so no other caller can mint one either. A round-trip test (`Day(y,m,d)` -> `startOfDayUTC` -> `Day(of:)` is the identity) would pin it.

**Verifier's correction.** Uphold, with one consequence removed: the month does NOT count the day twice in the gauge. `QuotaService.snapshot` passes `deskBookingDays: Set(bookedDays)` (QuotaService.swift:29-44), so duplicate rows on the same day collapse. The real damage is (a) two `DeskBooking` rows for one office on one day, both visible in the home screen's bookings list, (b) no clash strip and no Replace dialog because `existingBooking` misses, and (c) the review sheet showing 'Monday 2 March' for a date the parser accepted as 30 February. Fix: validate the day against `Day.calendar.range(of: .day, in: .month, ...)` in `day(from:)`, or make `Day.startOfDayUTC` non-lenient.

---
### 12. HaikuClient.extract — the app's only network call — has no test, despite `session` being an injectable seam

**`OfficeDaze/Capture/HaikuClient.swift:28`** — test-coverage — found by: test-coverage — confidence: certain

`decode(_:)` is well tested (10 assertions across the response shapes), but `extract(image:mediaType:today:)` — which builds the request, sets the three headers, serialises `body(...)`, and maps transport and HTTP failures onto `CaptureError` — is never called by any test. Neither is `body(...)` or `errorMessage(_:)`. Two of the type's seven `throw` sites are here and neither has an `#expect(throws:)`: `CaptureError.network` (line 47) and `CaptureError.httpStatus` (line 51). `CaptureCoordinatorTests` covers `.network` only by having its stubbed `extractor` closure throw it, which asserts the coordinator's handling and nothing about the client. The struct already carries `var session: URLSession = .shared` specifically so a stub can be injected, and no test uses it. The consequence is that the wire format — `output_config.format.type = "json_schema"`, `x-api-key`, `anthropic-version: 2023-06-01`, the base64 image block — is asserted nowhere. `SchemaTests` validates the schema's *shape* but never that it is placed at the key the API reads.

**Failure scenario.** Rename the request key `"output_config"` to `"output_format"` in `body(...)` (a plausible edit when following an API-doc change). All 220 tests still pass: `SchemaTests` only inspects `HaikuClient.schema` in isolation, and `decode` is fed hand-written envelopes. The first real capture returns HTTP 400 and the user sees "The model call failed (400): …" — a shipped, test-green break of the app's headline feature.

```swift
func extract(image: Data, mediaType: String, today: Day) async throws -> ([ParsedBooking], Usage) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
```

**Fix.** Add a `URLProtocol` stub and inject it via the existing seam:
```swift
final class StubProtocol: URLProtocol { nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))! ... }
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [StubProtocol.self]
var client = HaikuClient(apiKey: "k"); client.session = URLSession(configuration: config)
```
Then assert: the three headers and the JSON body's `model`/`max_tokens`/`output_config.format.type`/`messages[0].content[0].source.media_type` keys on a 200; `#expect(throws: CaptureError.httpStatus(429, "rate limited"))` on a 429 with an `{"error":{"message":…}}` body (which also covers `errorMessage`); and `#expect(throws: CaptureError.self)` for a thrown transport error covering the `.network` site.

**Verifier's correction.** Accurate as stated; only the severity needs correcting. Nothing here is presently broken — the wire format is correct as written — so this is a gap, not a defect: medium, not high. Worth adding that the fix is cheap and unusually well set up: `session` is already a var, so a URLProtocol stub asserting the three headers, the base64 image block and the `output_config.format.type` key, plus a 400 response mapping to .httpStatus, is a single small test file.

---
### 13. `OfficeMatcher`'s postcode branch is the one rule that can silently pick among several matching offices, in unsorted fetch order

**`OfficeDaze/Capture/OfficeMatcher.swift:42`** — correctness — found by: capture-pipeline — confidence: likely

Every other rule in this file is explicitly "exactly one, or nothing": the alias rule returns nil when `claiming.count > 1`, and the token rule returns `matches.count == 1 ? matches.first : nil`, with the comment "Two offices that both look right is the case where guessing does the most damage." The postcode rule breaks that invariant — `offices.first(where:)` returns the first candidate whose postcode appears in the printed name and never checks whether a second one also would. Worse, the candidate array comes from `CaptureCoordinator.matchedOffice(for:)`, which fetches with a bare `FetchDescriptor<Office>()` and no sort descriptor, so "first" is whatever order SwiftData happens to return — not stable across launches or after an insert. The result is exactly the outcome the file's own header says it exists to prevent: "A wrong match files a booking under the wrong building, which is worse than asking." Note also that the match is a plain substring test, so a shorter postcode that is a prefix of another ("EC2V 7N" inside "EC2V 7NQ") matches too.

**Failure scenario.** The user has two offices in the same building, as the app's own multi-office model invites: "Coleman, London" and "Coleman Annexe", both saved with postcode `EC2V 7NQ`. A capture comes back with `office: "Coleman Annexe, EC2V 7NQ"`. No alias claims it; the postcode branch runs and both offices satisfy the predicate, so `first(where:)` returns whichever the unsorted fetch yielded first. Half the time that is "Coleman, London" — the sheet shows the wrong office name with no picker (because `matched != nil` hides it), and the booking is saved against the wrong `officeID`, giving it the wrong colour, the wrong perimeter, and no arrival alert for the building the user actually goes to. The subsequent token rule would have correctly returned nil here and asked.

```swift
// A postcode is unambiguous when it appears, so it goes first.
        if let byPostcode = offices.first(where: {
            !$0.postcode.isEmpty && printed.localizedCaseInsensitiveContains($0.postcode)
        }) { return byPostcode }
```

**Fix.** Apply the same exactly-one discipline as the other two rules:

    let byPostcode = offices.filter {
        !$0.postcode.isEmpty && printed.localizedCaseInsensitiveContains($0.postcode)
    }
    if byPostcode.count == 1 { return byPostcode.first }
    if byPostcode.count > 1 { return nil }   // same building twice — ask

Independently, give `matchedOffice(for:)` a deterministic sort (`FetchDescriptor<Office>(sortBy: [SortDescriptor(\.name)])`) so no rule in this file depends on undefined fetch order. Consider normalising whitespace/case on both sides of the postcode comparison as well.

**Verifier's correction.** Uphold, with two corrections. (1) In the reviewer's own example the token rule would have matched the CORRECT office (`tokens("Coleman Annexe")` ⊂ `tokens("Coleman Annexe, EC2V 7NQ")`, while `tokens("Coleman, London")` is not), not returned nil — so the postcode branch preempts a correct match rather than merely bypassing a refusal. (2) The 'unsorted fetch order is not stable across launches' argument is speculative; an unsorted FetchDescriptor's order is unspecified but in practice insertion-ordered. The demonstrable defect is that the postcode branch alone omits the 'exactly one, or nothing' check that lines 39 and 60 apply everywhere else — `offices.filter { ... }` plus a `count == 1` guard is the consistent fix.

---
### 14. `Day` accepts non-existent dates and its `==`/`hash` disagree with `startOfDayUTC`, defeating the one-desk-per-office-per-day dedupe

**`OfficeDaze/Domain/Day.swift:20`** — correctness — found by: domain-logic — confidence: certain

`Day.init` validates nothing, and `Hashable`/`Comparable` are synthesised over the raw `(year, month, day)` tuple, while `startOfDayUTC` runs those components through `Calendar.date(from:)` — which normalises silently rather than returning nil. Verified on this machine with the project's exact calendar configuration:

```
2026-4-31  -> 2026-05-01T00:00:00Z
2026-2-30  -> 2026-03-02T00:00:00Z
2026-2-29  -> 2026-03-01T00:00:00Z
```

So `Day(2026,2,29) != Day(2026,3,1)` yet both produce the identical `Date`. Every SwiftData model stores `day.startOfDayUTC` and reads back with `Day(of: date)` (Store/Models.swift:126/138 and the four analogous pairs), so a non-canonical `Day` is normalised on write and can never again equal the value that produced it.

The only place in the app that builds a `Day` from unchecked integers is `CapturedBooking.day(from:)` (OfficeDaze/Capture/CapturedBooking.swift:172), whose guard is `(1...12).contains(month), (1...31).contains(day)` — a range check that permits 31 April, 30 February and 29 February in a common year. `BookingStore.upsert` then finds its existing row with `$0.day == incoming.day`, comparing a normalised stored `Day` against the un-normalised incoming one.

**Failure scenario.** A screenshot is shared and Haiku returns `"date": "2026-02-29"` for a Coleman London row (2026 is not a leap year). `day(from:)` passes it — month 2 is in 1...12, day 29 is in 1...31 — producing Day(2026,2,29). `CaptureCoordinator.save` builds a `Candidate` with that day; `upsert` finds no match, inserts a `DeskBooking` whose `date` is `2026-03-01T00:00:00Z`. The user re-shares the same screenshot (the flow explicitly supports this — "a re-share of a clearer screenshot completes a half-read booking"). Incoming day is Day(2026,2,29) again; the stored row's `day` getter now returns Day(2026,3,1); `Day(2026,3,1) == Day(2026,2,29)` is false, so no match is found and a **second** row is inserted for the same office on the same real day. Every further re-share adds another. This is verbatim the failure BookingMerge's own header warns about: "Get this wrong and re-sharing the same screenshot doubles the month." `CaptureCoordinator.existingBooking(day:officeID:)` misses for the same reason, so the clash dialog never asks.

```swift
init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
```

**Fix.** Give `Day` a validity invariant so a non-existent date cannot be constructed, e.g. a failable or normalising initialiser:

```swift
init?(checked year: Int, _ month: Int, _ day: Int) {
    guard (1...12).contains(month),
          let range = Day.calendar.range(
              of: .day, in: .month,
              for: Day.calendar.date(from: DateComponents(year: year, month: month, day: 1))!
          ), range.contains(day) else { return nil }
    self.init(year, month, day)
}
```

and have `CapturedBooking.day(from:)` use it, returning nil (a date we could not read) rather than a ghost date. A `#expect(Day(checked: 2026, 2, 29) == nil)` test would lock it. At minimum, add days-in-month validation at CapturedBooking.swift:172 — it is the only unchecked construction site in the app.

**Verifier's correction.** Uphold at medium, but the failure scenario should be re-stated to something reachable. "Haiku returns 2026-02-29" requires the model to invent a date that cannot appear on any booking confirmation — that is a weak trigger. The realistic one is an OCR digit misread that stays inside the 1...31 guard: a booking printed 2026-04-21 read back as "2026-04-31", or 2026-06-30 read as "2026-06-31". Those pass `day(from:)`, normalise to 1 May / 1 July on write, and produce exactly the described double-insert on re-share. The underlying defect — `Day` has no validity check, so its Hashable/Comparable identity and its storage identity can disagree — is unconditional and is the part worth fixing (validate in `Day.init` or return nil from a failable init, and tighten `day(from:)` to reject dates the calendar would normalise).

---
### 15. `Day` ↔ `Date` bridges through UTC midnight, so every date picker in the app is off by one day in any negative-UTC-offset timezone

**`OfficeDaze/Domain/Day.swift:44`** — correctness — found by: domain-logic — confidence: likely

`startOfDayUTC` and `init(of:)` are a matched pair only while the intermediate `Date` is never rendered or edited in local time. It is: both editors seed a SwiftUI `DatePicker` with `Day.today.startOfDayUTC` and read the result back with `Day(of:)` — `AttendanceEditorScreen.swift:23` / `:32`, and `BookingEditorScreen.swift:61` / `:156` (which also seeds from an existing booking at `:130`). `DatePicker` renders and recombines using `Calendar.current`, i.e. the device timezone, so midnight UTC is displayed at whatever local wall clock it corresponds to.

For offsets ≥ 0 the arithmetic happens to survive (01:00 BST on the 4th is still the 4th), which is why this holds in the UK and hid during development. For any negative offset it does not: midnight UTC on the 4th is the evening of the 3rd locally, so the picker opens on the wrong date and the value read back is shifted a day forward.

The same root cause makes `Day.today` (line 48) the UTC day rather than the local day. Verified with `Calendar(identifier: .gregorian)` pinned to UTC: `date(from: DateComponents(year: 2026, month: 8, day: 4))` is `2026-08-04T00:00:00Z`, which is `2026-08-03T20:00 EDT`.

**Failure scenario.** UK employee in the New York office, phone on America/New_York (EDT, UTC−4), at 10:00 local on Tuesday 4 August 2026. `Date.now` = `2026-08-04T14:00Z`, so `Day.today` = Day(2026,8,4) and `Day.today.startOfDayUTC` = `2026-08-04T00:00:00Z` = **20:00 on 3 August EDT**. They tap "Day in the office": the picker opens showing **3 August**. They set it to 4 August; `DatePicker` preserves the 20:00 local time component, giving `2026-08-04T20:00 EDT` = `2026-08-05T00:00:00Z`, and `Day(of: date)` returns **Day(2026,8,5)**. `isAhead` is then `Day(2026,8,5) > Day(2026,8,4)` = true, so the app writes a `PlannedDay` for 5 August instead of an `AttendanceDay` for 4 August — the day worked never counts toward the month and a day that has not happened appears in `forecast`. The identical shift applies to `BookingEditorScreen`, filing a desk booking one day late. Separately, at 20:00 EDT on the 4th `Day.today` flips to Day(2026,8,5), so a desk booked for the 5th stops satisfying `forecast`'s `$0 > input.today` filter and the gauge's "+1 booked" silently vanishes while `shortfall` rises by one, on the evening of the 4th.

```swift
var startOfDayUTC: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    nonisolated static var today: Day { Day(of: .now) }
```

**Fix.** Keep midnight-UTC as the *storage* encoding (Store/ can stay as it is), but stop handing it to anything that interprets a `Date` locally. Add a local-calendar bridge on `Day` and use it at every UI boundary:

```swift
/// For local-time UI only (DatePicker). Never for storage.
var startOfDayLocal: Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c.date(from: DateComponents(year: year, month: month, day: day))!
}
init(local instant: Date) {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    let p = c.dateComponents([.year, .month, .day], from: instant)
    self.init(p.year!, p.month!, p.day!)
}
static var today: Day { Day(local: .now) }
```

Then `AttendanceEditorScreen`/`BookingEditorScreen` seed with `startOfDayLocal` and read back with `Day(local:)`. "No timezone handling" is right for what a booking *means*; it is not right for reading the clock or driving a picker, which are the two places the device's zone is the only correct answer.

**Verifier's correction.** Severity corrected from high to medium. The mechanism is real and I confirmed it, but the trigger is gated on the device timezone being west of UTC, in an app whose entire quota model is England & Wales bank holidays (BankHolidays.swift:11-12, "This is England & Wales only, as specified"). For a UK-resident user on a UK phone the app is correct, which is why this survived; it is wrong for a traveller or a relocated user, not for the default population. Also worth stating precisely: the *default* value is not corrupted — a user who saves without touching the picker gets the right Day, because `Day(of: Day.today.startOfDayUTC)` round-trips. The corruption appears (a) as a wrong date *displayed* the moment the sheet opens, and (b) as a +1 day shift on any date the user actually selects. That distinction matters for reproducing it.

---
### 16. CalendarWriter.span mixes UTC midnight with local midnight and adds a raw interval, giving wrong event times on DST days and a day-early all-day event west of UTC

**`OfficeDaze/Handoff/CalendarWriter.swift:62`** — correctness — found by: arrival-handoff — confidence: certain

Two different midnights are used in one function. The timed branch builds `base` from a calendar switched to `.current`, i.e. local midnight, then reaches the start time with `addingTimeInterval(start * 60)` — absolute seconds, which is exactly the arithmetic that breaks across a DST transition. The all-day branch returns `entry.day.startOfDayUTC`, i.e. 00:00 UTC, which is a different instant from the timed branch's base and is not midnight anywhere with a non-zero offset. EventKit derives an all-day event's date from `startDate` in the display time zone (and `event.timeZone` is never set here), so a start instant that falls on the previous local day places the event on the previous day. The existing test only asserts `span.end - span.start == 8 * 3600`, which is true on every day including the broken ones, so neither case is covered.

**Failure scenario.** Verified by running the exact code path with `Europe/London`. (a) A desk booked 08:00–17:00 on 2026-03-29 (BST begins) produces a start of **09:00** local; on 2026-10-25 (BST ends) it produces **07:00**. The event lands in the calendar an hour off, and the notes say "Added by Office Daze." so the user has no reason to doubt it. (b) All-day path: the start instant for day 2026-08-05 is 2026-08-05T00:00Z, which in `America/New_York` is **2026-08-04 20:00** — so a UK user travelling in the US, or any user in a negative-offset zone, gets the all-day desk entry filed on 4 August. UK users at home are unaffected by (b) because GMT/BST are zero or positive offsets.

```swift
static func span(_ entry: Entry) -> (start: Date, end: Date, isAllDay: Bool) {
        let midnight = entry.day.startOfDayUTC
        guard let start = minutes(entry.startTime), let end = minutes(entry.endTime),
              end > start else {
            return (midnight, midnight, true)
        }
        var calendar = Day.calendar
        calendar.timeZone = .current
        let base = calendar.date(
            from: DateComponents(year: entry.day.year, month: entry.day.month, day: entry.day.day)
        ) ?? midnight
        return (
            base.addingTimeInterval(TimeInterval(start * 60)),
            base.addingTimeInterval(TimeInterval(end * 60)),
            false
        )
    }
```

**Fix.** Build both instants from full date components in one local calendar; never add raw seconds to a midnight, and never use a UTC midnight as a local one:
```swift
static func span(_ entry: Entry) -> (start: Date, end: Date, isAllDay: Bool) {
    var calendar = Day.calendar
    calendar.timeZone = .current
    func instant(minutesAfterMidnight m: Int) -> Date? {
        calendar.date(from: DateComponents(
            year: entry.day.year, month: entry.day.month, day: entry.day.day,
            hour: m / 60, minute: m % 60
        ))
    }
    let localMidnight = instant(minutesAfterMidnight: 0) ?? entry.day.startOfDayUTC
    guard let s = minutes(entry.startTime), let e = minutes(entry.endTime), e > s,
          let start = instant(minutesAfterMidnight: s),
          let end = instant(minutesAfterMidnight: e) else {
        return (localMidnight, localMidnight, true)
    }
    return (start, end, false)
}
```
Add tests that pin the wall clock rather than the duration, e.g. on 2026-03-29 and 2026-10-25 with `TimeZone(identifier: "Europe/London")`, asserting the local hour is 08.

**Verifier's correction.** The timed-branch failure is confirmed by execution; the all-day-branch failure is confirmed as far as the returned instant (2026-08-05T00:00Z = 2026-08-04 20:00 in America/New_York), with the final "EventKit files it on the 4th" step resting on EventKit's documented handling of isAllDay events with a nil event.timeZone, not on a run. The unambiguous defect either way is that span() returns local midnight in the timed branch and UTC midnight in the all-day branch for the same Day.

---
### 17. "Update calendar event" writes a twin: under write-only access `event(withIdentifier:)` cannot return the event, so the update branch is dead

**`OfficeDaze/Handoff/CalendarWriter.swift:104`** — api-misuse — found by: cross-cutting-critic — confidence: likely

`write(_:existingEventID:)` asks for `requestWriteOnlyAccessToEvents()`, then tries to fetch the previously written event with `store.event(withIdentifier:)`. `event(withIdentifier:)` is a read API; write-only authorization permits creating events and does not permit reading them back, so the fetch yields nil and the `if let existing` branch never runs. Control falls through to `EKEvent(eventStore:)` + `store.save`, which creates a second event and returns `.added(...)`. The file's own header states the problem two lines above the call — "Write-only access cannot read an event back … which is why the event identifier is stored on the booking, and why a second tap updates rather than writing a twin" — and then depends on the read it just said is impossible. Storing `calendarEventID` therefore buys nothing except a misleading button label: `BookingDetailScreen.calendarTitle` reads `booking.calendarEventID == nil ? "Add to calendar" : "Update calendar event"`, so the row promises an update and performs an insert, then reports "Added to calendar" back at the user. Because `addToCalendar()` overwrites `booking.calendarEventID` with the newest id, each round also forgets the previous event, so nothing in the app could ever clean them up.

**Failure scenario.** Open the seeded 12 August Coleman booking (desk 3C-121), grant calendar access, tap "Add to calendar". An event is created and `booking.calendarEventID` is set; the row now reads "Update calendar event". Tap it again — for example after correcting the floor. `store.event(withIdentifier:)` returns nil under write-only authorization, the `if let` fails, a fresh `EKEvent` is saved, and the outcome is `.added`. The calendar now holds two "Desk 3C-121 · Coleman" events on 12 August, the row's label flips back to "Added to calendar", and the id of the first event has been overwritten and lost.

```swift
if let existingEventID, let existing = store.event(withIdentifier: existingEventID) {
            apply(entry, to: existing, in: store)
            do {
                try store.save(existing, span: .thisEvent, commit: true)
                return .updated(existing.eventIdentifier)
```

**Fix.** Either request full access (`requestFullAccessToEvents()`), which makes both `event(withIdentifier:)` and `remove(_:span:)` work and lets the stored id do the job it was stored for; or keep write-only and stop pretending an update is possible — drop the fetch branch, label the row "Add to calendar" permanently, and warn the user that a second tap adds a second event. This has a test seam already: `write` is `@MainActor` and takes `existingEventID`, so a test that stubs the store (or at minimum asserts the outcome is `.added`, never `.updated`, under write-only) would have caught it.

---
### 18. Booking and attendance date pickers mix a UTC-pinned Date with a local-timezone DatePicker, giving an off-by-one day at negative UTC offsets

**`OfficeDaze/Screens/BookingEditorScreen.swift:84`** — correctness — found by: robustness-misc — confidence: likely

`date` is seeded with `Day.today.startOfDayUTC` (midnight UTC) and converted back with `Day(of: date)`, which uses the UTC-pinned `Day.calendar`. In between, `DatePicker(displayedComponents: .date)` renders and edits that instant in `Calendar.current` / `TimeZone.current` — there is no `.environment(\.calendar, Day.calendar)` anywhere in the app (grepped). A `.date`-only DatePicker preserves the existing time-of-day *in the local zone* when the user changes the day. At a positive UTC offset midnight UTC lands on the same local calendar day and the round trip is lossless, which is why this is invisible in the UK. At a negative offset midnight UTC is the previous local evening, so the picker both displays the wrong day and, on edit, hands back an instant that `Day(of:)` reads as the day *after* the one the user tapped. `AttendanceEditorScreen.swift:23`/`:58` has the identical construction, where the same slip also flips `isAhead` and so decides whether the record becomes an `AttendanceDay` or a `PlannedDay`. The app's whole `Day` design exists to guarantee "a desk on the 12th is a desk on the 12th, wherever the phone happens to be"; this is the one boundary where that guarantee is not held.

**Failure scenario.** Phone set to America/New_York (UTC−4). User taps Add → Desk booking. `date` = 2026-08-07T00:00Z, which the picker renders as **6 August** (20:00 EDT on the 6th) — already the wrong default. The user selects **10 August**; the picker preserves 20:00 local, producing 2026-08-10T20:00 EDT = 2026-08-11T00:00Z. `Day(of: date)` with the UTC calendar returns `Day(2026, 8, 11)`. The booking is stored, listed and alerted on as **11 August**. In `AttendanceEditorScreen` the same drift can push a chosen day past `Day.today` and silently turn a day the user worked into a `PlannedDay` instead of an `AttendanceDay`.

```swift
DatePicker(
                    "Date", selection: $date, displayedComponents: .date
                )
```

**Fix.** Give both pickers the app's own calendar so the two ends agree: `.environment(\.calendar, Day.calendar)` on the `DatePicker` (or on the enclosing `Form`), which makes the picker display and edit in UTC to match `startOfDayUTC`/`Day(of:)`. Add a test that pins `TimeZone` to a negative offset and asserts `Day(of:)` of a picker-produced date equals the day selected.

**Verifier's correction.** Split the claim into the part that is certain and the part that depends on UIKit behaviour. Certain, and the sharper failure: the *seed* is wrong. On a phone at UTC−4 the Add-booking picker opens showing 6 August; a user who accepts the default and taps Save gets a booking filed on 7 August — displayed day and stored day differ with no edit at all, and the same applies when re-opening an existing booking for edit. The reviewer's "user picks 10 August, gets 11 August" additionally depends on UIDatePicker in .date mode preserving the existing time-of-day in the local zone (standard behaviour, but not something I could verify from this source). The finding stands on the seed mismatch alone.

---
### 19. Every UI write path swallows save errors with `try?` and then dismisses as though it succeeded

**`OfficeDaze/Screens/BookingEditorScreen.swift:170`** — error-handling — found by: store-swiftdata, cross-cutting-critic — confidence: uncertain

`BookingStore` is written carefully — every mutator is `throws` and every path ends in an explicit `try context.save()`. Every caller then discards that with `try?`: `BookingEditorScreen.save`/`delete`, `AttendanceEditorScreen.save`, `HomeScreen.answerYes`/`answerNo`/`delete`, `BookingDetailScreen.recordAttendance`/`addToCalendar`, `OfficeEditorScreen.save`/`delete`, `SettingsScreen.wipe`, `ArrivalLedger.confirmAttendance`/`declineAttendance`/`handleEntry`. In each case control continues into `dismiss()` or a state mutation, so a failed write is indistinguishable from a successful one at the UI.

The worst-shaped one is `replace`, because it is not atomic from the caller's side: `context.delete(booking)` happens first (BookingStore.swift:107), and the re-created row is only committed by the `try context.save()` inside `upsert`. If that save throws, the deletion is already staged in the context, `try?` eats the error, the editor dismisses, and the next successful save anywhere in the app commits the deletion. The booking is gone and nothing ever said so.

I have not demonstrated a save failure here — SwiftData saves rarely throw on a healthy local store, which is why this is low and why the concrete loss is marked uncertain. The swallowing itself is certain and mechanical.

**Failure scenario.** Device out of disk, or the store file otherwise unwritable. User taps Edit on a booking, fixes the desk id, taps Save. `BookingStore.replace` deletes the old row, `upsert`'s `context.save()` throws, `try?` discards it, `dismiss()` runs. The detail screen's `stillExists` check sees the booking is gone from the `@Query` and dismisses in turn, so the user is returned to the list having apparently completed an edit — and the booking has been deleted rather than corrected.

```swift
if let booking {
            try? BookingStore.replace(booking, with: candidate, in: context)
        } else {
            try? BookingStore.upsert(candidate, in: context)
        }
        dismiss()
```

**Fix.** At minimum, do not dismiss on failure — `do { try BookingStore.replace(...); dismiss() } catch { saveError = error }` with an alert, so a lost edit is visible rather than inferred. Structurally, `replace` should not leave the context in a half-mutated state on throw: capture the candidate, perform the delete and the insert, and let a single `try context.save()` at the end commit both, rolling back with `context.rollback()` in a `catch` before rethrowing so a failed edit leaves the original booking intact.

**Verifier's correction.** Uphold at low for the swallowing itself; replace the failure scenario. Corrected version: the delete and the re-insert inside `replace` are staged in the same context, so a failed save cannot leave a bare deletion — the next successful save commits both. What is actually lost is the carry-across: `upsert` throwing at BookingStore.swift:39 aborts `replace` before lines 112-138, so the replacement row loses `calendarEventID` (the only handle on a write-only calendar event) and `captureID`, keeps no `notAttended` answer, and every AttendanceDay still holding the old booking's id is left pointing at a row that was deleted. The user is dismissed to the list with no indication. The remedy is the same either way: these paths need a `do/catch` that keeps the editor open and says the save failed, and `replace` should either be made atomic or clean up in a `catch`.

---
### 20. HomeScreen.snapshot is a recomputed property, so one body pass runs (4+officeCount) × 4 unbounded table fetches

**`OfficeDaze/Screens/HomeScreen.swift:112`** — performance — found by: swiftui-architecture — confidence: certain

`snapshot` is a computed property with no caching, and every read of it calls `QuotaService.snapshot`, which does four separate `context.fetch(FetchDescriptor<...>())` calls over the whole LeaveDay, AttendanceDay, DeskBooking and PlannedDay tables and then filters in Swift.

One evaluation of `body` reads it: three times in the `AttendanceGauge(...)` argument list (lines 178–180), once for `if let result = snapshot?.result` (line 183), and — the expensive part — once per office inside `officeShares`'s `map` closure (line 432), because the closure body re-evaluates the property for each element. On top of that `canStepBack` (line 225) calls `Store.recordedDays`, which is four more full fetches.

Nothing about this is amortised: `body` re-runs whenever any of the four `@Query` properties change, which is every save the app makes.

**Failure scenario.** With 3 offices and a normal month, one HomeScreen body pass reads `snapshot` 4 + 3 = 7 times → 28 full-table SwiftData fetches, plus 4 more from `canStepBack` = 32 fetches. Tapping "Yes" on a "Were you there?" strip inserts an AttendanceDay and saves; all four `@Query` properties invalidate, `body` re-runs, and the 32 fetches happen again synchronously on the main actor before the row updates. Stepping the month a month at a time re-pays it on every chevron tap.

```swift
private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: month, today: .today, in: context)
    }
```

**Fix.** Compute it once per pass and thread it through. Minimum change: make `body` open with `let snapshot = self.snapshot` and pass that value into `gaugeCard`, `shortfallStrip` and `officeShares` (which should take `[UUID: Double]` as a parameter rather than reaching back for the property). Better: move the whole thing behind an `@Observable` view model that recomputes on month change / model-context change rather than on every body evaluation, so `canStepBack`'s `Store.recordedDays` is cached too.

---
### 21. The entire SwiftUI Screens layer and DesignSystem have effectively zero coverage — 3,431 of 7,887 production lines

**`OfficeDaze/Screens/HomeScreen.swift:116`** — test-coverage — found by: test-coverage — confidence: certain

Screens/ is 2,791 lines across 10 files and DesignSystem/ is 640 lines across 4. Between them that is 43% of the production Swift in the app. Not one `View` in either directory is ever instantiated by a test: there is a single unit-test target (`com.apple.product-type.bundle.unit-test`), no UI-test target, no ViewInspector, no snapshot library, and no `XCUIApplication` anywhere. What is tested is the handful of pure statics deliberately hoisted out of the views — `HomeScreen.entries`, `HomeScreen.isUnanswered`, `HomeScreen.dateLine`, `HomeScreen.targetExplanation`, `HomeScreen.shortfallText`, `BookingEditorScreen.unreadFieldNames`, `CaptureSheet.clashMessage`, `fullAddress` — roughly 110 lines. Everything else is unexercised, including logic that is not merely layout: `HomeScreen.daysLeftText` (the singular/plural of the app's only red banner), `HomeScreen.dayCount`, `AttendanceGauge.accessibilityValue` (the sole VoiceOver description of the app's centrepiece, four conditional clauses), `shortfallStrip`'s five-way `switch` including the `case _ where month < Day.today.month_` past-month arm, and `officeShares`. The hoisting pattern is the right instinct; it just stopped short of the branches that still live inside `body` and in `private var`s.

**Failure scenario.** `HomeScreen.shortfallStrip` has a `case _ where month < Day.today.month_` arm that renders "Fell N short" for a finished month, deliberately suppressing the red. Delete that case and every one of the 220 tests still passes, because `shortfallStrip` is `private` and no test ever renders `HomeScreen`. A past month in the `.unreachable` standing would then show "Can't reach 8 this month" in red under the heading "July 2026" — the exact regression the code comment says the arm exists to prevent — and CI would be green.

```swift
var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                gaugeCard
```

**Fix.** Two steps. (1) Continue the existing hoist: make `shortfallStrip`'s standing→(tone, leading, trailing) decision a `static func` returning a plain value type, and make `AttendanceGauge.accessibilityValue` a `static func accessibilityValue(attended:booked:target:)`, then assert them the way `dateLine` and `targetExplanation` already are — including `daysLeftText(daysAvailable: 1)` for the singular. (2) Add a UI-test target with a handful of smoke tests (launch, open Settings, open the leave calendar), or adopt snapshot tests for `AttendanceGauge`, so the drawing code in DesignSystem/ is at least executed once.

**Verifier's correction.** The facts hold; the framing inflates them. Most of the 3,431 lines are declarative view builders whose unit-test value is near zero, and the finding's own remedy — hoisting logic to statics — is already the codebase's established pattern. The actionable core is five named, currently-unreachable pieces of logic: HomeScreen.daysLeftText (:331, static, trivially testable today), HomeScreen.dayCount (:437, static, trivially testable today), HomeScreen.shortfallStrip's past-month arm (:302), AttendanceGauge.accessibilityValue (:109), and HomeScreen.officeShares (:430). Two of those are already static and public enough to test in one line each — the gap there is not architectural, it is simply unwritten. Severity is medium, not high: nothing here is a defect users can hit today.

---
### 22. HomeScreen recomputes the whole quota snapshot once per office plus four more times, every body evaluation

**`OfficeDaze/Screens/HomeScreen.swift:432`** — performance — found by: concurrency-swift6 — confidence: certain

`snapshot` is a computed property, so every syntactic reference re-runs `QuotaService.snapshot`, which performs four unfiltered `context.fetch` calls (`LeaveDay`, `AttendanceDay`, `DeskBooking`, `PlannedDay`) plus `Quota.calculate` and its bank-holiday derivation. `gaugeCard` references it four times (lines 178, 179, 180, 183 — the first three are separate getter invocations, not one bound value), and `officeShares` references it *inside a map over `offices`*, so the count scales with the number of offices. All of it is synchronous SwiftData work on the main actor, repeated on every re-render — and `@Query`-backed `bookings`, `attendance` and `planned` already hold the same rows in memory, so most of the fetching is redundant on top of being repeated.

**Failure scenario.** With the 3 seeded offices, one HomeScreen body evaluation runs `QuotaService.snapshot` 7 times = 28 unfiltered SwiftData fetches; with the palette's full 6 offices it is 10 snapshots = 40 fetches. Every insert from `BookingStore` (each `save` in the capture review writes and saves individually), every month-stepper tap and every `@Query` invalidation re-triggers the whole set on the main thread, so a year of bookings turns a routine re-render into tens of full-table scans.

```swift
private var officeShares: [(office: Office, days: Double)] {
        offices
            .map { ($0, snapshot?.attendedByOffice[$0.id] ?? 0) }
```

**Fix.** Compute the snapshot once per body evaluation and pass it down: bind `let snapshot = self.snapshot` at the top of `body` and hand it to `gaugeCard(snapshot)` and `officeShares(snapshot)` (the latter then hoists the dictionary out of the `map`). Better still, derive the snapshot from the `@Query` arrays already in memory rather than issuing fresh `FetchDescriptor` fetches, so it is a pure function of state SwiftUI is already tracking.

**Verifier's correction.** Arithmetic off: SeedData seeds two offices, not three, so a seeded body evaluation runs QuotaService.snapshot 6 times = 24 unfiltered fetches (not 7 / 28). The six-office ceiling figure (10 snapshots / 40 fetches) is correct. Everything else — the computed property, the four unfiltered fetches, the four gaugeCard references and the per-office reference in officeShares — is confirmed.

---
### 23. LeaveScreen derives the whole year's bank holidays twice per calendar cell — ~62 full derivations per render

**`OfficeDaze/Screens/LeaveScreen.swift:21`** — performance — found by: swiftui-architecture — confidence: certain

`bankHolidays`, `attendedDays` and `fractions` are computed properties with no caching, and `cell(_:)` reads them repeatedly. Per cell: `bankHolidays` is built once as an argument to `LeaveCycle.editable` (line 124) and again inside `background(_:fraction:)` (line 158); `attendedDays` is built once for `editable`, once in `foreground` (line 146) and once in `background` (line 157); `fractions` is built once (line 123).

Each `bankHolidays` build calls `BankHolidays.englandAndWales(in:)` → `englandAndWales(year:)`, which is not cheap: it constructs `Month(...).days` three times (each = a `Calendar.range` plus 31 `Day` allocations), runs `firstMonday`/`lastMonday` scans where every `isMonday` costs a `Calendar.date(from:)` plus a `Calendar.component(.weekday:)`, runs three `placeFixed` weekend-substitution loops, then sorts a Set and filters by `isWeekday`. That is on the order of 150+ Calendar operations per call.

**Failure scenario.** A 31-day month renders 31 cells → 62 `englandAndWales(year:)` derivations (~9,000+ Calendar date/component operations) plus 93 `attendedDays` Set rebuilds and 31 `fractions` dictionary rebuilds, all synchronously on the main actor. `toggle(_:)` (line 212) saves the context, which invalidates the `leave` `@Query` and re-runs `body` — so every single tap on a day in the holiday calendar pays the whole cost again. This is the interaction most likely to be done in bursts (booking a fortnight off is 10–14 consecutive taps).

```swift
private var bankHolidays: Set<Day> {
        Set(BankHolidays.englandAndWales(in: month))
    }
```

**Fix.** Two fixes, both cheap. (1) Compute the three sets once per body pass: move `let bankHolidays = self.bankHolidays`, `let attended = self.attendedDays`, `let fractions = self.fractions` into `grid` and pass them into `cell`/`foreground`/`background` as parameters. (2) Memoise `BankHolidays.englandAndWales(year:)` behind a `[Int: [Day]]` cache — it is a pure function of the year and the year set an app touches is tiny.

**Verifier's correction.** Uphold, and the finding actually understates it. `result` (LeaveScreen.swift:37-46) is also an uncached computed property that runs Quota.calculate — which itself calls BankHolidays.englandAndWales(in:) at Quota.swift:141 and re-derives `fractions` at :40 — and it is read ~7 more times per pass: once at :165 and six times across `explanation` (:182, :183, :186, :187, :188, :192). So the true per-render figure is ~69 englandAndWales derivations, not 62.

---
### 24. Month-stepper chevrons and the Yes/No answer buttons are well under the 44pt minimum tap target, and the chevrons are unlabelled

**`OfficeDaze/Screens/LeaveScreen.swift:80`** — accessibility — found by: swiftui-architecture — confidence: certain

Several primary controls are built as bare glyphs or small-padded text with `.buttonStyle(.plain)`, which gives the button exactly its content's bounds as the hit region:

- `LeaveScreen.monthStepper` (lines 80–92): `Image(systemName: "chevron.left"/.right")` at `.font(.system(size: 17))` with no padding and no `contentShape` → roughly a 20×17pt target. These are also the only way to change month on the screen and carry no `.accessibilityLabel`, so VoiceOver falls back to the symbol name.
- `HomeScreen.stepButton` (lines 263–277): 17pt symbol + 6pt vertical / 10pt horizontal padding → about 37×32pt. Also unlabelled — the middle month button has an accessibility label but the two chevrons do not.
- `HomeScreen.answerButton` (lines 599–612): 14pt text + 5pt vertical padding → about 27pt tall.
- `LeaveScreen.cell` (line 135): `.frame(height: 40)`.

The 44pt floor is honoured elsewhere in the codebase (`Metrics.minimumRow`, `headerIcon`'s comment), so these are omissions rather than a deliberate choice.

**Failure scenario.** On an iPhone held one-handed, tapping the LeaveScreen month chevron requires hitting a ~20×17pt region — under half the HIG minimum in each dimension — and misses land on the card behind it, doing nothing. For VoiceOver users, HomeScreen's stepper announces three controls where only the middle one is named; the two chevrons are read from the SF Symbol name, so "previous month" and "next month" are not stated anywhere.

```swift
Button { month = month.adding(months: -1) } label: {
                Image(systemName: "chevron.left")
                    .opacity(canStepBack ? 1 : 0.3)
            }
            .disabled(!canStepBack)
```

**Fix.** Reuse `HomeScreen.stepButton`'s shape (extract it into DesignSystem) and give it a real target and a name:

    .frame(minWidth: Metrics.minimumRow, minHeight: Metrics.minimumRow)
    .contentShape(Rectangle())
    .accessibilityLabel("Previous month")   // / "Next month"

and raise `answerButton`'s vertical padding to 12 (or add `.frame(minHeight: Metrics.minimumRow)`), and the leave cell height to 44.

**Verifier's correction.** Drop the LeaveScreen.cell bullet. The grid cell is `.frame(height: 40)` across a 7-column LazyVGrid inside a card padded 12/12 within 16pt screen padding — about 42×40pt on a 375pt device. That is marginal, not 'well under', and bundling it weakens the three genuine cases.

---
### 25. Leave-calendar cells expose no accessibility label or value — leave, half-leave, attended and bank holiday are conveyed by background colour alone

**`OfficeDaze/Screens/LeaveScreen.swift:122`** — accessibility — found by: swiftui-architecture — confidence: certain

`cell(_:)` builds a `Button` whose only label content is `Text("\(day.day)")` — a bare day number. Every piece of state the grid encodes is carried exclusively by `foreground(...)` and `background(...)`: amber surface = whole day's leave, amber at 0.5 opacity = half day, green surface = attended, grey = weekend or bank holiday, clear = available. None of it is surfaced through `.accessibilityLabel`, `.accessibilityValue` or `.accessibilityAddTraits`, and the button carries no month context.

The half-day distinction is the worst case: a whole day and a half day differ only by `Palette.warningSurface.opacity(1)` vs `.opacity(0.5)` — a distinction that is also marginal for low-vision sighted users, since both sit on white with the same `warningText` foreground.

**Failure scenario.** A VoiceOver user opens the holiday calendar with 12–16 August booked off (16 Aug as a half day). Swiping through the grid announces "12, button", "13, button", "14, button", "15, button", "16, button" — identical to "17, button" which has no leave. There is no way to hear which days are booked off, whether a day is a half or a whole, which days are already attended, or why some cells do not respond to activation (the disabled ones announce "dimmed" with no reason).

```swift
return Button {
            toggle(day)
        } label: {
            Text("\(day.day)")
                .font(.system(size: 15, weight: fraction != nil ? .semibold : .regular))
```

**Fix.** Attach an explicit label and value to the button, e.g.:

    .accessibilityLabel(day.dayAndMonth)
    .accessibilityValue(
        fraction.map { $0 >= 1 ? "Whole day's leave" : "Half day's leave" }
            ?? (attended.contains(day) ? "Attended"
                : bankHolidays.contains(day) ? "Bank holiday"
                : day.isWeekend ? "Weekend" : "No leave")
    )
    .accessibilityHint(editable ? "Double tap to cycle leave" : "")

and add a non-colour marker (a dot, or a "½" glyph) for the half-day case so it is distinguishable without colour discrimination.

---
### 26. A day marked as leave and later recorded as attended becomes a permanently stuck amber cell the user cannot clear

**`OfficeDaze/Screens/LeaveScreen.swift:141`** — correctness — found by: swiftui-architecture — confidence: certain

`LeaveCycle.editable` returns false for any day in `attendedDays`, and `cell` applies `.disabled(!editable)`. The intent (per the doc comment on `LeaveCycle.editable`) is that you cannot *book* leave on a day you were on prem. But the guard is applied to the whole cell, including the clear path — so a day that already carries a leave row and then acquires an attendance row is rendered with the leave styling (`foreground` returns `Palette.warningText` and `background` returns `Palette.warningSurface`, both because `fraction != nil` short-circuits before the attended check) and is simultaneously disabled.

The user sees an amber, leave-looking cell, taps it, and nothing happens. There is no explanation on screen; the `key` text only says days on prem "can't be booked off", which does not describe a day that is already booked off. The leave row keeps feeding `QuotaService`'s leave input and keeps counting toward `relief`, so it goes on lowering the month's target with no way to remove it from this screen.

**Failure scenario.** 1. In August, tap 5 Aug in the holiday calendar to book it as leave. 2. On 5 Aug, either the geofence fires or the user adds it via "Day in the office" → an AttendanceDay for 5 Aug is written (`BookingStore.recordAttendance` has no leave check). 3. Return to the holiday calendar: 5 Aug is amber (leave), and tapping it does nothing — `editable` is false because `attendedDays.contains(5 Aug)`. The leave day is now unremovable from the UI while still counting toward `relief`.

```swift
.buttonStyle(.plain)
        .disabled(!editable)
```

**Fix.** Only block *adding* leave, not clearing it. Change the disable condition to `.disabled(!editable && fraction == nil)`, and in `toggle` short-circuit to "clear" when the day is attended, e.g. `let next = attendedDays.contains(day) ? nil : LeaveCycle.next(after: fractions[day])`. Add a test in the LeaveCycle suite covering "leave booked first, attendance recorded second".

**Verifier's correction.** The failure is real but 'permanently stuck' / 'unremovable from the UI' overstates it. There is an undiscoverable escape: deleting the AttendanceDay row from HomeScreen's row menu (HomeScreen.swift:472-479 → :761 BookingStore.deleteAttendance) makes `attendedDays` no longer contain the day, which re-enables the cell and lets the leave be cleared. The correct statement is: the leave cannot be cleared from the screen that owns it, and nothing on that screen says why or where to go — while the day goes on counting toward both `relief` and `attended`.

---
### 27. All six office colour swatches share the accessibility label "Office colour", and selection state is not exposed

**`OfficeDaze/Screens/OfficeEditorScreen.swift:179`** — accessibility — found by: swiftui-architecture — confidence: certain

`colourPicker` renders six `Button`s whose labels are bare `Circle()` fills — no text — with a single hard-coded `.accessibilityLabel(taken ? "Colour already used" : "Office colour")`. Every selectable swatch therefore announces the identical string, and the currently selected one (`colourHex == hex`, drawn as a ring overlay on line 170–172) carries no `.isSelected` trait or accessibility value.

The office colour is not decorative — `Palette` calls the office dot "the only place colour carries meaning outside the gauge", it is the sole channel that ties a booking row to its office in `HomeScreen.bookingRow` and the sole channel in the `officeSplit` bar. So the one control that assigns that meaning is unusable without sight.

**Failure scenario.** A VoiceOver user adds a second office. Swiping across the Colour section announces "Office colour, button" four times and "Colour already used, button" twice, in a row, with nothing to distinguish teal from amber from purple and no announcement of which one is currently selected. The user cannot deliberately pick a colour, and cannot tell whether their double-tap changed anything.

```swift
.buttonStyle(.plain)
                .disabled(taken)
                .accessibilityLabel(taken ? "Colour already used" : "Office colour")
```

**Fix.** Give each palette entry a name and use it, plus expose selection:

    .accessibilityLabel(OfficeColours.name(of: hex))          // "Teal", "Amber", …
    .accessibilityValue(taken ? "Already used by another office" : "")
    .accessibilityAddTraits(colourHex == hex ? [.isSelected] : [])

Adding a `name` (or `label`) alongside the hex in `OfficeColours.palette` is the only supporting change needed, and it also gives `OfficeDot` something to say.

**Verifier's correction.** The example scenario's arithmetic is wrong. `takenColours` (OfficeEditorScreen.swift:40-42) excludes only the office being edited, so adding a *second* office means one colour taken, not two: VoiceOver hears 'Office colour' five times and 'Colour already used' once. The defect itself is unchanged.

---
### 28. Saving the office editor writes back a stale alias list, silently discarding an alias the capture sheet taught while the editor was open

**`OfficeDaze/Screens/OfficeEditorScreen.swift:206`** — concurrency — found by: cross-cutting-critic — confidence: likely

`OfficeEditorScreen` snapshots `aliases` into `@State` once, in a `.task` guarded by `loaded`, and then blindly writes the snapshot back over the model on save (`target.aliases = aliases`) — a read-modify-write with no merge. The other writer of that same array is `CaptureCoordinator.remember(_:as:)`, which appends the printed office name after the capture sheet asks "Which office is …?" and saves the context. Those two can be live at the same time, because the capture sheet is presented from `OfficeDazeApp`'s `WindowGroup` content (`.sheet(isPresented: capture.isActive)`) and therefore covers whatever is pushed in the navigation stack, and because `.onOpenURL` starts a capture the instant iOS hands over a shared file — no user action on the underlying screen is needed. `remember` also strips the alias off every other office on the way through, so its work is not just lost, it is lost after other rows have already been mutated for it.

**Failure scenario.** Settings → Coleman → Edit. The `.task` loads `aliases = []` into state. While that screen is up, the user shares a booking screenshot to Office Daze; `onOpenURL` starts a capture and the sheet slides over the editor. The printed office is "Coleman, London", which matches nothing, so the sheet asks and the user picks Coleman. `CaptureCoordinator.save` calls `remember("Coleman, London", as: colemanID)` → `target.aliases == ["Coleman, London"]`, saved. The sheet closes; the editor is on screen again, still holding `aliases == []`. The user taps Save. `target.aliases = aliases` sets it back to `[]` and `context.save()` commits. The alias the user was just asked for and answered is gone, and the very next capture of the same document asks the same question again — which the alias mechanism exists specifically to prevent.

```swift
// Written on save like every other field, so backing out of a deletion
        // leaves the office as it was.
        target.aliases = aliases
```

**Fix.** Do not write the whole array back. Track only the deletions the user made on this screen and apply them as a difference: `target.aliases.removeAll { removed.contains($0) }`, leaving anything added since the screen opened in place. Alternatively re-read `target.aliases` at the top of `save()` and union it with the on-screen list minus the user's deletions. The same read-modify-write shape applies to every other field here, but `aliases` is the only one with a second writer today.

---
### 29. Adding or editing an office never re-registers its geofence, so a new office is not monitored until the process is relaunched

**`OfficeDaze/Screens/OfficeEditorScreen.swift:220`** — correctness — found by: store-swiftdata — confidence: likely

`ArrivalMonitor.refreshRegions()` has exactly three call sites: the root view's `.task` in `OfficeDazeApp` (launch), `locationManager(_:didChangeAuthorization:)`, and `SettingsScreen.wipe`. `OfficeEditorScreen.save()` inserts or mutates the `Office` and saves the context, and `delete()` removes it, but neither tells the monitor. `refreshRegions` rebuilds the whole set from a fresh fetch, so it is exactly what needed calling.

SwiftUI's `.task` on the WindowGroup root runs when the view appears and does not re-run when the app returns from the background — the root never disappears — so the stale region set persists for the entire process lifetime, not just until the next foreground. That covers adding a second office (permission is already `authorizedAlways`, so `didChangeAuthorization` never fires), changing `radiusMetres`, and flipping `alertEnabled` from off to on.

Settings even renders "Alert on · 200m" from the stored `Office`, so the row asserts a perimeter that CoreLocation is not watching, or is watching at the old radius.

**Failure scenario.** User already has Coleman set up with Always granted, so `monitoredRegions` contains Coleman. They add Brussels: Settings → Add office → name, address, Save. The office is geocoded and persisted, the Settings row reads "Alert on · 50m", and `manager.startMonitoring` is never called for it. They keep the app in the background. Next morning they walk into Brussels: no `didEnterRegion`, no alert, no ledger row, and the day goes unrecorded until the evening nudge or the "Were you there?" row catches it. Same shape for editing: raise Coleman's perimeter from 50m to 300m because the alert kept missing, save, and CoreLocation goes on using 50m.

```swift
if editing == nil {
            context.insert(target)
            // Held, so a second Save after the not-located alert corrects this
            // office rather than inserting another one beside it.
            created = target
        }
        try? context.save()
```

**Fix.** Inject the monitor into the editor the way `SettingsScreen` already does (`@Environment(ArrivalMonitor.self) private var arrival`) and call `arrival.refreshRegions()` after the save in `save()` and after the delete in `delete()`. `refreshRegions` is already idempotent and rebuilds wholesale, so the call is cheap and cannot drift. Alternatively, have `ArrivalMonitor` observe the container's `didSave` notification and refresh when any `Office` row changes, which closes the gap for every future write path rather than these two.

**Verifier's correction.** Uphold at medium, with the window stated more precisely. It is not permanent: iOS routinely terminates backgrounded apps, and the next cold launch runs the root `.task` and re-registers everything, so the exposure is "until the app process next starts", which can be minutes or days. Two additions the reviewer did not make: the same gap applies in the opposite direction on delete — CLLocationManager keeps monitoring the deleted office's region (the app's own comment at SettingsScreen.swift:207-209 says so), and an entry there calls ArrivalLedger.handleEntry, which returns `.disabled` at line 39 because `office(officeID)` is now nil, so it fails quietly rather than alerting for a building that no longer exists. The fix is one `arrival.refreshRegions()` at the end of both save() and delete(); OfficeEditorScreen would need the `@Environment(ArrivalMonitor.self)` SettingsScreen already takes.

---
### 30. Deleting an office orphans attendance and planned days, and the gauge and its office-split bar stop agreeing

**`OfficeDaze/Screens/OfficeEditorScreen.swift:240`** — correctness — found by: store-swiftdata — confidence: certain

Entities reference each other by UUID, so SwiftData has no relationship to cascade or nullify. `delete()` removes the `Office` row and nothing else, and unlike `SettingsScreen.wipe` it does no cleanup of the rows that point at it. Four models are left holding a dangling `officeID`: `DeskBooking`, `AttendanceDay`, `PlannedDay`, `ArrivalAlert`.

The confirmation dialog only warns about one of them — "Its desk bookings stay, but they will no longer name an office" — and the two it does not mention are the two that still feed arithmetic. `QuotaService.snapshot` fetches every `AttendanceDay` and `PlannedDay` and filters only by month, so orphaned rows keep counting toward `attended` and `forecast`. But `HomeScreen.officeShares` maps over the live `offices` query, so the orphaned share silently vanishes from the split bar — whose own doc comment promises "this is the same number, and this is where it went".

There is also no route back: `AttendanceEditorScreen` can only add rows, so an orphaned attendance day can never be re-pointed at a replacement office, and re-adding an office with the same name mints a fresh UUID.

**Failure scenario.** Store with three offices — Coleman (3 attended days), Brussels (1), and a third with 2. The gauge card reads attended 6 and the split bar shows 3 / 1 / 2. Open Settings, tap Brussels, Delete office, confirm. The gauge still reads 6 (the Aug-4 Brussels `AttendanceDay` is untouched), but `officeShares` now yields only Coleman 3 and the third office 2, so the bar underneath sums to 5. Two figures in the same card disagree by a day, with nothing on screen explaining the missing one. Any `PlannedDay` for Brussels likewise keeps inflating `forecast` while rendering as "Unknown office · no desk booked".

```swift
private func delete() {
        guard let office else { return }
        context.delete(office)
        try? context.save()
        dismiss()
    }
```

**Fix.** Make the delete explicit about the rows it strands, in the store rather than the screen — add `BookingStore.deleteOffice(_:in:)` that, in one transaction, deletes the office's `PlannedDay` and `ArrivalAlert` rows (neither means anything without a building), nulls or deletes `AttendanceDay.officeID` for that office per the product decision, leaves `DeskBooking` as the dialog already promises, saves once, and then calls `arrival.refreshRegions()`. Whichever choice is made for attendance, `officeShares` needs an "Other" bucket for `attendedByOffice` keys with no matching `Office` so the bar cannot silently disagree with the gauge above it.

**Verifier's correction.** Uphold at medium with two factual trims. (1) "There is no route back" overstates it: an orphaned AttendanceDay or PlannedDay can be deleted from the month list via HomeScreen.delete (HomeScreen.swift:754-764). What is genuinely impossible is re-pointing it at a replacement office. (2) The visible gauge/bar contradiction needs three or more offices: officeSplit is only rendered when `shares.count > 1` (HomeScreen.swift:124-127), so with two offices and one deleted the bar disappears entirely and the inflated gauge goes unchallenged rather than contradicted. Also worth noting the fix is not simply nulling `officeID` on delete — `attendedByOffice` skips rows with a nil officeID (QuotaService.swift:51), so the bar would still fall short of the gauge; the split bar needs an "other/removed" share, or the dialog needs to say what happens to attendance.

---
### 31. Attendance dedupe is per-office but the quota sums fractions per-row, so one calendar day at two offices counts as two days on prem

**`OfficeDaze/Store/BookingStore.swift:234`** — correctness — found by: store-swiftdata — confidence: certain

`recordAttendance` refuses a duplicate only when an existing row matches BOTH the day and the office. `Quota.calculate` then computes `attended` by summing `fraction` across every attendance row in the month with no per-day collapse (Quota.swift:166-168), while `Snapshot.attendedDays` is a `Set<Day>`. Two `AttendanceDay` rows for the same date at different offices therefore make the same calendar day worth 2.0 toward the eight, and make the snapshot internally inconsistent: `result.attended == 5` alongside `attendedDays.count == 4`.

This is not a theoretical path — three separate flows walk straight into it, and each one is deliberately per-office:
- `AttendanceEditorScreen.alreadyRecorded` (line 40-45) also keys on day AND office, so the Save button stays enabled for the second office.
- `ArrivalRule.decide` is scoped per office by design (tested in ArrivalTests.acknowledgementIsScoped), so a second arrival alert fires and its `I'm here` action is a static category action that cannot be suppressed per notification. `ArrivalLedger.deliver` even comments "Recorded at another office earlier today ... the day is already counted" and drops the "tap to make it 5" tail — it knows the day is counted, and still leaves the button wired to `confirmAttendance`, which writes the second row.
- `NudgeScheduler.unconfirmed` explicitly handles "two offices in one day is unusual but possible" and will ask about the second office's booking that evening; answering "I was there" goes through the same `recordAttendance`.

The existing test only covers confirming twice at the SAME office (ArrivalTests.swift:565).

Downstream consequences: `Result.standing` returns `.met` when `attended >= target`, so the gauge can read "Target met" a whole day early; `HomeScreen` prints "5 of 8" for four days worked; the arrival notification title says "Day 5 of 8"; and `attendedByOffice` splits 5 across the offices so the office-split bar agrees with the wrong total.

**Failure scenario.** Seeded store (attendance: 3 Aug Coleman, 4 Aug Brussels, 5 Aug Coleman, 6 Aug Coleman; attended == 4, target == 8). Call `BookingStore.recordAttendance(day: Day(2026, 8, 5), officeID: SeedData.brusselsID, source: .manual, today: Day(2026, 8, 6), in: context)` — reachable by opening "Day in the office", picking 5 August and Brussels. The `already` guard misses (no Aug-5-Brussels row), a fifth row is inserted. `QuotaService.snapshot(for: SeedData.month, today: Day(2026,8,6)).result.attended` is now 5.0 while `snapshot.attendedDays` still has 4 elements. The user has worked four calendar days and the app credits five.

```swift
let already = try context.fetch(FetchDescriptor<AttendanceDay>())
            .contains { $0.day == day && $0.officeID == officeID }
        guard !already else { return nil }
```

**Fix.** Attendance is a fact about a day, not about a day-and-a-building, so the invariant belongs on the day. Either cap the write — reject (or convert to a fraction top-up) when the day already totals 1.0 across all offices:

    let recordedToday = try context.fetch(FetchDescriptor<AttendanceDay>())
        .filter { $0.day == day }
    guard recordedToday.reduce(0, { $0 + $1.fraction }) + fraction <= 1.0 else { return nil }

— or make `Quota.calculate` authoritative by collapsing per day before summing:

    let attended = Dictionary(grouping: input.attendance.filter { month.contains($0.day) }, by: \.day)
        .values
        .reduce(0) { $0 + min(1.0, $1.reduce(0) { $0 + $1.fraction }) }

Doing both is cheapest: the cap stops the bad row, the collapse makes existing bad rows harmless. `attendedByOffice` then needs the same treatment or it will no longer sum to `attended`.

**Verifier's correction.** Uphold on substance; severity down from high to medium. Two corrections to the write-up. (1) The seeded example does not by itself make the gauge read "Target met" — target is 8 there, so the visible damage is "5 of 8" for four days worked plus the internal attended/attendedDays disagreement; the early `.met` only follows once the inflated total crosses the target. (2) Worth adding: StoreTests.swift:106-129 already exercises this exact case (3 Aug Brussels on top of the seeded 3 Aug Coleman) and asserts attended goes up by a whole day, so fixing the dedupe will break that test — it needs rewriting to a date the seed does not already hold. Severity is medium rather than high because the trigger needs two offices and a same-day double record; a single-office user cannot reach it at all. Note also that summing fractions across offices is the right behaviour for half-days (0.5 at each office = 1.0 day); the defect is specifically that two full-day rows for one date are accepted.

---
### 32. DeskBooking.hoursText: one of four switch arms tested, and an untested arm is on the common capture path

**`OfficeDaze/Store/Models.swift:145`** — test-coverage — found by: test-coverage — confidence: certain

`hoursText` is a four-arm switch and exactly one assertion exists for it — `StoreTests:47`, `#expect(bookings[0].hoursText == "09:00 – 17:00")`, the both-present arm. The `(nil, end?)` arm is not an exotic edge: `CapturedBooking.parsed()` always fills `endTime` from `Self.defaultEndTime` while leaving `startTime` nil whenever the model could not read it, and `CaptureTests.namesSilentBlanks` produces exactly that shape (`startTime` nil, `endTime` "17:00", "startTime" in `unsureFields`). Save that booking and `BookingDetailScreen:139` renders `hoursText`, taking the untested `"until \(end)"` arm. The `(start?, nil)` and `(nil, nil)` arms are reachable from `BookingEditorScreen` manual entry. So three of four arms — including one that fires on ordinary captured bookings — are unasserted.

**Failure scenario.** A booking captured from the confirmation-email layout with an unreadable start time is stored as startTime=nil, endTime="17:00". Swap the two nil-arms — `case (let start?, nil): "until \(start)"` / `case (nil, let end?): end` — and every test passes. The booking detail screen then reads "17:00" as the hours line for a booking whose start was never read, which is indistinguishable from a booking that starts at 17:00.

```swift
var hoursText: String? {
        switch (startTime, endTime) {
        case (let start?, let end?): "\(start) – \(end)"
        case (let start?, nil): start
        case (nil, let end?): "until \(end)"
        case (nil, nil): nil
        }
    }
```

**Fix.** Add a table-driven test beside the existing seed assertions:
```swift
@Test("The hours line says only what was read", arguments: [
    ("09:00", "17:00", "09:00 – 17:00"), ("09:00", nil, "09:00"),
    (nil, "17:00", "until 17:00"), (nil, nil, nil),
] as [(String?, String?, String?)])
func hoursText(start: String?, end: String?, expected: String?) {
    let booking = DeskBooking(officeID: UUID(), day: Day(2026, 8, 5), deskID: "3C-114",
                              startTime: start, endTime: end, source: .capture)
    #expect(booking.hoursText == expected)
}
```

---
### 33. Store.swift: four of its six functions untested, including the first-launch seeding gate and the month-stepper floor

**`OfficeDaze/Store/Store.swift:46`** — test-coverage — found by: test-coverage — confidence: certain

Tests touch only `makeInMemoryContainer` (every suite's `init`) and `wipe` (both scopes, StoreTests:554 and :570). Untested: `makeContainer` (the on-disk path with `seedIfEmpty`), `seedIfNeeded` and its two guards, the `hasSeeded` UserDefaults flag, and `recordedDays`. Two of these carry real rules. `seedIfNeeded`'s whole point, per its own comment, is that a deliberately-emptied store must not be re-seeded — that is a flag/empty-store distinction with two guard branches and no assertion anywhere, and `wipe`'s `hasSeeded = true` postcondition is likewise unasserted by the two wipe tests. `recordedDays` is the sole input to both month steppers (`HomeScreen:225`, `LeaveScreen:74`) via `MonthRange`: `MonthRangeTests` is thorough but feeds hand-built `[Day]` arrays, so the four fetches and the `kind != .bankHoliday` filter that actually build that array are never run. Separately, no code anywhere in OfficeDaze/ ever constructs a `LeaveDay(kind: .bankHoliday)`, so that filter — duplicated in four files — is unreachable today and untested in all four.

**Failure scenario.** Drop the `+ context.fetch(FetchDescriptor<PlannedDay>()).map(\.day)` term from `recordedDays`. All 220 tests pass. A user whose only record in an earlier month is a `PlannedDay` (a workshop noted last March, later attended elsewhere) finds the back chevron on both the gauge and the holiday calendar disabled at the current month, with no way to reach that history. Similarly, deleting `hasSeeded = true` from the second guard in `seedIfNeeded` passes every test and makes a user who has emptied their store re-seed the sample August 2026 month on the next cold launch.

```swift
static func seedIfNeeded(_ context: ModelContext) throws {
        guard !hasSeeded else { return }
        guard try context.fetchCount(FetchDescriptor<Office>()) == 0 else {
            hasSeeded = true
            return
        }
        try SeedData.populate(context)
        hasSeeded = true
    }
```

**Fix.** Add a `Store` suite that saves and restores the `store.seeded` default around each case: assert `seedIfNeeded` on a fresh in-memory context populates and sets the flag; that a second call is a no-op; that a non-empty store sets the flag without populating; and that `wipe` leaves `hasSeeded == true`. For `recordedDays`, seed one record of each of the four kinds in four different months plus a `LeaveDay(kind: .bankHoliday)`, and assert the returned set is the four days and excludes the bank-holiday row — which pins the filter and the union together.

**Verifier's correction.** Upheld as stated, with one caveat on the seeding half: hasSeeded reads and writes UserDefaults.standard through a private key with no injection seam, so a test of seedIfNeeded's two guards mutates global process state shared with every other test in the target. That is a legitimate reason it was skipped, and the fix is a seam (inject the UserDefaults suite) rather than just a test. The recordedDays half has no such excuse — it takes a ModelContext, every suite already builds one, and it is the sole input to both month steppers.

---
### 34. "Delete data → Everything" leaves the Anthropic API key in the Keychain, where it also survives app deletion

**`OfficeDaze/Store/Store.swift:97`** — security — found by: security — confidence: certain

`Store.wipe` iterates `scope.models`, which is `OfficeDazeSchema.all` — seven `PersistentModel` types. The Keychain is not a SwiftData model, so nothing in either wipe scope touches it. `Keychain.delete()` is only ever reachable from `SettingsScreen`'s `SecureField` `onChange` (line 113), i.e. only if the user manually selects the masked text and clears the field. The confirmation dialog in `SettingsScreen` offers a button literally titled "Everything, including N offices" (line 202) and the surrounding copy frames the choice as total loss of app data — but the one item in the app that is a live, billable third-party credential is the one item that is not deleted. Compounding this: iOS does not purge generic-password Keychain items when an app is uninstalled. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps the item out of iCloud backups but does nothing about uninstall persistence, and the code comment at Keychain.swift:56-57 only claims the backup property. So neither "Delete data → Everything" nor deleting the app revokes the key from the device.

**Failure scenario.** User pastes `sk-ant-api03-…` into Settings. Later they hand the phone to a colleague, tap Settings → Delete data… → "Everything, including 2 offices", and confirm. Offices, bookings, attendance, leave and retained screenshots are gone; the Settings screen is then re-opened and the API key row still reads "Key saved" with the key intact in `SecureField`. Equivalently: delete Office Daze from the home screen, reinstall it from TestFlight/Xcode, open Settings — the previous owner's live API key is pre-populated and capture works immediately against their Anthropic account.

```swift
static func wipe(_ context: ModelContext, scope: Scope = .everything) throws {
        for model in scope.models {
            try context.delete(model: model)
        }
        try context.save()
```

**Fix.** Delete the secret alongside the records for `.everything` (and say so in the dialog copy). E.g. in `SettingsScreen.wipe`:

```swift
private func wipe(_ scope: Store.Scope) {
    try? Store.wipe(context, scope: scope)
    if scope == .everything {
        Keychain.apiKey = nil
        apiKey = ""          // keep the field and keyStatus in step
    }
    arrival.refreshRegions()
    NudgeScheduler.refresh(in: context)
}
```

Separately, correct the Keychain.swift comment: `ThisDeviceOnly` excludes iCloud backup, it does not mean the item goes away when the app does.

**Verifier's correction.** Uphold as stated for the wipe path. Trim the uninstall half: state it as observed iOS behaviour (keychain items are not purged on app deletion; Apple reverted the iOS 10.3 beta change) rather than as a documented guarantee, since the finding does not need it. Note also that the wipe leaves the field repopulated but the status line degrades to "Key saved · not used yet", because the parsed Captures that supplied the last-used date were deleted.

---
### 35. The stubbed extractor is blind to two of its three arguments, so nothing checks which image or which date reaches the model

**`OfficeDazeTests/CaptureCoordinatorTests.swift:28`** — test-quality — found by: test-lenience — confidence: certain

`CaptureCoordinator.extractor` has signature `(Data, String, Day) async throws -> ([ParsedBooking], HaikuClient.Usage)` and production calls it as `extractor(data, mediaType, .today)` in `run()`. Every stub in this suite is `{ _, _, _ in ... }` — lines 28, 273, 349, 382, 399 — and the single exception at line 322 captures only `mediaType`. The image `Data` and the `Day` are therefore Mockito-`any()` parameters: the fake returns the same canned bookings whatever it is handed. That would be tolerable if the arguments were verified elsewhere, but they are not: `HaikuClient.userPrompt(today:)` and `HaikuClient.extract(image:mediaType:today:)` have zero references in OfficeDazeTests (only `HaikuClient.decode`, `.schema`, `.systemPrompt` and `.model` are exercised), so the whole path by which `today` and the prepared bytes reach the API is untested end to end.

**Failure scenario.** Change `receive(image:unreadableAs:)` (CaptureCoordinator.swift) from `lastInput = (prepared.data, prepared.mediaType)` to `lastInput = (data, prepared.mediaType)` — i.e. keep the original camera bytes but the detected type. `mediaTypeFollowsTheBytes` still passes because it only reads the second argument, and every other test passes because the fake ignores the first. The suite is fully green while a 12MP photographed confirmation is posted at 11,907,424 bytes and the API returns `400 … image exceeds 10 MB maximum` — the exact regression PhotoImport was written to fix. Independently: change the call to `extractor(data, mediaType, Day(2020, 1, 1))`. Nothing fails, yet `userPrompt(today:)` is the only anchor the model has for resolving a year absent from an otherwise legible date, so a screenshot printing "5 Aug" is filed in 2020.

```swift
/// Nothing reaches the network.
    func stub(_ bookings: [ParsedBooking]) {
        coordinator.extractor = { _, _, _ in (bookings, CaptureSamples.usage) }
    }
```

**Fix.** Make the fake argument-aware in the way `Seen` already demonstrates: record all three arguments and assert them. e.g. add a `final class Sent: @unchecked Sendable { var image: Data?; var mediaType: String?; var today: Day? }`, have `stub` capture into it, and add a test asserting `sent.image == CaptureSamples.pixel` (the 1×1 PNG passes through `PhotoImport.prepare` untouched, per `smallPNGPassesThrough`) and `sent.today == Day.today`. Separately, add a direct test of `HaikuClient.userPrompt(today: Day(2026, 8, 4))` asserting the date appears in the prompt text.

**Verifier's correction.** Uphold as a coverage gap, not a live defect, at medium. Corrected statement: the coordinator's stub discards the first and third arguments in all six stubs, so no test pins which byte buffer or which Day crosses the extractor boundary; both are cheaply assertable (capture the arguments in a Seen-style box, as line 321 already does for mediaType, and assert `seen.data == CaptureSamples.pixel` and `seen.today == .today`). The reviewer's phrase 'so a screenshot printing "5 Aug" is filed in 2020' overstates what is demonstrated — that is the consequence of a hypothetical future edit, not of the code as it stands.

---
### 36. The all-day calendar span asserts only the flag, hiding a UTC-midnight start that files the event on the wrong day west of UTC

**`OfficeDazeTests/HandoffTests.swift:355`** — test-quality — found by: test-lenience — confidence: likely

`CalendarWriter.span` returns `(midnight, midnight, true)` for the all-day case, where `midnight` is `entry.day.startOfDayUTC` — an instant, not a local date. `CalendarWriter.apply` sets `event.startDate = span.start` with `event.timeZone` left nil, so EventKit interprets it in the default calendar's time zone. The test asserts nothing but `.isAllDay`, although the correct start is exactly knowable. The timed branch at line 348 has the same weakness in the other direction: it asserts only `end - start == 8 * 3600`, never the absolute instants, even though production deliberately rebases onto `TimeZone.current` (`var calendar = Day.calendar; calendar.timeZone = .current`).

**Failure scenario.** Device in America/New_York. A booking on 2026-08-05 whose times the capture could not read produces `startDate = 2026-08-05T00:00Z`, which is 2026-08-04 20:00 EDT, so the all-day event appears on 4 August — the user goes in on the wrong day. `allDayWhenUnread` passes. Equally, delete the line `calendar.timeZone = .current` from `CalendarWriter.span`: an 09:00–17:00 booking is then written at UTC midnight + 9h, i.e. 10:00–18:00 in London during BST. `span()` still passes because the eight-hour difference is unchanged.

```swift
@Test("Unread or nonsense times become an all-day event, never a guess")
    func allDayWhenUnread() {
        #expect(CalendarWriter.span(entry(start: nil, end: nil)).isAllDay)
```

**Fix.** Assert the instants, not just the flags, against a fixed zone. Give `CalendarWriter.span` an injectable `TimeZone` (defaulting to `.current`) as the rest of the codebase injects `today`, then assert e.g. `span.start == ISO8601DateFormatter().date(from: "2026-08-05T09:00:00+01:00")` for Europe/London and `span.start == <local midnight>` for the all-day case. Add a case in a negative-offset zone (America/New_York) so the day-shift is caught.

**Verifier's correction.** Uphold. Sharpen the framing: the certain part is that both span tests assert relative properties where the absolute instants are fully determined (HandoffTests.swift:348 and :355), and the `calendar.timeZone = .current` line at CalendarWriter.swift:69 is provably unpinned by any test. The all-day-lands-on-the-wrong-day consequence is a strong inference from the two branches using different midnights, not something I could execute here; state it as an inconsistency between CalendarWriter.swift:63 and :68-72 rather than as a confirmed EventKit rendering.

---
### 37. The wipe tests check four of the seven models, and the fixture contains no rows for the other three

**`OfficeDazeTests/StoreTests.swift:555`** — test-coverage — found by: test-lenience — confidence: certain

`OfficeDazeSchema.all` lists seven models. `Store.Scope.records` is documented as covering "the arrival ledger and the retained capture originals", and `.everything` covers all seven. Both tests assert only `Office`, `DeskBooking`, `AttendanceDay` and `LeaveDay`. `SeedData.populate` inserts no `PlannedDay`, `ArrivalAlert` or `Capture` rows, so those three counts would be zero before the wipe as well — the assertions that are made are vacuous for them, and the assertions that would not be vacuous are absent. `Capture.asset` is `@Attribute(.externalStorage)` holding the user's original screenshots and photographs, which is the one thing a wipe most obviously has to remove.

**Failure scenario.** Change `Scope.records.models` to `OfficeDazeSchema.all.filter { $0 != Office.self && $0 != Capture.self }` (a plausible "keep the cost history" edit), or add a new `@Model` to `OfficeDazeSchema.all` and forget it in a future scope filter. `wipeRecordsOnly` and `wipe` both stay green while "Clear records" leaves every captured screenshot — photographs of confirmation emails, with names and desk numbers in them — on disk.

```swift
let counts = [
            try context.fetchCount(FetchDescriptor<Office>()),
            try context.fetchCount(FetchDescriptor<DeskBooking>()),
            try context.fetchCount(FetchDescriptor<AttendanceDay>()),
            try context.fetchCount(FetchDescriptor<LeaveDay>()),
        ]
```

**Fix.** Insert a `PlannedDay`, an `ArrivalAlert` and a `Capture` (with a non-nil `asset`) before each wipe, then assert every model in `OfficeDazeSchema.all` is empty afterwards — for `.records`, everything but `Office`. A count taken over a table that was empty to begin with proves nothing.

**Verifier's correction.** Uphold as stated. One clarification worth carrying: the fix is in the fixture as much as the assertion — inserting a PlannedDay, an ArrivalAlert and a Capture (with a non-nil asset) before the wipe is what makes the missing counts non-vacuous. As written, adding `fetchCount(FetchDescriptor<Capture>()) == 0` to either test would pass without exercising anything.

---


## LOW

### 38. Code coverage is switched off in the only shared scheme, so the brief's ≥80% bar has never been measured

**`OfficeDaze.xcodeproj/xcshareddata/xcschemes/OfficeDaze.xcscheme:25`** — test-coverage — found by: test-coverage — confidence: certain

The `<TestAction>` element carries no `codeCoverageEnabled` attribute. Xcode defaults that to NO, so `xcodebuild test -scheme OfficeDaze` produces no .xccovreport and no coverage figure — locally or in CI. The project brief requires ≥80% line coverage; nothing in the repository can currently produce the number, let alone gate on it. My own file-by-file attribution (see notes) puts the real figure near 41% of production lines, which is less than half the bar. This is the finding that hides every other finding below it: with coverage on, the 3,431 untested lines of Screens/ and DesignSystem/ would have shown up on the first run.

**Failure scenario.** Run `xcodebuild test -scheme OfficeDaze -destination 'platform=iOS Simulator,name=iPhone 17'`. The 220 tests pass and the build log reports no coverage data at all; `xcrun xccov view --report <result>.xcresult` fails with "no code coverage data found". A reviewer asked "are we at 80%?" has no way to answer, and the true answer is roughly 41%.

```swift
<TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
```

**Fix.** Add `codeCoverageEnabled = "YES"` to the `<TestAction>` attributes, and scope it to the app target so DesignSystem/Screens are counted:
```xml
<TestAction
   buildConfiguration = "Debug"
   codeCoverageEnabled = "YES"
   onlyGenerateCoverageForSpecifiedTargets = "YES"
   ...>
   <CodeCoverageTargets>
      <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "AA0000000000000000000010" BuildableName = "OfficeDaze.app" BlueprintName = "OfficeDaze" ReferencedContainer = "container:OfficeDaze.xcodeproj"/>
   </CodeCoverageTargets>
</TestAction>
```

**Verifier's correction.** Corrected: the shared scheme does not enable code coverage, so a plain `xcodebuild test -scheme OfficeDaze` records none. That is a one-attribute config nit, not a compliance failure: no coverage requirement exists anywhere in the repo, there is no CI at all, and the figure is obtainable on demand with `-enableCodeCoverage YES`. The '≥80% brief bar' and the '41%' figure should both be struck as unsupported.

---
### 39. ArrivalMonitor is 202 untested lines, and the nil-bookingID round trip through userInfo is unasserted on both sides

**`OfficeDaze/Arrival/ArrivalMonitor.swift:170`** — test-coverage — found by: test-coverage — confidence: certain

`ArrivalMonitor` has no test of any kind. Most of it is CoreLocation and UNUserNotificationCenter plumbing that is fairly said to be untestable in a unit target, but `userNotificationCenter(_:didReceive:)` is not plumbing — it is a five-clause guard that decodes three userInfo strings back into typed values and then branches confirm-vs-decline. One specific round trip is broken across the seam and untested at both ends. `ArrivalNotifications.request` writes `bookingID?.uuidString ?? ""` — an empty string for the no-booking case — and `ArrivalTests.requestUserInfo` only ever asserts the non-nil case (`desk.id.uuidString`). The handler reads it back with `UUID(uuidString: "")`, which returns nil, and then `else if let bookingID` silently does nothing for a decline. So the unbooked-arrival path through the notification actions is unverified end to end, and the empty-string sentinel is asserted nowhere.

**Failure scenario.** An arrival at an office with nothing booked posts the `.unbooked` category (this part is covered, `ArrivalLedgerTests.unbookedRepeats`). Change line 218 to `bookingID?.uuidString ?? "none"` — a reasonable-looking tidy-up — and every test still passes. `UUID(uuidString: "none")` is still nil so confirm still works by luck; but change it to any 36-character placeholder and `confirmAttendance` writes an `AttendanceDay` whose `bookingID` points at a booking that does not exist, and nothing in the suite notices.

```swift
let bookingText = info[ArrivalNotifications.UserInfo.bookingID] as? String
        let bookingID = bookingText.flatMap(UUID.init(uuidString:))
```

**Fix.** Two cheap steps. (1) Extend `ArrivalTests.requestUserInfo` with the nil case: build a request with `bookingID: nil` and `#expect(info[UserInfo.bookingID] as? String == "")`, then `#expect(UUID(uuidString: info[...] as? String ?? "") == nil)` — pinning both ends of the sentinel. (2) Extract the handler's decode into a testable static, e.g. `ArrivalNotifications.route(actionIdentifier:userInfo:) -> Route?` returning `.confirm(officeID:day:bookingID:)` / `.decline(bookingID:)` / nil, and assert it for: confirm with a booking, confirm with an empty bookingID, decline with no bookingID (must be nil, not a no-op that looks like success), an unknown action identifier, and a malformed day string.

**Verifier's correction.** Corrected: the delegate body is not merely untested but untestable in a unit target, because UNNotificationResponse cannot be constructed — closing this properly needs a refactor (a pure routing function over the userInfo dictionary), not just a test. The one thing that is testable today and genuinely missing is a single assertion in ArrivalTests.requestUserInfo for the nil case: `#expect(info[UserInfo.bookingID] as? String == "")`, pinning the sentinel that the handler relies on decoding back to nil. Severity low on that basis.

---
### 40. `nonisolated(unsafe)` on NudgeScheduler's injection points discards isolation the type already has for free

**`OfficeDaze/Arrival/NudgeScheduler.swift:44`** — concurrency — found by: concurrency-swift6 — confidence: certain

`NudgeScheduler` is already `@MainActor`, so plain `static var schedule` / `withdraw` would be main-actor-isolated and fully checked — no annotation needed, and both the production caller (`refresh`, itself `@MainActor`) and every test that swaps them (`NudgeSchedulerTests`, a `@MainActor` suite) are on the main actor today. `nonisolated(unsafe)` therefore buys nothing and costs the one check that matters: it makes these two mutable globals writable and readable from any isolation domain without the compiler saying a word. Contrast `ArrivalLedger.post` / `ArrivalLedger.withdraw` (ArrivalLedger.swift:18, 24), which serve exactly the same test-seam purpose and carry no such annotation. I could not demonstrate a live race — hence low severity — but this is a silencing annotation sitting on shared mutable state in a codebase that otherwise relies on Complete checking to catch precisely this.

**Failure scenario.** Not reachable today. The trap is the next change: any nonisolated helper or `Task.detached` that reads `NudgeScheduler.schedule` — or a future non-`@MainActor` test suite that assigns it — compiles clean under Complete checking and races the main actor's write, with the notification silently going to the wrong sink or a torn closure reference.

```swift
nonisolated(unsafe) static var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request)
    }
    nonisolated(unsafe) static var withdraw: () -> Void = {
```

**Fix.** Drop `nonisolated(unsafe)` from both. The enclosing `@MainActor` on the enum already isolates them correctly, and if that produces an error at some call site, that error is the bug report you want.

---
### 41. Cancelling the scanner mid-shutter still fires a full capture: the photo Task has no handle and outlives the view

**`OfficeDaze/Capture/BookingScanner.swift:169`** — concurrency — found by: concurrency-swift6 — confidence: likely

`capture(from:)` starts an unstructured `Task` around `scanner.capturePhoto()` and keeps no handle to it. Nothing cancels it and nothing checks `Task.isCancelled` after the await, so dismissing the `fullScreenCover` while the shutter is in flight does not stop it: on resumption the task calls `onCapture(data)` — which is HomeScreen's `Task { await capture.receive(photo: data) }` (HomeScreen.swift:166) — and `onFinish()` on a view that is already gone. `ScanLock` itself is clean (it is a struct mutated only from the `@MainActor` coordinator, and `isLocked` is set synchronously before the await), so the defect is purely the unmanaged task, not the lock. The error branch is worse behaved still: it calls `lock.reset()` and `try? scanner.startScanning()` on a dismissed controller, with the failure swallowed by `try?`.

**Failure scenario.** User points the phone at a booking confirmation; `ScanLock` fires on its own, `capture(from:)` runs, scanning stops and the caption changes to 'Reading the booking…'. That caption is exactly the cue that makes a user who did not mean to fire reach for Cancel — they tap it during the few hundred milliseconds `capturePhoto()` takes. The cover dismisses, then the task resumes, calls `onCapture(data)`, and the capture sheet opens on the home screen with a billed Haiku call already on its way for a shot the user cancelled.

```swift
Task {
                do {
                    let photo = try await scanner.capturePhoto()
```

**Fix.** Hold the handle on the coordinator (`private var shot: Task<Void, Never>?`), assign it here, `guard !Task.isCancelled` after the `capturePhoto()` await and before `onCapture(data)`, and cancel it when the scanner goes away — either from `ScannerHost.viewWillDisappear` via a callback, or from a `.task`/`onDisappear` on the SwiftUI side. Guard the catch branch on `isCancelled` too, so a cancelled shot does not try to restart scanning on a dismissed controller.

**Verifier's correction.** The code facts hold — unstructured Task at BookingScanner.swift:169 with no handle, no cancellation, and unconditional onCapture/onFinish at 179-180 — but the claimed outcome (a billed Haiku call after Cancel) is contingent on DataScannerViewController.capturePhoto() still resolving successfully after dismissal and the second stopScanning() in viewWillDisappear. If it throws instead, the flow lands in the catch at 181-189 and nothing user-visible happens. Report it as an uncancellable task that calls back into a dismissed view, not as a confirmed billed call. Severity low.

---
### 42. CaptureCoordinator.receive(url:) — the share-sheet intake, the app's primary way in — is never called by a test

**`OfficeDaze/Capture/CaptureCoordinator.swift:83`** — test-coverage — found by: test-coverage — confidence: certain

`CaptureCoordinatorTests` is otherwise excellent — 25 tests covering the phase machine, retry, generation-guarded cancellation, alias learning and the capture record — and it drives every one of them through `receive(data:filename:)` or `receive(photo:)`. `receive(url:)` is never called. Yet it is the entry point the class's own header comment names as the reason it exists ("iOS launches the app *with* the shared file"), it is what `OfficeDazeApp`'s `.onOpenURL` calls, and it contains logic the other two intakes do not: security-scoped resource acquisition with a `defer` release, and a failure branch whose error message depends on a ternary over `url.pathExtension.isEmpty`. That ternary's empty-extension arm — which produces the user-visible string "Office Daze can't read a .FILE file." — is untested, and so is the whole scoped-resource pairing.

**Failure scenario.** A user shares an extension-less file from a third-party app. `Data(contentsOf:)` fails, and the sheet reads "Office Daze can't read a .FILE file." — a message that names a file type that does not exist. Nothing catches it, because the only two `unsupportedFile` assertions in the suite (`unreadableFile`, which asserts `.unsupportedFile("pdf")`) go through `receive(data:filename:)`, which reaches the error by a different route and never evaluates this ternary.

```swift
func receive(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            phase = .failed(.unsupportedFile((url.pathExtension.isEmpty ? "file" : url.pathExtension)))
            return
        }
```

**Fix.** Write the fixture to a temp URL and drive the real entry point:
```swift
@Test("A shared file is read from its URL")
func receivesFromURL() async throws {
    stub(CaptureSamples.one)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
    try CaptureSamples.pixel.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    await coordinator.receive(url: url)
    #expect(coordinator.current?.deskID == "CO03C407")
}
```
Add a second case pointing at a non-existent extension-less URL and assert the message, which pins the ternary.

**Verifier's correction.** Corrected scenario: the '.FILE' message requires `Data(contentsOf:)` to fail, which needs a denied or already-revoked security-scoped URL, not merely a missing extension — an extension-less file that reads successfully takes a different path and correctly reports .unreadableImage. Worth adding that this is easy to cover: write a temp file with the Bash-equivalent of a .png fixture and call receive(url:) with its file URL, plus one call with a URL to a nonexistent extension-less path to pin the 'file' arm. Severity low — the untested code is six lines and the worst outcome is a slightly odd error string.

---
### 43. A corrupt file in a supported format is reported as an unsupported format, and offers no retry

**`OfficeDaze/Capture/CaptureCoordinator.swift:127`** — error-handling — found by: capture-pipeline — confidence: certain

This catch block covers every failure `PhotoImport.prepare` can raise, but it decides the message purely from the filename extension. `prepare` throws `.unreadableImage` from four distinct places — `CGImageSourceCreateWithData` returning nil, a zero-image source, thumbnail creation failing, and destination creation/finalisation failing — none of which imply the *format* is unsupported. The comment ("A PDF says so by name") reasons about the case where the extension is the diagnosis, but the code applies that reasoning to every failure. Because `lastInput` is still nil at this point, `canRetry` is false and the failure card shows only "Enter manually", so the user cannot even retry past a transient encode failure.

**Failure scenario.** The user shares a screenshot that was truncated in transit, `screenshot.png`. `receive(data:filename:)` extracts `ext = "png"`, `CGImageSourceCreateWithData` returns nil, `prepare` throws `.unreadableImage`, and the catch maps it to `.unsupportedFile("png")`. The sheet tells them "Office Daze can't read a .PNG file" — a flatly false statement about the app's most common input format, and one that will send them to enter the booking by hand rather than re-sharing the image.

```swift
phase = .failed(ext.map { CaptureError.unsupportedFile($0) } ?? .unreadableImage)
```

**Fix.** Only claim the format is unsupported when the extension is actually one the app does not handle; otherwise let `.unreadableImage` ("That image couldn't be opened. Try a screenshot or a photo instead.") speak, since it is already the right message:

    private static let readableExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
    ...
    let unsupported = ext.map { !readableExtensions.contains($0.lowercased()) } ?? false
    phase = .failed(unsupported ? .unsupportedFile(ext!) : .unreadableImage)

A sharper alternative is to have `PhotoImport` distinguish "ImageIO does not recognise these bytes at all" from "decode/encode failed midway" and let the coordinator map the two differently.

**Verifier's correction.** Uphold, narrowed to the error text. Drop the retry argument: `retry()` only re-runs `run()` and never re-runs `PhotoImport.prepare`, and every `prepare` failure is deterministic for the same bytes, so offering 'Try again' would be the do-nothing button CaptureSheet.swift:353-355 deliberately hides. The defect is that the catch decides the message from the filename extension for all four `unreadableImage` throw sites — telling a user that a truncated screenshot.png means "Office Daze can't read a .PNG file". Distinguishing the format-is-the-diagnosis case (an extension ImageIO has no decoder for) from a decode/encode failure in a supported format would fix it.

---
### 44. Every image sent to Anthropic is also retained on disk forever, for a feature that does not exist

**`OfficeDaze/Capture/CaptureCoordinator.swift:161`** — privacy — found by: security — confidence: certain

`record(asset:status:usage:)` stores the full prepared image bytes on a `Capture` row (`@Attribute(.externalStorage) var asset: Data?`, Models.swift:292) on both the success path (line 161) and the failure path (line 173). I grepped the whole repo for readers of that property: the only reference outside the writer and the model declaration is a test assertion, `OfficeDazeTests/CaptureCoordinatorTests.swift:343`. There is no "view original screenshot" screen anywhere in `Screens/`, so the justification in the doc comment ("Keeps the original so \"view original screenshot\" works") describes a feature that was never built. Meanwhile the app is by design pointed at a workplace booking system: these are photographs of an employer's screen, holding building names, floors, desk ids and often colleagues' rows in the same table. They land in the SwiftData external-storage directory in the app container, which is included in iCloud/iTunes backups by default (no `NSURLIsExcludedFromBackupKey`), and which SwiftData protects only to `NSFileProtectionCompleteUntilFirstUserAuthentication`. There is no cap, no expiry, no per-capture delete, and no UI or Info.plist string that tells the user the pictures are kept — `NSCameraUsageDescription` says only "is not saved to your photos", which reads as reassurance that the picture is not retained. The only way to remove them is the blunt Settings → Delete data.

**Failure scenario.** User captures one booking a week for a year, plus retries. After 60 captures at ~1.5MB of prepared JPEG each, ~90MB of photographs of their employer's desk-booking system sit in the app container and in every iCloud backup, indefinitely. Nothing in the app ever displays them, and nothing offers to remove a single one. A failed capture (`record(asset: data, status: .failed, usage: nil)`, line 173) retains its image too, so an accidentally-shared photo of something else entirely is also kept permanently.

```swift
captureID = record(asset: data, status: .parsed, usage: usage)
```

**Fix.** Either build the reader or stop keeping the bytes. Cheapest correct change is to drop the asset and keep only the metering the Settings screen actually uses (`receivedAt`, `inputTokens`, `outputTokens`, `status`):

```swift
let capture = Capture(
    receivedAt: .now,
    asset: nil,
    status: status,
    …
)
```

If the original really is wanted, bound it: keep at most the last N (or the last 30 days) and prune in `record`, exclude the store's external-data directory from backup, and add a line to the Settings copy saying the images are kept on the device and for how long.

**Verifier's correction.** Correct the magnitude: prepared images are capped at 1568px / JPEG q0.9 (PhotoImport.swift:25,35), so realistic retention is a few hundred KB per capture (up to 4MB only on the untouched-passthrough branch at PhotoImport.swift:54-57), not ~1.5MB each. Also state the retention as deliberate-but-orphaned rather than accidental: Store.swift:81-83 names the retained originals as part of a wipe, and OfficeDazeTests/CaptureCoordinatorTests.swift:343 asserts it on purpose. The actionable defect is that BookingDetailScreen.swift:170-171 promises a "View original" row that does not exist, so the data is kept for nothing — either build the reader or stop writing the bytes.

---
### 45. The entire Haiku request — base64 of up to 4 MB plus JSON serialisation — is built on the main actor

**`OfficeDaze/Capture/HaikuClient.swift:34`** — concurrency — found by: concurrency-swift6 — confidence: certain

I confirmed from the actual compile flags (xcodebuild emits `-enable-upcoming-feature NonisolatedNonsendingByDefault`, from `SWIFT_APPROACHABLE_CONCURRENCY = YES`) that `nonisolated func extract(...) async` is `nonisolated(nonsending)`: it runs on the *caller's* executor, not the generic one. Its caller is `CaptureCoordinator.run()`, which is `@MainActor`. So everything in `extract` up to the `session.data(for:)` suspension executes on the main thread: `image.base64EncodedString()` on a `Data` of up to `PhotoImport.maxBytes` (4,000,000 bytes) producing a ~5.3 MB `String`, and then `JSONSerialization.data(withJSONObject:)` scanning and escaping that 5.3 MB string into the request body. The same applies to the extractor closure itself (CaptureCoordinator.swift:60-66), whose body up to its first await is main-actor bound regardless of the feature flag — so `Keychain.apiKey`, a synchronous `SecItemCopyMatching` XPC round trip to securityd, is also on main. This is the compiler-invisible half of a split the author clearly intended to make: `PhotoImport.prepare` carries the comment "CPU-bound — decodes and re-encodes an image. Call it off the main actor" and is correctly pushed onto `Task.detached`, while the equally CPU-bound base64/JSON step silently stayed on main because `nonisolated` no longer means "runs off the caller's actor" under this build setting.

**Failure scenario.** User shares a 3.5 MB PNG screenshot (acceptable format, <= 1568px, so `PhotoImport.prepare` returns it untouched). `run()` awaits `extractor` on the main actor; `extract` base64-encodes 3.5 MB into a ~4.7 MB String and `JSONSerialization` serialises it — all synchronously on the main thread. The 'Reading with Claude AI' sheet's `ProgressView` freezes for the duration and the checklist animation drops frames, on the one screen whose entire purpose is to look busy while the network call runs.

```swift
request.httpBody = try JSONSerialization.data(withJSONObject: body(
            image: image, mediaType: mediaType, today: today
        ))
```

**Fix.** Build the body off the main actor. Either mark the hot path `@concurrent` (`@concurrent nonisolated func extract(...) async`), or split out request construction and run it detached, e.g. `let request = try await Task.detached { try Self.makeRequest(image:mediaType:today:) }.value` before awaiting `session.data(for:)`. Do the same for the `Keychain.apiKey` read in the default `extractor` closure. As a general guard, note that any `nonisolated func ... async` in this project now inherits the caller's isolation — `Geocoding.coordinates` and `CalendarWriter` are in the same position.

**Verifier's correction.** Correct claim, wrong magnitude and one wrong sub-claim. The request body IS built on the main actor because SWIFT_APPROACHABLE_CONCURRENCY = YES makes `nonisolated func extract` nonisolated(nonsending) (verified by compiling the same shape with and without the flag). But the closure prefix is main-bound BECAUSE of the flag, not 'regardless of' it; and the measured cost is ~36 ms for the 3.5 MB worst case (~45 ms at the 4 MB cap), single-digit ms for the normal downsized payload — a few dropped frames, not the described freeze. The Keychain SecItemCopyMatching XPC round trip on main is the other half and is real. Severity low.

---
### 46. Three of decode's six throw sites have no #expect(throws:) — malformed-response handling is half tested

**`OfficeDaze/Capture/HaikuClient.swift:241`** — test-coverage — found by: test-coverage — confidence: certain

`HaikuClient.decode` throws from six places. Three are asserted: `.refused` (CaptureTests:162), the `max_tokens` cut-short (CaptureTests:168), and the two empty-result messages (CaptureTests:149-154). Three are not: "the response was not JSON" (line 241), "no text block in the response" (line 262), and "could not decode the extraction" (line 269). All three are reachable from a live API — a 200 with an HTML error page from a proxy hits the first, a response whose only content block is a `thinking` or `tool_use` block hits the second, and a structured-outputs response whose text block does not conform hits the third. Note also that the two tested empty-result paths only assert `CaptureError.self`, not which of the two distinct messages came back, so the `decoded.bookings.isEmpty` ternary at line 278 is untested in both directions as a *discriminator*.

**Failure scenario.** Change line 260's predicate from `$0["type"] as? String == "text"` to `== "message"`. Every capture test still passes, because every fixture envelope in `CaptureMappingTests` is built by `envelope(_:)` which hardcodes one text block and the two tests that exercise a content-less response (`refusal`, `truncated`) throw at lines 247 and 256 before reaching line 260. In production every capture would fail with "Nothing usable came back: no text block in the response".

```swift
guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.modelReturnedNothingUsable("the response was not JSON")
        }
```

**Fix.** Add three cases to `CaptureMappingTests`:
```swift
#expect(throws: CaptureError.self) { try HaikuClient.decode(Data("<html>502</html>".utf8)) }
#expect(throws: CaptureError.self) { try HaikuClient.decode(Data(#"{"content":[{"type":"thinking"}],"usage":{}}"#.utf8)) }
#expect(throws: CaptureError.self) { try HaikuClient.decode(Data(#"{"content":[{"type":"text","text":"{\"rows\":[]}"}],"usage":{}}"#.utf8)) }
```
And tighten the two existing empty-result assertions to match on the message, so the `decoded.bookings.isEmpty` branch is pinned.

**Verifier's correction.** Corrected demonstration — the offered mutation is caught, but a real surviving one exists: change line 260 from `blocks.first(where: { $0["type"] as? String == "text" })?["text"]` to `blocks.first?["text"]`. Every fixture's first (and only) block is a text block, so all 220 tests still pass; in production a response that leads with a `thinking` or `tool_use` block yields nil text or the wrong text and the capture fails with 'could not decode the extraction'. That is the branch worth pinning. Severity drops to low: the three untested throws are all mapped to the same user-visible error family and none of them corrupts data.

---
### 47. Keychain writes discard their OSStatus, and the "Key saved" row reads view state rather than the Keychain

**`OfficeDaze/Capture/Keychain.swift:53`** — security — found by: security — confidence: likely

`write` throws away both status codes. `SecItemUpdate`'s result is only compared against `errSecSuccess` — every non-success is treated as "not there yet, add it", including `errSecInteractionNotAllowed`, `errSecAuthFailed` and `errSecMissingEntitlement`. `SecItemAdd`'s `OSStatus` is discarded entirely (it is a C import, so Swift issues no unused-result warning). `delete` likewise ignores its status. Nothing upstream can observe a failure: `Keychain.apiKey`'s setter is `Void`. The Settings screen then compounds it — `keyStatus` (line 48) derives "Key saved · …" from the `@State private var apiKey` string, i.e. from what is in the text field, and never re-reads `Keychain.apiKey`. The doc comment at SettingsScreen.swift:115-118 explicitly claims this row exists so the user can "tell a saved key from a typo", but the row cannot distinguish a persisted key from a key whose write failed, and it turns green on the first character typed. Also note there is no validation that the string is even shaped like a key (`sk-ant-…` is a placeholder only), so the row reads "Key saved" for input that can only ever produce a 401.

**Failure scenario.** Whatever makes the write fail — a signing/entitlement misconfiguration returning `errSecMissingEntitlement`, or a keychain in a state that returns `errSecInteractionNotAllowed` — the user sees a green "Key saved · not used yet" the moment they finish typing. They dismiss Settings satisfied. The next capture calls `Keychain.apiKey` in `CaptureCoordinator`'s default extractor (line 62), gets `nil`, and the sheet says "No API key yet. Add one in Settings" — pointing them back at a screen that insists the key is saved. There is no diagnostic anywhere, because the app has no logging at all.

```swift
let updated = SecItemUpdate(
            query() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updated != errSecSuccess else { return }

        SecItemAdd(query([
```

**Fix.** Make the write report, and make the status row read back from the Keychain rather than from the field:

```swift
@discardableResult
private static func write(_ value: String) -> Bool {
    let data = Data(value.utf8)
    let updated = SecItemUpdate(query() as CFDictionary,
                                [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return true }
    guard updated == errSecItemNotFound else { return false }   // don't paper over a real error
    let added = SecItemAdd(query([
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]) as CFDictionary, nil)
    return added == errSecSuccess
}
```

Then in `SettingsScreen`, drive `keyStatus.saved` off `Keychain.apiKey != nil` refreshed after each write, so "Key saved" is an observation rather than an assumption.

**Verifier's correction.** Restate as: Keychain.write/delete discard every OSStatus and the setter is Void, so there is no channel by which a Keychain failure could ever be surfaced. Drop the errSecMissingEntitlement scenario — this item uses the default access group and needs no Keychain Sharing entitlement, so that status is not reachable on a correctly signed build; the finding has no demonstrated trigger. Drop the claim that the status row cannot tell a working key from a typo: SettingsScreen.swift:50-62 derives "last used <date>" from Captures with status == .parsed, which is direct evidence the key worked, and the pre-first-use state honestly reads "not used yet".

---
### 48. An office name that tokenises to nothing can never be matched, and its alias is re-appended on every capture

**`OfficeDaze/Capture/OfficeMatcher.swift:71`** — correctness — found by: capture-pipeline — confidence: likely

`tokens(_:)` drops single-character tokens, pure-numeric tokens, and the noise words `the`/`office`/`building`/`floor`/`level`. I verified that this can produce an empty set for real strings: `tokens("Building")`, `tokens("The Building")`, and `tokens("Level 5")` are all `[]`. `matches(printed:alias:)` short-circuits on `!tokens.isEmpty`, so for such a name it returns false against *any* alias, including a byte-identical one, and `match()` bails at `guard !parts.isEmpty`. `CaptureCoordinator.remember(_:as:)` guards its append with `!target.aliases.contains(where: { OfficeMatcher.matches(printed, $0) })` — a predicate that can never become true for these names — so the alias is appended again on every capture, and the sheet asks the same question forever. The `aliases` array grows without bound in SwiftData. The class of names affected is narrow, which is why I'm rating this low, but the loop is unconditional once you're in it.

**Failure scenario.** A booking system prints the office column as `Level 5` (or a single confirmation prints `Building: The Building`). Capture 1: no match, sheet asks, user picks "Euroclear London", `remember("Level 5", as: euroclearID)` appends `"Level 5"` to `aliases`. Capture 2 of the same document: the alias rule evaluates `matches("Level 5", "Level 5")` -> `tokens("Level 5")` is `[]` -> false, so nothing claims it; the token rule bails on the empty `parts`; the sheet asks again, and `remember` appends a second `"Level 5"`. After ten captures `aliases == ["Level 5"] * 10` and the user has answered the same question ten times — the exact behaviour the `aliases` doc comment calls "the app failing to listen".

```swift
static func matches(_ printed: String, _ alias: String) -> Bool {
        let tokens = tokens(printed)
        return !tokens.isEmpty && tokens == Self.tokens(alias)
    }
```

**Fix.** Fall back to a normalised whole-string comparison when tokenisation yields nothing, so an alias that was taught is always recognised:

    static func matches(_ printed: String, _ alias: String) -> Bool {
        let a = tokens(printed), b = tokens(alias)
        if a.isEmpty || b.isEmpty {
            return printed.compare(alias, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return a == b
    }

Separately, `remember` should be defensive about duplicates regardless (`aliases = Array(Set(aliases))` or a plain case-insensitive string check before appending). While you're here: `tokens` is diacritic-sensitive, so an office typed as "Zurich" will not match a printed "Zürich" (I confirmed `tokens("Zürich") == ["zürich"]` vs `["zurich"]`) — that fails safe by asking, but `.diacriticInsensitive` folding would remove a needless question.

---
### 49. AttendanceGauge's shrink-to-fit scaling is dead code — the Canvas is pinned to boxSize so the scale factor is always exactly 1

**`OfficeDaze/DesignSystem/AttendanceGauge.swift:39`** — maintainability — found by: swiftui-architecture — confidence: certain

`draw(in:size:)` computes `let scale = size.width / GaugeMetrics.boxSize.width` and applies `context.scaleBy(x: scale, y: scale)`, with the comment "honour whatever width we are given so the dial can shrink on a small phone without re-deriving every radius". But the `Canvas` it draws into is given `.frame(width: GaugeMetrics.boxSize.width, height: GaugeMetrics.boxSize.height)` on lines 40–43, and the enclosing `ZStack` is pinned to the same fixed size on line 95. `size.width` is therefore always 256, `scale` is always 1.0, and the dial cannot shrink for anything — a narrow phone, a Slide Over pane, or an accessibility text size that squeezes the card.

This matters because the comment reads as a guarantee that has been designed for and is being maintained; nobody reviewing a layout change will discover it is inert until the dial overflows on a device the fixed 256pt no longer fits.

**Failure scenario.** `GaugeMetrics.boxSize.width` is 256. `Metrics.screenPadding` is 16 per side and the gauge card adds 16 per side, so the gauge needs a container of at least 256 + 64 = 320pt. On any surface narrower than 320pt — an iPad Slide Over pane at its minimum, or a future compact width — the Canvas keeps its hard 256pt frame instead of scaling down, and gets clipped by the Card's `clipShape` rather than shrinking as the comment promises.

```swift
Canvas { context, size in draw(in: &context, size: size) }
                .frame(
                    width: GaugeMetrics.boxSize.width,
                    height: GaugeMetrics.boxSize.height
                )
```

**Fix.** Either make it real — replace the fixed frames with `.aspectRatio(GaugeMetrics.boxSize, contentMode: .fit)` on the Canvas and `.frame(maxWidth: GaugeMetrics.boxSize.width)` on the ZStack, so `size.width` genuinely varies and the label overlays use a `GeometryReader`-derived width rather than `boxSize.width` — or delete the `scaleBy` and correct the comment to say the dial is a fixed 256×208 that must fit.

**Verifier's correction.** The claimed failure — clipping on a narrow surface — is not currently reachable and should be dropped. On the narrowest supported iPhone (375pt) the gauge's container is 375 − 2×16 screen padding − 2×16 card padding = 311pt of inner width against a 256pt box, and iOS 26 supports nothing narrower. The real finding is the one that is provable: the scale factor is structurally pinned to 1, so a comment that reads as a maintained guarantee is inert, and a future layout change would discover that only by overflowing.

---
### 50. `BankHolidays.exceptional` can only add holidays, never move or remove one — so 2022's Spring bank holiday is on the wrong date and any future moved holiday will be double-counted

**`OfficeDaze/Domain/BankHolidays.swift:17`** — correctness — found by: domain-logic — confidence: certain

The design splits bank holidays into eight derived and a per-year table of extras, and the table is only ever unioned in (`holidays.append(contentsOf: exceptional[year] ?? [])`). There is no mechanism to suppress a derived holiday. But the two adjustments the UK government has actually made in living memory were *moves*, not additions, and a move is exactly what this shape cannot express.

I ran the algorithm for 2020–2035 and diffed against the GOV.UK England & Wales list. 2024–2035 are correct, including every weekend substitution (2026: 25 and 28 December; 2027: 27 and 28 December; 2028: 3 January). Two historical years are wrong:

- **2022**: the code emits Monday 30 May as the Spring bank holiday. That year it was moved to Thursday 2 June for the Platinum Jubilee, with Friday 3 June added. The table supplies 3 June but cannot delete 30 May or add 2 June.
- **2020**: the code emits Monday 4 May as the Early May bank holiday; it was moved to Friday 8 May for VE Day 75. Same month, so working-day counts survive, but the day itself is wrong.

Easter is the anonymous Gregorian computus, transcribed correctly (`(32 + 2e + 2i − h − k)` has minimum value 0, so Swift's `%` never sees a negative operand), and the `placed` set correctly pushes Boxing Day past a substituted Christmas in every configuration I checked.

**Failure scenario.** May 2022 has 22 weekdays. The correct England & Wales holiday set for that month is just Monday 2 May, giving 21 working days; the code returns {2 May, 30 May}, giving 20. `Quota.calculate` for Month(2022, 5) therefore reports `workingDays == 20` and `eligible` one day low. June 2022 has 22 weekdays; the correct set is {2 June, 3 June} → 20 working days, but the code returns only {3 June} → 21. Both months are reachable through the month stepper for anyone whose store holds a record from 2022 (`MonthRange.earliest` opens the door as far back as the earliest recorded day), which is why this is a defect rather than a curiosity. The forward-looking risk is the shape, not these two years: the next time a holiday is moved, adding it to `exceptional` will produce a month with one bank holiday too many and a target one day too generous.

```swift
static let exceptional: [Int: [Day]] = [
        2022: [Day(2022, 6, 3), Day(2022, 9, 19)], // Platinum Jubilee, State Funeral
        2023: [Day(2023, 5, 8)],                   // Coronation
    ]
```

**Fix.** Make the table able to subtract as well as add, so a move is one entry rather than an impossibility:

```swift
static let exceptional: [Int: (added: [Day], removed: [Day])] = [
    2020: (added: [Day(2020, 5, 8)],  removed: [Day(2020, 5, 4)]),   // VE Day 75
    2022: (added: [Day(2022, 6, 2), Day(2022, 6, 3), Day(2022, 9, 19)],
           removed: [Day(2022, 5, 30)]),                              // Platinum Jubilee, State Funeral
    2023: (added: [Day(2023, 5, 8)],  removed: []),                   // Coronation
]
```

then `Set(holidays).subtracting(removed).union(added).sorted()`. The existing `noneOnWeekends` test already sweeps 2024...2035; extending a spot-check suite to 2020 and 2022 would have caught this.

**Verifier's correction.** Severity low is right, but the justification given for it being "a defect rather than a curiosity" is the weakest part and should be dropped. IPHONEOS_DEPLOYMENT_TARGET is 26.0, so this app cannot have been installed before 2025 and no store can hold a 2022 AttendanceDay/DeskBooking/LeaveDay except by hand-seeded fixture — MonthRange.earliest opens the door, but there is nothing behind it. Re-state the finding on its forward-looking half alone, which is entirely sound: `exceptional` is union-only, the two real-world adjustments in living memory (2020 Early May, 2022 Spring) were both *moves*, and the next move will produce a month with one bank holiday too many and a target one day too generous. The fix shape is a per-year suppression list (or a `moved: [Day: Day]` table) alongside the additions.

---
### 51. Geocoding has no test at all, and its only guard branch is untestable as written

**`OfficeDaze/Domain/Geocoding.swift:15`** — test-coverage — found by: test-coverage — confidence: certain

`Geocoding` is the one file in Domain/ with zero test references — every other type there (Day, Month, BankHolidays, Quota, GaugeMetrics, MonthRange, BookingMerge, LeaveCycle, OfficeColours) is covered, several of them exhaustively. The query-building half of this function is pure and worth pinning: it trims both inputs, drops empties, joins with ", ", and returns nil for an all-empty query. That last branch is the one that matters — it is what stops an office saved with no address and no postcode from geocoding to something arbitrary — and it cannot be tested today because it sits in the same function as the `CLGeocoder` call.

**Failure scenario.** An office is saved with a whitespace-only postcode and an empty address. If the `.filter { !$0.isEmpty }` were dropped, `query` becomes ", " — non-empty, so the guard passes — and CLGeocoder is asked to geocode a bare comma. On some inputs it returns a placemark, `Office.latitude/longitude` get written to a location nowhere near the building, `isLocated` becomes true, and `ArrivalMonitor.refreshRegions` starts monitoring a 50m perimeter around it. The arrival alert then never fires, silently, and no test would have caught the change.

```swift
static func coordinates(postcode: String, address: String) async -> CLLocationCoordinate2D? {
        let query = [postcode, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !query.isEmpty else { return nil }
```

**Fix.** Split the pure part out so it can be asserted without a network call:
```swift
static func query(postcode: String, address: String) -> String? {
    let joined = [postcode, address]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    return joined.isEmpty ? nil : joined
}
```
Then `coordinates` becomes `guard let query = query(...) else { return nil }`, and a test asserts: both present → "EC2R 5BB, 63 Coleman Street"; postcode only → "EC2R 5BB"; both empty → nil; both whitespace-only → nil.

**Verifier's correction.** Corrected: the all-empty guard is fully testable today — it returns at Geocoding.swift:20 before CLGeocoder is touched, so a one-line async test covers it with no network. The finding should read: 'the empty-query guard, the one thing standing between a blank office and an arbitrary geocode, is uncovered despite being trivially coverable' — the excuse offered for the gap is not valid. Only the query-string construction on the non-empty path is genuinely awkward, and that would want the string-building extracted to its own static.

---
### 52. CalendarWriter.write and its update-then-fall-back-to-add rule are untested, though the pure helpers around them are

**`OfficeDaze/Handoff/CalendarWriter.swift:93`** — test-coverage — found by: test-coverage — confidence: certain

`CalendarWriterTests` covers `title`, `location`, `notes`, `span` (including the all-day fallbacks) and `minutes` (including boundary rejections at "24:00" and "8") — good, sharp coverage of everything pure. `write(_:existingEventID:)` and `apply(_:to:in:)`, roughly 40 lines, are untested and never called from a test. That is where the rule the file's header calls out actually lives: because write-only access cannot read events back, a stored `existingEventID` is updated blind, and only if that save throws is a fresh event written. Three of the four `Outcome` cases (`.added`, `.updated`, `.denied`) and both `.failed` sites have no assertion. `StoreTests.editingKeepsTheCalendarEvent` protects the id's *survival* through a booking edit, which is the adjacent concern, not this one. EventKit is genuinely awkward to unit test, so this is partly forced — but the branch structure is not, and it is currently invisible.

**Failure scenario.** Invert the fall-through at line 104 so a failed update returns `.failed` instead of dropping to the add. Every test passes. A user who deleted the calendar event by hand and taps "Add to calendar" again gets "failed" forever, with the booking still holding a `calendarEventID` that resolves to nothing — the precise scenario the comment at lines 101-103 says the fall-through exists for.

```swift
@MainActor
    static func write(_ entry: Entry, existingEventID: String?) async -> Outcome {
        let store = EKEventStore()
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return .denied }
```

**Fix.** Introduce a narrow protocol over the three EKEventStore calls actually used (`requestWriteOnlyAccessToEvents`, `event(withIdentifier:)`, `save(_:span:commit:)`) with the real store as the default conformance, take it as a defaulted parameter on `write`, and assert the four outcomes against a fake: access denied → `.denied`; no existing id → `.added`; existing id that resolves and saves → `.updated`; existing id that resolves but whose save throws → `.added` (the fall-through). `apply` can then be asserted directly on an `EKEvent` for title/location/notes/isAllDay.

**Verifier's correction.** Two corrections. First, the count is worse than stated in one direction and moot in another: none of the four Outcome cases is asserted, not three of four. Second, and decisively for severity, this is not a coverage gap that can be closed as written — write() constructs `EKEventStore()` internally, and requestWriteOnlyAccessToEvents() in a unit-test host is a permission prompt, so there is no seam to stub. Testing the update-then-add rule requires injecting the store (a protocol over the two methods used, event(withIdentifier:) and save(_:span:commit:)). Low, and honestly recorded as a design limitation rather than a missing test.

---
### 53. `UIBackgroundModes: location` is declared but the app never uses background location, which is a documented App Review rejection

**`OfficeDaze/Info.plist:44`** — project-hygiene — found by: robustness-misc — confidence: certain

The Info.plist declares the `location` background mode, and `ArrivalMonitor.init` explicitly sets `manager.allowsBackgroundLocationUpdates = false`. There is no `startUpdatingLocation`, no significant-location-change monitoring, and no `CLBackgroundActivitySession` anywhere in the app — only region monitoring, which iOS relaunches the app for regardless of this key. The plist comment states this outright: "Strictly, region monitoring does not need it... It is here so the capability matches the brief, not because the geofence would fail without it." App Review guideline 2.5.4 rejects apps declaring a background mode they do not exercise, and this one is trivially detectable by static analysis of the binary. Separately, `ITSAppUsesNonExemptEncryption` is absent from both the plist and the `INFOPLIST_KEY_*` build settings, so every TestFlight/App Store upload will stall on the export-compliance question until it is answered by hand.

**Failure scenario.** The first App Store or TestFlight external submission is rejected under 2.5.4 for declaring a background mode the binary never uses, costing a review cycle; every upload before that point also blocks on the missing export-compliance declaration.

```swift
<key>UIBackgroundModes</key>
	<array>
		<string>location</string>
	</array>
```

**Fix.** Delete the `UIBackgroundModes` array — region monitoring wakes the app without it, which the comment already concedes. Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` to both build configurations (the app uses only HTTPS, which is exempt).

**Verifier's correction.** Note that the comment at Info.plist:20-23 is an explicit, reasoned decision rather than an oversight, so this is a "decide before submission" item, not a mistake. Also, the export-compliance half is a prompt rather than a hard block: App Store Connect asks the question once per build and the build is unusable for external TestFlight until it is answered, which is friction rather than a failed upload.

---
### 54. Directions URL percent-encodes with .urlQueryAllowed, which does not escape & or =

**`OfficeDaze/Screens/BookingDetailScreen.swift:220`** — correctness — found by: security — confidence: certain

`CharacterSet.urlQueryAllowed` is the set of characters *legal anywhere in a query string*, which includes the sub-delimiters `& = + ; , $ ' ( ) * ! : @ / ?`. It is the wrong set for encoding a single query *value*: `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` leaves `&` and `=` untouched, so a value containing them splits into extra parameters. `office.name` is free text the user types into `OfficeEditorScreen`, so it routinely contains `&`. This is user-controlled rather than model-controlled, so it is a correctness bug rather than an injection across a trust boundary — but it is the same footgun that becomes one the moment a name reaches this from capture.

**Failure scenario.** User names an office `Bar & Grill House`. `openDirections` builds `http://maps.apple.com/?daddr=51.5155,-0.0922&q=Bar%20&%20Grill%20House`. Maps parses `q` as `Bar ` and then two junk parameters, so the destination pin is labelled "Bar" instead of the office. An office named `Coleman&dirflg=d` silently changes the travel mode Maps opens in.

```swift
let name = office.name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? ""
```

**Fix.** Build the URL with `URLComponents` and let it encode the value, rather than hand-encoding:

```swift
var components = URLComponents(string: "https://maps.apple.com/")!
components.queryItems = [
    URLQueryItem(name: "daddr", value: "\(office.latitude),\(office.longitude)"),
    URLQueryItem(name: "q", value: office.name),
]
if let url = components.url { UIApplication.shared.open(url) }
```

(Also worth switching the scheme to `https` while you are there — the Maps app claims the URL so nothing goes over the wire today, but the plaintext scheme is a needless liability if it ever falls through to Safari.)

**Verifier's correction.** Lead with the parameter-injection consequence, which is verifiable: an office named "Coleman&dirflg=d" appends a real Apple Maps parameter and changes the travel mode Maps opens in; more generally any & in the name truncates the q value and turns the remainder into junk parameters. Soften the pin-label claim — Apple documents q as a search term (and as a label only alongside ll), so whether q affects the destination label in directions mode with a coordinate daddr is unverified. Fix is CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#")), or better, build the URL with URLComponents/URLQueryItem so the encoding is not hand-rolled.

---
### 55. The bookings section header is hard-coded "This month" while the list beneath it is month-steppable

**`OfficeDaze/Screens/HomeScreen.swift:454`** — correctness — found by: swiftui-architecture — confidence: certain

`bookingsSection` renders `SectionHeader(title: "This month")` as a literal, but the list under it is `monthEntries`, which is filtered by the `@State month` that the stepper at the top of the gauge card moves freely in both directions. The empty state four lines below gets this right — `"Nothing recorded for \(month.text)."` — so the screen contradicts itself depending on whether the month happens to have rows in it.

**Failure scenario.** On 7 August 2026, tap the right chevron in the gauge card twice. The gauge card now says "October 2026", the list shows October's bookings, and the section header above them still reads "THIS MONTH". Step back to July and the header claims July's finished bookings are this month's.

```swift
SectionHeader(title: "This month") {
```

**Fix.** Use the month the list is actually showing: `SectionHeader(title: isThisMonth ? "This month" : month.text)`. `isThisMonth` already exists on line 229. (Note `SectionHeader` uppercases the title itself, so `month.text` will render as "OCTOBER 2026", consistent with the existing style.)

---
### 56. Day.mediumText allocates a fresh DateFormatter and Locale for every list row, on every render

**`OfficeDaze/Screens/HomeScreen.swift:661`** — performance — found by: swiftui-architecture — confidence: certain

`Day.formatted(_:)` (OfficeDaze/Domain/Day.swift:86–93) constructs a new `DateFormatter`, a new `Locale(identifier: "en_GB")` and parses a new `dateFormat` string on every call. `DateFormatter` initialisation and format-string parsing are among the most expensive routine operations in Foundation, and this is called straight out of the view body once per row.

Call sites in one HomeScreen pass: `bookingRow` line 661 (`booking.day.mediumText`, once per booking row), `deskless` line 733 (`day.mediumText`, once per deskless row), `dateLine` line 287 (`today.dayAndMonth`), `monthStepper` lines 245 and 253 (`month.text` twice — once for the Text, once for the accessibility label, each a separate `Month.text` call and therefore a separate DateFormatter), and `emptyBookings` line 528. The same pattern recurs in `LeaveScreen.monthStepper` and `BookingDetailScreen`.

**Failure scenario.** A month with 20 recorded days renders 20 `bookingRow`/`deskless` calls plus 3 header calls → 23 DateFormatter + Locale allocations per HomeScreen body pass. Because `body` re-runs on every `@Query` invalidation (see the snapshot finding), answering one "Were you there?" strip pays for all 23 again. Nothing here is cached across renders, and the app's format strings are a fixed set of four.

```swift
Text(booking.day.mediumText)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
```

**Fix.** Cache the formatters in `Day`. Replace the body of `formatted(_:)` with a lookup into a static dictionary keyed by the template:

    private static let formatters: [String: DateFormatter] = ["EEEE d MMMM", "EEE d MMMM", "d MMMM", "MMMM yyyy"].reduce(into: [:]) { out, template in
        let f = DateFormatter()
        f.calendar = Day.calendar; f.timeZone = Day.calendar.timeZone
        f.locale = Locale(identifier: "en_GB"); f.dateFormat = template
        out[template] = f
    }

(or use `Date.FormatStyle`, which is value-typed and cheap). Separately, hoist `month.text` in `monthStepper` into a single `let` so it is not formatted twice.

**Verifier's correction.** Uphold the mechanism, downgrade to low. The claim 'DateFormatter initialisation ... among the most expensive routine operations in Foundation' is true but the finding never crosses from allocation count to demonstrated jank. Note also that line 253's `month.text` appears twice in the same ternary branch, so the per-pass count is slightly higher than stated — which does not change the verdict.

---
### 57. ForEach over the weekday headings uses id: \.self on a collection with duplicate values ("T" and "S" each appear twice)

**`OfficeDaze/Screens/LeaveScreen.swift:102`** — correctness — found by: swiftui-architecture — confidence: likely

`["M", "T", "W", "T", "F", "S", "S"]` with `id: \.self` produces the identity sequence M, T, W, T, F, S, S — "T" collides at indices 1 and 3, "S" at indices 5 and 6. `ForEach` requires identifiers to be unique across the collection; SwiftUI logs "the ID T occurs multiple times within the collection, this will give undefined results!" at runtime and the diffing behaviour for the colliding elements is unspecified.

The headings are a fixed 7-column row sitting directly above a 7-column `LazyVGrid`, so any element the diff drops or mis-associates misaligns the day letters against the columns they label.

**Failure scenario.** Every render of LeaveScreen emits a runtime ForEach identity warning to the console. Because identity is what SwiftUI uses to decide which subview corresponds to which element, the 2nd/4th ("T") and 6th/7th ("S") headings are not reliably distinguishable to the framework — behaviour that is explicitly undefined and is not something to rely on staying benign across an OS update, on a row whose whole job is to label seven fixed columns.

```swift
ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { day in
```

**Fix.** Index the array so the identity is unique: `ForEach(Array(["M","T","W","T","F","S","S"].enumerated()), id: \.offset) { _, day in ... }`. While there, hide the row from VoiceOver (`.accessibilityHidden(true)`) — single letters read aloud between the month title and the grid are noise, especially once the cells themselves carry proper labels.

**Verifier's correction.** Soften the failure statement. This is a static, never-mutated literal array, so the diff never has to reassociate anything and the headings render correctly in practice today — the concrete cost is the console diagnostic plus reliance on unspecified behaviour. The claimed misalignment is possible-in-principle, not observed. `id: \.offset` over `.enumerated()` fixes it.

---
### 58. BookingStore.markNotAttended(bookingID:) has zero callers and zero tests

**`OfficeDaze/Store/BookingStore.swift:200`** — test-coverage — found by: test-coverage — confidence: certain

A grep of the whole of OfficeDaze/ finds no call site for this overload: the notification handler in `ArrivalMonitor` routes a decline through `ledger.declineAttendance(bookingID:)`, and `HomeScreen:639` and `ArrivalLedger:129` both use the `(_ booking:)` overload. No test references it either. So both of its branches — the found case and the guard's silent `return` when the id matches nothing — are dead in production and unmeasured in test. The doc comment says it is "the same answer from a notification, where only the id came back", which is precisely the path that stopped using it; the silent-return-on-missing-id branch is the kind of behaviour that matters if it is ever wired back up, and there is no test to say what it should do.

**Failure scenario.** There is no runtime failure today — the function is unreachable. The trap is future: a developer wiring the decline action straight to this overload gets a function whose "booking not found" behaviour (swallow silently, save nothing, tell the caller nothing) has never been asserted, and whose difference from `declineAttendance` — which additionally refuses to answer for a day already recorded as attended, the guard that `ArrivalLedgerTests.declineRefusesAnAnsweredDay` exists to protect — is invisible. Routing through this overload would reintroduce exactly the stale-question bug that test was written for, and the suite would stay green because nothing tests this function at all.

```swift
static func markNotAttended(bookingID: UUID, in context: ModelContext) throws {
        guard let booking = try context.fetch(FetchDescriptor<DeskBooking>())
            .first(where: { $0.id == bookingID }) else { return }
        try markNotAttended(booking, in: context)
    }
```

**Fix.** Delete it — `ArrivalLedger.declineAttendance(bookingID:)` is the id-based entry point the app actually uses and it carries the extra safety guard. If it is kept, add two tests: one that an unknown UUID writes nothing and throws nothing, and one that it behaves identically to `declineAttendance` for a day already attended (which today it does not).

**Verifier's correction.** Severity corrected from medium to low. The finding itself concedes 'there is no runtime failure today — the function is unreachable', which is the definition of a nit under the stated rubric: it is six lines of dead code. The framing as a coverage gap is misleading — an unreachable function has no coverage obligation. The right action is deletion, not a test; if the notification path ever needs an id-based decline it already has one in ArrivalLedger.declineAttendance, which carries the already-attended guard that ArrivalLedgerTests protects.

---
### 59. Every captured image is stored forever for a "view original" feature that does not exist, with no way to view, prune or delete one

**`OfficeDaze/Store/Models.swift:292`** — dead-code — found by: robustness-misc — confidence: certain

`CaptureCoordinator.record` writes the full prepared JPEG into `Capture.asset` on every capture, success and failure alike, and nothing ever deletes an individual row. Four separate comments (`Models.swift:286`, `CaptureCoordinator.swift:328`, `BookingStore.swift:54`, `BookingStore.swift:100`) justify design decisions — notably the extra bookkeeping in `BookingStore.replace` to carry `captureID` across a delete-and-reinsert — on the grounds that "view original" must keep working. There is no view-original anywhere in the app; `BookingDetailScreen.swift:170` has a comment describing the row and no row. `Capture.bookingID` is likewise declared and never written or read. The result is a store that grows without bound and a set of invariants being maintained for a consumer that was never built. The only way to reclaim the space is `Store.wipe`, which is all-or-nothing.

**Failure scenario.** At the design's own stated volume — under fifteen captures a month at a few hundred KB each after `PhotoImport` downsizing — the app accumulates roughly 50–100 MB of unreachable image data per year of use, with the only remedy being a destructive wipe that also deletes bookings, leave and attendance. Failed captures are retained on exactly the same terms as successful ones.

```swift
@Attribute(.externalStorage) var asset: Data?
```

**Fix.** Pick one: either build the "view original" row on `BookingDetailScreen` that the four comments assume exists, or stop retaining `asset` (keep only `receivedAt`, `status` and the token counts, which is all `SettingsScreen`'s "This month" section actually reads) and delete the dead `Capture.bookingID`. If retention stays, add pruning — drop `.failed` captures immediately and cap retained assets by age or count.

**Verifier's correction.** One precision on the remedy: Store.Scope.records (Store.swift:87-92) is OfficeDazeSchema.all minus Office, so it does delete Capture rows and the offices survive. The user therefore does not have to destroy their offices to reclaim the space — but they do still have to destroy bookings, attendance and leave, and attendance is the record the app repeatedly says has no other copy. So "all-or-nothing" is right in substance, wrong in detail.

---
### 60. `Capture.bookingID` is persisted schema that nothing ever writes or reads

**`OfficeDaze/Store/Models.swift:296`** — dead-code — found by: store-swiftdata — confidence: certain

`Capture.bookingID` is declared, defaulted, and threaded through the initializer, and that is the whole of its existence. `CaptureCoordinator.record(asset:status:usage:)` — the only place a `Capture` is created in production — never passes it, and no code anywhere reads `capture.bookingID`; the link is only ever traversed in the other direction, via `DeskBooking.captureID` (used in `CaptureCoordinator.provenance` and carried across in `BookingStore.replace`). A grep over the whole target and test suite finds no assignment outside the initializer.

The cost is not just clutter: it is a column in a schema with no migration plan, and it reads as a maintained back-reference. `BookingStore.replace` goes to real trouble to keep `DeskBooking.captureID` pointing at the right row and to avoid orphaning; a reader who believes `Capture.bookingID` is live would reasonably expect the same care on this side and find none — every `Capture` row survives a `replace` still claiming a booking id it never had.

**Failure scenario.** Import a screenshot, save the booking, then edit it. `BookingStore.replace` deletes the old `DeskBooking` and re-creates it under a new id, carefully carrying `captureID` forward. The `Capture` row is untouched — and would be stale if `bookingID` were ever populated, since nothing in `replace` or `delete` updates it. Today the field is simply always `nil`, so `provenance(of:)` works only because it reads the forward link; the field promises a reverse lookup the store cannot actually perform.

```swift
var inputTokens: Int = 0
    var outputTokens: Int = 0
    var bookingID: UUID?
```

**Fix.** Delete `bookingID` from `Capture` and from its initializer — `DeskBooking.captureID` is the live link and is sufficient for every reader. Removing a property is inferable by lightweight migration, so it is safe to do now and gets cheaper the sooner it happens. If a reverse link is genuinely wanted later, add it together with the `replace`/`delete` maintenance that would keep it honest.

---
### 61. Two notification-copy expectations hardcode a decimal point, so they fail under any comma-decimal locale

**`OfficeDazeTests/ArrivalTests.swift:241`** — test-quality — found by: test-lenience — confidence: certain

`ArrivalNotifications.number` is `value.formatted(.number.precision(.fractionLength(0...1)))`, and `FloatingPointFormatStyle` defaults to `Locale.autoupdatingCurrent`. Unlike `Day`/`Month`, which pin `Locale(identifier: "en_GB")` on their formatters precisely to avoid this, these two assertions compare against a string with an ASCII full stop. They pass on an en_* host and fail on a fr/de/es one — hidden non-determinism of exactly the kind that forces authors to weaken assertions later.

**Failure scenario.** Run the suite on a simulator or CI runner whose region is France. `(4.5).formatted(.number.precision(.fractionLength(0...1)))` yields "4,5", so `dayCount(attended: 4.5, target: 7, monthName: "August")` returns "Day 4,5 of 7 for August" and the expectation "Day 4.5 of 7 for August" fails. `consequence(attended: 4.5)` returns "tap to make it 5,5" against an expected "tap to make it 5.5". Two red tests with no code change.

```swift
#expect(
            ArrivalNotifications.dayCount(attended: 4.5, target: 7, monthName: "August")
                == "Day 4.5 of 7 for August"
        )
```

**Fix.** Pin the locale in production the way `Day.formatted` already does — `value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_GB")))` in `ArrivalNotifications.number` (and the identical helpers in HomeScreen, LeaveScreen, AttendanceGauge, EveningNudge) — or, if the half-day figure is meant to localise, build the expected string in the test with the same format style rather than hardcoding it.

**Verifier's correction.** Uphold at low. Corrected statement: ArrivalTests.swift:242-243 and :257 are the only two assertions in the suite that exercise a fractional day, and both hardcode a full stop against a formatter that follows the device region (ArrivalNotifications.swift:128), so they are green on an en_* simulator and red on fr/de/es. Fix is in the test, not the app — build the expected string through the same `.formatted(.number.precision(.fractionLength(0...1)))` call, or pin the locale. Drop the implication that this is a production bug; the app deliberately formats numbers for the user's locale.

---
### 62. `captures.first?.asset != nil` is over-broad where the exact bytes are knowable

**`OfficeDazeTests/CaptureCoordinatorTests.swift:343`** — test-quality — found by: test-lenience — confidence: certain

The test's own docstring is "A capture is recorded with its cost and its original", and every other line in it pins an exact value (status, inputTokens, outputTokens). The asset is checked only for being non-nil, even though the expected value is fully determined: the input is `CaptureSamples.pixel`, a small PNG, and `smallPNGPassesThrough` already establishes that `PhotoImport.prepare` returns such data byte-for-byte unchanged.

**Failure scenario.** Change `record(asset:status:usage:)` in CaptureCoordinator to `record(asset: Data("placeholder".utf8), ...)`, or have it store a thumbnail, or store the response JSON instead of the image. The assertion still passes, and "view original screenshot" shows something that is not the original — which is the one thing this record exists for.

```swift
#expect(captures.first?.asset != nil, "so \"view original\" has something to show")
```

**Fix.** `#expect(captures.first?.asset == CaptureSamples.pixel, "the original, not a stand-in")`.

---
### 63. `heicIsTranscoded` returns before asserting anything when the fixture comes back empty

**`OfficeDazeTests/CaptureTests.swift:371`** — test-quality — found by: test-lenience — confidence: likely

The guard is documented as covering a host with no HEIC encoder, which is a fair concern — but `makeImage` returns `Data()` on three distinct failures (the `CGContext`/`makeImage` chain failing, `CGImageDestinationCreateWithData` failing, or `CGImageDestinationFinalize` returning false), not only on a missing encoder. The test therefore reports success while executing zero expectations, and it cannot distinguish "this host cannot encode HEIC" from "the fixture builder is broken". Swift Testing has a first-class way to say the former.

**Failure scenario.** Someone edits `makeImage` (say, changing `bitmapInfo` to a combination `CGContext` rejects for 8bpc RGB). `makeImage` returns `Data()` for every call. `oversizedIsResampled`, `orientationIsApplied` and the others fail loudly with unwrapping errors, but `heicIsTranscoded` returns green having asserted nothing — and it stays green forever afterwards if HEIC support is later dropped from `PhotoImport` entirely, since the guard fires before `prepare` is ever called.

```swift
guard !heic.isEmpty else { return }
        #expect(try PhotoImport.prepare(heic).mediaType == "image/jpeg")
```

**Fix.** Skip explicitly rather than returning silently, so the run records it: `try #require(!heic.isEmpty, "host has no HEIC encoder")` fails visibly, or better, gate on encoder availability directly — `guard CGImageDestinationCopyTypeIdentifiers().contains(UTType.heic.identifier as CFString) else { withKnownIssue(...) { } ; return }` — so an empty fixture from any other cause is a failure rather than a pass.

**Verifier's correction.** Uphold at low with the mechanism corrected: the fix is a `.enabled(if:)` trait on the @Test (swift-testing has no runtime skip API), plus having makeImage distinguish 'this host cannot encode this UTType' from 'the fixture builder failed' rather than returning Data() for both. Drop the 'stays green forever' clause — it only applies on a host lacking a HEIC encoder; where an encoder exists the assertion does execute.

---
### 64. `#expect(early.shortfall == early.shortfall)` is a tautology — the cross-month invariant it claims to check is never checked

**`OfficeDazeTests/QuotaTests.swift:291`** — test-quality — found by: test-lenience — confidence: certain

The comment above it says "The same month a fortnight earlier is short by exactly as much", which is a comparison between `early` and the `result` computed 15 lines above. As written the expression compares `early.shortfall` with itself; it is true for every possible value including NaN-free garbage, and the message "same shortfall" describes an assertion that was never made. This is the textbook lenient() equivalent: stubbing whose misuse cannot fail the test.

**Failure scenario.** Make `Quota.calculate` subtract the forecast twice, or make `shortfall` depend on `daysToRun` (e.g. `max(0, Double(target) - attended - forecast - Double(daysToRun) * 0)` replaced by something date-sensitive). On 6 August `early.shortfall` becomes 7 while on 27 August `result.shortfall` stays 7 — or vice versa. The test's stated invariant is broken, `early.shortfall == early.shortfall` is still true, and the test passes.

```swift
#expect(early.shortfall == early.shortfall, "same shortfall")
        #expect(early.standing == .behind)
```

**Fix.** Compare the two results: `#expect(early.shortfall == result.shortfall, "same shortfall")` — and while there, pin the value, `#expect(early.shortfall == 7)`, so the invariant is anchored rather than merely relative.

**Verifier's correction.** Uphold the tautology, correct the severity to low and drop the claimed failure. Corrected statement: QuotaTests.swift:291 compares `early.shortfall` with itself; it should read `#expect(early.shortfall == result.shortfall, "same shortfall")`. It is a dead assertion whose message describes a check that never runs, but shortfall is pinned to absolute values elsewhere in the same suite (lines 241, 263), so no plausible regression in `Quota.calculate` escapes because of it.

---
