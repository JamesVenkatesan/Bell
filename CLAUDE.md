# Bell — project context

A location-aware iOS timetable app. Reads a university schedule, shows it in
widgets, and works out how long it actually takes to walk to the next room.

Built for one user's Purdue ECE schedule, on hardware he owns, signed with a
free personal team. That shapes several decisions below.

---

## Start here

```bash
./setup.sh                 # regenerates Bell.xcodeproj from project.yml
xcodebuild -scheme Bell -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Bell -destination 'platform=iOS Simulator,name=iPhone 17' test
```

**You can compile and run the tests. The previous sessions could not.** All of
this code was written without a Swift toolchain, verified by reasoning and by
prototyping parsers in Python against real PDFs, then compiled by the user
pasting errors back. If something here looks subtly wrong, it may well be.
Build first, trust the tests, and fix what they catch.

There are 419 tests. They are not decoration — most of them encode a bug that
actually shipped and took a round trip with the user to find. Before changing
parsing or scheduling logic, read the test for it.

---

## Hard-won traps

These cost real time. Do not rediscover them.

**`./setup.sh` after any file move, add, or delete.** The project is generated
by XcodeGen from `project.yml`; it is gitignored and not the source of truth.
Symptom of forgetting: "Build input files cannot be found" naming a path that
no longer exists, or "Cannot find X in scope" for a file you can see on disk.

**Signing is baked in.** `DEVELOPMENT_TEAM: M862PL886J` sits in
`project.yml`, so regenerating no longer wipes it. If a build fails on signing,
check that line survived rather than re-picking the team by hand in Xcode —
Xcode's change would be lost at the next `setup.sh`.

**Stale build descriptions survive a plain rebuild.** After a file move, if the
old error persists, `xcodebuild clean` or delete
`~/Library/Developer/Xcode/DerivedData/Bell-*`.

**Deleting files in the user's folder may fail** with "Operation not permitted"
depending on how you're connected. Moving works.

**The simulator runtime may be missing.** `xcrun simctl list runtimes` empty
means tests can't run; `xcodebuild -downloadPlatform iOS` fetches it (8 GB).
`setup.sh` also opens Xcode every time; `xcodegen generate` alone regenerates
without that.

**Screenshots without tapping (DEBUG only).** `-BellSeedBundled YES` loads the
bundled Events.xml into an empty store; `-BellRoute` takes week, inbox, review, notion,
location, gallery, settings or `"course:ECE 30200"`. Also `-BellDemoCalendar`,
`-BellDemoInbox`, `-BellLocationDemo`, `-BellNoPrompts`, `-BellNoActivity`,
`-BellOnboarding`. Pass them to `xcrun simctl launch`.

**"The test runner hung before establishing connection."** A simulator state
problem, not Bell: the app launches fine by hand. Rebooting the simulator
usually clears it; when it doesn't, boot a different device (iPhone 17e) and
test there.

**PDFKit emits schedule tables column by column, not row by row.** `page.string`
gives every CRN, then every course, then every room. Room and instructor came
out empty for every real PDF until `TableLayout.reflow` rebuilt rows from
line geometry (`selectionsByLine`, anchored on CRNs left of the "Room"
header). Per-character bounds drift; don't go back to them.
`BellTests/RealPDFTests` runs the user's real PDFs and asserts the ten meetings.

**The ICS feed's instructor is in `ORGANIZER;CN=`, not DESCRIPTION.** SUMMARY
carries "CS 15900 12941-LE5" (course, CRN, section). EXDATE is not handled yet.

**Widgets render in tests.** `WidgetRenderTests` writes all eight, both modes,
as PNGs when `BELL_RENDER_DIR` is set. ImageRenderer can't draw timer-driven
progress, so the Bell widget's drain bar is only right on a device.

**`Bundle.main.infoDictionary` drops `~ipad` keys on an iPhone.** Read the
Info.plist file itself when testing device-specific keys.

**Dates are days, not instants, for breaks and term bounds.** They're stored
at midnight. Comparing instants matched only midnight, so the widget showed
classes on breaks at any other hour. Tests now ask at mid-morning.

**He runs Xcode 27 / iOS 27 betas.** Combine `Autoconnect` and `Publishers`
warnings are SDK noise. Ignore them.

**Free personal team.** App Groups *do* work (verified). Push notifications,
iCloud and TestFlight do not. The provisioning profile expires after 7 days, so
the app stops working weekly until rebuilt from Xcode. Local notifications,
background modes, geofencing, Live Activities and Foundation Models all work
without a paid membership.

---

## Architecture

### The two-process problem

The app and the widget are separate processes with separate sandboxes. This
governs the whole persistence design.

```
┌─ App process ────────────────┐     ┌─ Widget extension ──────┐
│  BellStore  (SwiftData)      │     │  ScheduleProvider       │
│      │                       │     │      │                  │
│      └──> SnapshotCache ─────┼────────────┘                  │
│           (flat JSON in      │     │  reads only             │
│            the App Group)    │     │                         │
└──────────────────────────────┘     └─────────────────────────┘
```

**SwiftData lives only in the app.** A widget timeline build is a cold start on
a tight budget; opening a ModelContainer, running fetches and faulting
relationships is slow, and SwiftData in an extension fails in ways whose only
symptom is a blank widget. So the app derives a flat snapshot after every write
and the widget reads that and nothing else.

`project.yml` **explicitly excludes** `Persistence/BellStore.swift`,
`Persistence/Records.swift`, `Persistence/LegacyMigration.swift` and the whole
`Capture/` directory from the widget target. Keep it that way.

**Every mutation republishes.** `BellStore.save()` calls `refresh()`, which
rebuilds the snapshot and reloads timelines. A write that doesn't do both
produces a widget that disagrees with the app. Don't add a write path that
bypasses it.

### Value types vs records

`StoredCourse` / `StoredMeeting` (SwiftData) are the durable shape.
`ClassEvent` / `Timetable` (plain structs in `Domain/`) are what the engine,
the views and the widget work with. `BellStore.buildTimetable()` converts.

This split is deliberate: the scheduling logic is pure and trivially testable,
and never has to think about persistence or thread confinement.

### File map

```
Shared/
  Domain/          pure value types + logic, no frameworks
    Models.swift          ClassEvent, TaskEvent, Timetable
    ScheduleEngine.swift  occurrences, gaps, leave times, refresh points
    ScheduleDiff.swift    what an import would change
    DayLayout.swift       true-scale day geometry + RowWindow (app and widget)
    WeekGridGeometry.swift zoom, scrub and focal-point anchoring
    Conflicts.swift       ExternalEvent + clash detection (overlap, travel)
    NextBell.swift        the hero's one fact: next start, end or leave-by
    DayIntelligence.swift FreeTime, DeadlinePressure, GapAdvisor, WakePlan
                          (moved here so the widget can use them)
  Widgets/         WidgetModel (pure), WidgetActions (App Group queue +
                   AppIntents), WidgetViews (eight), MaxPlan (pure) +
                   MaxWidgetView (Bell Max); app + widget
  Persistence/
    AppGroup.swift        container + defaults, one identifier
    Records.swift         @Model schema (covers phases 2-6 already)
    BellStore.swift       the only write path
    SnapshotCache.swift   what the widget reads (+ JSON coders)
    Preferences.swift     small settings in App Group defaults
    LegacyMigration.swift one-time seed from the old JSON blob
  Capture/         app-only; excluded from the widget
    TextExtraction.swift  PDF + Vision -> positioned fragments and raw text
    TableLayout.swift     reflows PDFKit's column-ordered text into rows
    TableReader.swift     THE important one; see below
    GridReader.swift      weekly-grid fallback, approximate by design
    HeuristicParser.swift line-by-line regex, last resort
    IntelligentParser.swift Foundation Models, cross-check only
    ScheduleCapture.swift orchestrates the four, in quality order
    ICSImporter.swift     calendar feeds; the best path
    Subscription.swift    feed URL in the Keychain
  Design/          tokens, motion curves, haptics
  (loose files)    Campus, RoomCoordinates, LocationProvider, Notifier,
                   ClassActivity, Palette, WidgetComponents

BellApp/           RootView (routes, hero namespace, onboarding gate)
  Today/           TodayScreen, DayTimeline
  Week/            WeekScreen (pinch, scrub)
  Course/          CourseScreen, CourseSummary (pure)
  Calendar/        CalendarPlan + CalendarReconciler (pure), CalendarSync
                   (EventKit), CalendarSettingsView
  Inbox/           EventTextReader, InboxAgreement + AIOverride (pure),
                   InboxModelReader, InboxProcessor, InboxScreen
  Intelligence/    Brief, WeeklyReview, Ask (QA + chat + tools),
                   Briefing (notifications), WakeAlarm (AlarmKit), views
  Location/        LocationLogic (GeofencePlan, AttendanceRule, Escalation,
                   BuildingLocator, ActivityPolicy; pure), LocationServices
                   (CLMonitor), ClassTracking (Live Activity, intent,
                   notification actions), LocationSettingsView
BellShare/         share extension: queues and exits, nothing else
Shared/Inbox/      CaptureQueue (compiled into app + share extension only)
  Onboarding/  Settings/  Import/
  Email/           Gmail (OAuth + PKCE, Keychain tokens, polling), settings
  Notion/          NotionSchema (pure: schema, mapping, values, kind, course),
                   NotionAPI (client, pinned versions, fallback), NotionAccount
                   (token, sync, BGAppRefreshTask), NotionSettingsView
  Widgets/         WidgetGalleryView: all eight, full colour and tinted
BellWidget/        timeline provider + every widget family
BellTests/         419 tests (Fixtures/ holds the real PDFs and ICS; gitignored)
```

---

## The import pipeline (Phase 1, done)

Four readers, tried in quality order by `ScheduleCapture`. **The ordering is
the design**: a document usually contains a better and a worse representation
of the same schedule, and picking the better one beats parsing the worse one
cleverly.

1. **`ICSImporter`** — a subscribed calendar feed. Exact, and self-updating.
   UniTime (Purdue's system) publishes one from Export → Export iCalendar.
   Confidence 1.0.
2. **`TableReader`** — the registrar's section table. Confidence 0.95.
3. **`GridReader`** — the weekly grid. Day and room reliable; times read off
   pixel positions, so approximate. Confidence 0.45, always flagged.
4. **`HeuristicParser` + `IntelligentParser`** — line-by-line regex,
   cross-checked against Apple's on-device model. 0.55–0.98.

### TableReader: read this before touching it

It took four rewrites. The failures were not where they looked.

**It anchors on the CRN, not on geometry.** An earlier version located columns
by their x-positions from the header row. That required clean word boxes out of
PDFKit, which don't materialise, and the failure was silent — it found nothing
and the import quietly fell through to the worst reader. A CRN (`17727-002`) is
unique, appears once per section, and the column order around it is fixed:

```
Subject  Course  Type  CRN  Days  Start  End  Date  Room  Instructor  ... Credit  Gr Md
```

Every field is found by walking outward from the CRN. Line wrapping stops
mattering, because token *order* survives wrapping even though line structure
doesn't.

**PDF text has no spaces between columns.** A real row arrives as:

```
08/25 -12/10BHEE 170I Lin  3G
```

`12/10BHEE` is one whitespace-delimited token. `TableReader.tokenize` therefore
splits by *shape* — CRN, clock time, date, digit run, letter run — not by
whitespace. Letter runs keep a trailing comma, because `M C Ruiz, S P France`
is two people and the comma is the only thing saying so.

**A row's grade flag welds onto the next row's subject.** `3G` + `ECE` arrives
as `GECE`: four capitals followed by a course number, shape-identical to a real
subject. Counting occurrences **does not work** — in a fully glued document the
artefact outnumbers the clean form; it was tried and reverted. The rule that
holds is structural: *a real subject never ends with another real subject*, so
when a token does, the suffix is the subject. Capped at two stripped characters.

**Each record owns the tokens between its CRN and the next.** Without that
bound, the backward search for the course code runs into the previous row's
wrapped tail and reads its room as this row's course.

**Days is searched only in the first 3 tokens after the CRN.** Wider, and
`S L Feld` reads as Saturday.

**A one-digit number is a credit count, never a room.** Room numbers are 2–4
digits.

**A letter group made only of `MTWRFSU` is a day token, not a building.** But
`WTHR` contains H, `WALC` contains A, `UC` contains C — so the rule is "only
day letters", never "contains day letters". Getting this wrong breaks every
Wetherill class.

**Instructor is best-effort and stops early.** The Note column follows with no
separator, so a stop-list (`Evening`, `Exams`, `Required`, …) marks the end. A
cleverer rule would have to decide whether "Evening" is a surname. Glued
initials (`PFrance`) are split at the capital-capital-lowercase seam.

### Verifying parser changes

Three real PDFs with three different wrapping patterns were used. If you change
`TableReader`, confirm the expected output is still:

| Day | Course | Time | Room | Instructor |
|---|---|---|---|---|
| Mon | ECE 30864L | 9:30–10:20 | WALC 2088 | S P France, M Ikram |
| Mon | ECE 30200 | 15:30–16:20 | WALC 1018 | A R Reibman |
| Tue | ECE 30100 | 7:30–8:45 | BHEE 170 | I Lin |
| Tue | ECE 20869 | 16:30–17:45 | UC 114 | S Bagchi |
| Wed | ECE 30200 | 15:30–16:20 | WALC 1018 | A R Reibman |
| Thu | ECE 30100 | 7:30–8:45 | BHEE 170 | I Lin |
| Thu | ECE 30864L | 9:30–11:20 | BHEE 206 | M C Ruiz, S P France |
| Thu | ECE 39401 | 12:30–13:20 | WALC 2088 | C J Hack, B A Parks |
| Thu | ECE 20869 | 16:30–17:45 | UC 114 | S Bagchi |
| Fri | ECE 30200 | 15:30–16:20 | WALC 1018 | A R Reibman |

`SOC 10000DIST` is an async online section: a real enrolment with no meeting
time. It must produce **no** meetings. Inventing one puts a phantom class on
the widget.

### Confidence is measured, not asserted

For the unstructured path, confidence comes from *agreement between two readers
that fail differently*, not from the model's opinion of its own output — which
is near-constant and therefore useless for deciding anything.

### The diff is the safety mechanism

`ScheduleDiff` matches on identity, so a room change reads as a change rather
than a delete plus an add. Two defaults matter and should not be "simplified":

- **Removals are never accepted by default.** A class the parser *missed* looks
  identical to a class the user *dropped*.
- **Low-confidence additions start unticked.** A class that isn't real is worse
  than one extra tap.

---

## Design system

`Shared/Design/`. Use these tokens; don't introduce raw colours or durations.
`Design/PLAN.md` is the approved plan: palette hex values, type roles, the
reasoning. Read it before changing anything visual.

**The idea: the next bell is the interface.** Today opens on `BellSlab`, one
number on a slab of the course's colour that drains as time runs out (content
drawn twice, masked at the level). It is the only loud thing; everything else
is quiet, neutral surfaces with one signal colour (vermilion, `Bell.Signal.now`)
for now, urgent and conflict. Compressed Black appears only in bell numerals.
No tracked uppercase labels, no gradient headers.

**The colour rule: brightness carries meaning, hue is decoration.** It began as
a constraint — iOS tinted mode discards hue and renders widgets from luminance
alone — and turned out to be right everywhere, because a schedule is read at a
glance, at arm's length, often through a tint. `Palette.assign` spreads courses
across a ten-step ramp evenly spaced in CIELAB L* (92 to 29), using
`spread` so few courses still span light to dark; a lab shares its lecture's colour via `courseFamily`.
There's a test asserting the steps stay separable by brightness alone. Keep it.

**Motion: nothing linear, response before bounce, bounce only for arrivals.**
`Bell.Motion` has the curves and the reasoning.

**Haptics are a five-case vocabulary**, not a buzz on every tap. If everything
buzzes, the buzz stops carrying information.

**Numbers that change are monospaced-digit.** A countdown that jitters
horizontally makes a calm interface feel cheap.

---

## Roadmap

All roadmap phases (0 to 6) are done; the notes below record what each one
built and the traps it found. The user wants work built deeply rather than
thinly, and approves each step before the next begins.

### Phase 2 — UI/UX overhaul (done)

How it was built, so later phases extend it rather than fork it:
- Every push is a `Route` value. Course pages zoom out of their source via
  `.navigationTransition(.zoom)` + `.matchedTransitionSource`, keyed by
  `HeroID.card(sourceID)`; the same course has distinct sources (`now-`,
  `week-`, plain occurrence id).
- Glass (`Bell.Material_.floating`) only on things content scrolls under:
  day strip, week header, scrub readout. Scroll edges use `.soft`.
- `RowEmphasis(status)` is the only place status becomes emphasis.
- `Bell.legibleOn` picks by contrast ratio. It used a 0.45 luminance cut,
  which gave mid-ramp colours white text at about 2:1.
- Tasks have a stable `uid` (they used to get a new UUID per refresh).
- `SharedStore` is retired; `Palette.ink/rail/paper` aliases are gone.

Original brief:

The current UI is scaffolding. Rebuild it on the design system, taking
inspiration from Apple's own apps.

- Matched-geometry hero transitions: a row expands into a full screen. Keys are
  in `HeroID` so the row and the detail screen can't drift apart.
- Layered materials and content-aware blur, used where content shows through —
  not as decoration over flat fills.
- A today timeline with a live "now" hairline that moves, and gaps drawn at
  true scale, because finding free time is the question the grid doesn't answer.
- Interactive week grid: pinch to zoom, drag to scrub.
- Course detail pages: attendance history, upcoming work, room map.
- Redesigned widget family carrying the new language.
- Three-screen onboarding.
- Fix the two Info.plist warnings (orientations, documents-in-place).

Three-tier emphasis already exists and must survive: finished classes dimmed at
34% with strikethrough, in-progress or next at full weight, the rest at 88%.
The user asked for this explicitly.

### Phase 3 — Calendar (done)

- Bell writes four weeks ahead into one calendar (new "Bell" in iCloud, or an
  existing calendar the user picks). Each event carries its key in the URL
  *and* a `bell:` line in notes, because some servers drop the URL.
- `CalendarReconciler` decides everything. Events without a key are never
  touched. A Bell event that disappears is read as "the user deleted it",
  i.e. a cancellation, but only if the ledger says it existed, and only up
  to 3 at once; more is treated as a reset and recreated. Don't loosen that.
- Cancellations are `StoredCancellation` rows -> `Timetable.cancelled`; the
  engine filters them. Today shows them with Restore, and a one-time undo
  banner when a sync created them.
- Other calendars are read into memory only (`ExternalEvent`), never stored
  or put in the widget snapshot. They share lanes and gaps in `DayLayout`.
- `AppSession.didLaunch` syncs *before* any permission prompt: awaiting a
  prompt suspends until answered, and other calendars sat unloaded behind it.
- Write-only access is refused: it can't read Bell's own events back, so it
  would duplicate on every sync.
- `Timetable` has a hand-written decoder so new fields default instead of
  breaking a widget reading an older snapshot. Add new fields there.
- DEBUG: `-BellDemoCalendar YES` creates a "Bell demo" calendar with two
  clashing events (simulator, needs calendar access granted via
  `xcrun simctl privacy <device> grant calendar com.yourteam.bell`).

Original brief:

EventKit two-way sync. **No API keys**: if his Google and Outlook accounts are
in iOS Settings, EventKit reads them locally. Bell writes a managed calendar so
classes appear in every calendar app. Conflict detection with travel time.

### Phase 4 — Inbox (done)

- Ways in: share sheet (BellShare extension), paste, latest screenshot
  (PhotoKit), any photo, typing. The extension only writes to the App Group
  `CaptureQueue`; the app drains it on launch and on foreground.
- Each capture is read twice: `EventTextReader` (NSDataDetector + course,
  building and kind rules) and `InboxModelReader` (Foundation Models).
  `InboxAgreement` scores agreement. `AIOverride` adds automatically only
  with a keyword, a date still ahead, confidence >= 0.65 and no caution.
- Traps found by testing, all with tests:
  - NSDataDetector reads "due December 3" as a span starting *now*; the
    deadline is date + duration.
  - The model invents dates for undated text (gave "send me the slides"
    today's date). A model date with no detector date is kept only if the
    text has a time word (`mentionsTime`).
  - ISO 8601 drops fractional seconds; the queue uses epoch seconds so
    same-second shares keep their order.
  - Foundation Models DOES run in this simulator (the Mac has Apple
    Intelligence). Pipeline tests set `usesModel = false` for determinism.
- Automatic adds are marked in data (`addedAutomatically` on the task,
  `wasAutoAccepted` on the item) and in every view that shows a task, via
  `AutomaticBadge` in `Signal.inferred`. Undo puts the item back in review.
- `.glassProminent` fills with the app tint, which is near-white: its label
  must be `Bell.Surface.canvas` or it's invisible.
- Not built: Gmail/Outlook polling. It needs an OAuth client registered with
  Google or Microsoft, which is an API key by another name; sharing an email
  to Bell covers the same need without one.
- DEBUG: `-BellDemoInbox YES` processes three sample messages once.

Original brief:

Share-sheet and screenshot capture → Foundation Models extracts date, time,
place → review queue. `InboxItem` is already in the schema.

**"AI Override"**: items matching exam/deadline/interview/final/mandatory are
added automatically and labelled as such. An automatic add must never be
mistakable for one the user made.

**iMessage reading is impossible.** No public API exposes SMS or iMessage
content to third-party apps, and nothing in iOS 27 changes it. The user asked
for this and was told. Screenshot capture is the honest substitute. Do not
claim otherwise.

Gmail/Outlook polling needs OAuth and is the one feature that breaks the
no-API-keys property. Keep it optional and clearly separated.

### Phase 5 — Daily intelligence (done)

The rule: every number is computed and tested in `DayIntelligence`; the model
only phrases it, and its output is checked before use.
- Brief: `BriefFacts` -> `BriefWriter.template` (always correct, always shown
  first) -> model rephrase, used only if `isGrounded` (every h:mm and every
  course/room code appears in the facts) and `keepsTense`.
- Traps found running it for real, all with tests:
  - Rooms share the course-code shape ("BHEE 170"). Without rooms in the
    vocabulary every sentence naming one failed grounding, so the model's
    prose was silently never used.
  - The model wrote "You were up by 6:25" at 2:30am: right times, wrong
    meaning. Grounding checks facts, not meaning; `keepsTense` covers the one
    distortion seen. Expect others; the template is the safe floor.
  - Times without AM/PM read backwards ("free 11:20–10:00"). `clock` shows
    AM/PM; grounding compares `digits` so "4:20pm" still matches.
  - Today auto-scrolled to the first class before the day began, hiding the
    brief. It now scrolls only while now is inside the day's timeline.
- Wake-up is a real AlarmKit alarm (through silent mode), one at a time,
  recomputed whenever Bell runs. It can't recompute itself overnight.
  Walk from HOME in RoomCoordinates if set, else last location, else a stated
  15 min guess.
- Ask bar: `AskIntent` (rule, not model) splits questions from instructions.
  Questions: `ScheduleQA` exact answers first, then the model with `DayTool` /
  `TasksTool`, grounded against the fortnight. Instructions go through the
  inbox pipeline and are added as the user's own (never badged automatic).
- Effort per task kind (exam 6 h, project 8, assignment 3, quiz 2) is a guess;
  the UI states only the measured free hours.

Original brief:

Morning brief as generated prose, not a list. Adaptive wake-up from the first
class plus live walking distance. Gap suggestions. Deadline pressure against
remaining free time. Natural-language input. Ask-your-schedule chat. Weekly
review.

### Phase 6 — Location depth (done)

- `CLMonitor` named "BellBuildings" watches the next two days' buildings
  (plus HOME when known), max 20. **Names must be letters and digits**: a
  dot made CLMonitor throw an uncaught exception and crash every launch.
- Arrival within [start−15 min, halfway] marks attended, automatically;
  automatic never overwrites a manual mark, and nothing is ever auto-marked
  missed. Arrival cancels that class's walk alerts.
- Escalation (opt-in, needs attendance on): heads-up, leave now, running
  late at start − walk + 2 min. Leaving a building re-estimates from there.
  The Notifier skips plain reminders only for classes escalation covers.
- Buildings: learned from an accurate fix while in class (this was promised
  in Campus's comments and never implemented), or looked up in Apple Maps
  once the user allows it; results > 2.5 km from campus are rejected; a
  lookup never overwrites a position measured in the building.
- Room values like REMOTE/ONLINE/TBA are not buildings (`ClassEvent.notBuildings`).
- `.unmonitored` events carry the reason in flags; Settings > Location shows
  it. **The simulator reports circular regions as unsupported**, so geofence
  events can only be tested on a device.

**Live Activity (the known gap):** fully automatic start with the app closed
is impossible on a free account. ActivityKit refuses background starts, and
push-to-start needs APNs. What exists: start up to 3 h early whenever the app
is foreground (correct with no updates, since the range is the real class
start to end), notification actions that open Bell into tracking, and
`TrackClassIntent` for Shortcuts automations ("When I arrive at WALC").
The old presentation's progress ran from render time, not class start; fixed.

Original brief:

Geofenced auto-attendance (`AttendanceRecord` exists). Live re-routing with
escalating alerts. Automatic building geocoding so new rooms resolve without
editing `RoomCoordinates.swift`.

(Known gap addressed above, within what iOS allows.)

---

## Apple Intelligence

`IntelligentParser` uses the Foundation Models framework: on-device, no key, no
network, no per-request cost. Requires iOS 26+ and an Apple Intelligence
device. Always guard with `IntelligentParser.isAvailable` and degrade to the
non-AI path — `unavailableReason` exists to tell the user why.

Context window is small (a few thousand tokens), so prompts are chunked by
line, never mid-line.

Image input exists in iOS 27 but is **not** used: text is extracted with Vision
and fed as text. That was a deliberate choice by a session that couldn't
compile, and is worth revisiting now that you can.

Privacy is a real constraint, not a slogan: a class schedule is a record of
where the user is every hour of the week. It doesn't leave the device.

---

## Conventions

- Comments explain **why**, not what. The codebase is written to survive
  handoff; match that standard.
- Non-obvious decisions get their reasoning recorded inline, especially where
  the obvious alternative was tried and failed.
- Tests encode bugs that actually happened. New fix, new test.
- British-leaning prose in comments is the existing voice; stay consistent.
- No em dashes in anything written *for the user* (his stated preference).
- `Resources/Events.xml` and `Shared/RoomCoordinates.swift` are gitignored:
  together they are a weekly map of where he physically is.

## After the roadmap (done)

1. **PDF room/instructor**: see the PDFKit trap above. ICS now extracts the
   instructor too, so both paths fill the same fields.
2. **Gmail**: needs the user's own Google Cloud OAuth client (iOS type, Gmail
   readonly scope, themselves as test user); the client ID is pasted in
   Settings > Email. This is the one feature that isn't key-free. Tokens live
   in the Keychain. Mail goes through the inbox pipeline unchanged.
3. **Visual overhaul**: Design/PLAN.md.
4. **Eight widgets**, one question each: Bell (small), Behind me (small), Free
   (medium), Due (medium, tick buttons), Today (large, attendance buttons),
   Week (large), Leave (accessoryRectangular), Term (accessoryCircular).
   Timelines hold entries only at `WidgetModel.refreshDates` boundaries.
   Widget buttons write to `WidgetActions`; `BellStore.applyWidgetActions`
   applies them at launch and on becoming active, because the widget can't
   open SwiftData.

5. **Notion** (read-only, additive). Internal integration token in the
   Keychain with `availableInBackground` (AfterFirstUnlock: the 5am refresh
   runs locked). Discovery tries `POST /databases/{id}/query` at pinned
   2022-06-28, then `/data_sources/{id}/query` at pinned 2025-09-03, and
   remembers which worked; a sync that starts failing re-probes once.
   Column mapping is by property **ID** (survives renames), suggested from
   types, editable in Settings > Notion. Rows mirror into `StoredTask`
   keyed by `notionPageID`; `BellStore.applyNotion` updates, adds and
   removes only those rows, and only from a complete fetch (`allPages`
   throws rather than return a partial list). `doneInBell` keeps a widget
   tick across syncs since Bell never writes back. Course match reuses
   `EventTextReader.course`; no match stays nil, shown as Uncategorised.
   Refresh: BGAppRefreshTask for ~5am (a request iOS may defer), foreground
   when over an hour old, and the widget sets `notionRefreshRequested` when
   it sees data over four hours old (it cannot fetch or wake the app).
   **Not tested against the real database**: the token never left the
   phone. The Connect button probes it on device and Settings shows which
   path was pinned.
6. **Bell Max** (ninth widget, large). `MaxPlan` decides the composition:
   classes lead while any remain, then today's due list leads and classes
   collapse to a summary line; an exam within 7 days is a bottom line
   (4-7 days), an outlined box on top (2-3), a solid block first (0-1).
   Context blocks pin to the bottom edge. The Due widget flags each item's
   course (dashed outline when uncategorised).

7. **Deadlines on the day.** Today's timeline draws the selected day's
   open tasks: `DayLayout(exams:)` turns a timed exam with an end into a
   block that takes time (window, lanes, gaps); `DayLayout.deadlines`
   places everything else: marks at their time inside the window (labels
   nudged down, never up), lists above/below for times outside it (an
   11:59 PM deadline doesn't stretch the day), all-day items in a strip.
   "Coming up" above now starts tomorrow. Notion date ranges keep their
   end (`NotionValue.ends`). DEBUG `-BellDemoTasks YES` seeds examples.
8. **Bell Max legibility.** Nothing under 12pt; finished rows dim to 34%
   only in full colour (0.55 when tinted/clear, where the widget sits on
   the wallpaper); the exam hero is a heavy outline, not a knocked-out
   fill, outside full colour. Renders cover light, dark and tinted.

9. **Sky on "Done for today".** With no bell left, `BellSlab` shows
   `SkyScene` instead of a course colour: before sundown a sunset whose sun
   sinks and sky warms over the last four hours (the slab's level idea),
   after sundown the moon at its real phase over stars that twinkle unless
   Reduce Motion. `SkyClock` (Shared/Domain) computes sunrise/sunset (NOAA
   equations, campus coordinates, checked against the independent sunrise
   equation to ~1 min) and moon phase. Text sits on the hill silhouette,
   which rises to just under half the slab so the headline is never on sky.
10. **Bell Max, second design** (the glass-panel one was rejected as ugly,
   and the three-section one before it as blocky). Now Apple's large-widget
   shape: one hero (`MaxLayout.Hero`: exam today/tomorrow, else the bell's
   live countdown, else the next deadline once classes are over, else a
   quiet statement), a Fitness-style `DayRing` of the day's classes in
   course colours, one merged time-ordered list (classes, deadlines, exam)
   anchored to the bottom edge, and one footer line (an exam 2-7 days out,
   or stale Notion). A quiet day's list is "Coming up" (next class, the
   week's deadlines). Ground is always dark (`MaxGround`, a soft bloom of
   the hero's colour) and the content is forced to the dark scheme to
   match. No panels, one typeface plus the bell numeral, two greys.

## Open items

- `NextBell` (the hero) knows only classes: during a timed exam it can say
  "Done for today". Exams as bells is a sensible next step.

- Notion: real-database behaviour, the background refresh actually firing
  (only on device; simulate in the debugger with
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.yourteam.bell.notion-refresh"]`).

- Not verified on a device: home-screen tinted compositing, the interactive
  widget buttons, the Bell widget's drain bar, Gmail sign-in end to end.

- Breaks in `BundledTimetable.swift` are guesses at Purdue's calendar, not from
  any export. Term dates (08/24–12/12) are real.
- `Campus.swift` has estimated coordinates; `RoomCoordinates.swift` has the
  real measured ones for BHEE, EVER, UC, WALC, WTHR and overrides them.
- Pinch-zoom anchoring and the scrub gesture are verified by geometry tests
  and screenshots, not by hand on a device. Feel them on hardware.
