# Bell

A timetable app whose widget stays readable when the home screen is tinted.

Built around one constraint: iOS tinted mode discards hue and renders widgets
from luminance alone. Everything in the design follows from that.

---

## Why the existing widget breaks

Tinted mode isn't a bug you can opt out of — no third-party widget can refuse
it. What a widget *can* do is stop depending on the things tinting removes:

| What breaks | What Bell does instead |
|---|---|
| Raster images become gray blobs | No bitmaps anywhere. Text, SF Symbols, and shapes only. |
| Ten hues at equal brightness collapse into one gray | Palette is built from **luminance steps first**, hue second. |
| Hand-rolled `ZStack` backgrounds don't recolor | `containerBackground(_:for:.widget)`, which the system understands. |
| Symbols flatten into the background | `widgetAccentable()` puts them in the accent group. |
| Fixed-interval refresh goes stale mid-lecture | Timeline entries generated at exact class boundaries. |

The palette point is the load-bearing one. Your export stores every course as a
gray (`r == g == b`), so it carries no hue information at all. Bell assigns
colors from a ten-step luminance ramp in sorted course order, which means five
courses get five *well-separated* steps rather than five that a hash happened to
land on. Tinted, your courses stay distinguishable. Untinted, they look like a
deliberate palette rather than a rainbow.

---

## The file format

`.timetable` is a ZIP containing one `Events.xml`, which is an Apple property
list. No reverse engineering required — `PropertyListDecoder` reads it directly.

```
WeekEvents[]           the classes
  title                course code       "ECE 30200"
  info                 room              "WALC 1018"
  dayNum               0 = Monday
  time / endTime       seconds since local midnight   (27000 = 07:30)
  weekNum              rotation week, 0 when NumberOfWeeks == 1
Settings
  NumberOfWeeks        A/B week rotation length
  WeekendDaysAreActive
  ColorSettings        course → [r, g, b], all grays in your export
TaskEvents[]           dated one-offs; empty in your export
```

`TimetableImporter` includes a small ZIP reader (stored + deflate) so there's no
dependency for a 900-byte archive.

---

## Features

**Widgets**
- **Next class** — small, plus lock screen rectangular, circular, and inline.
  Shows the class you're in with a progress rail, or the next one with a
  countdown and a leave-by time.
- **Today** — medium and large. Everything still ahead, with walking times
  between rooms and a leave-now badge when the walk is at risk.
- **Week** — extra large. Full grid with today's column emphasised. Grid bounds
  come from your actual earliest and latest class, so a 7:30 lecture isn't
  clipped off the top by a hardcoded 8 a.m.
- **Control Centre button** (iOS 18+) — next class without unlocking.

**Live Activity**
Runs for the length of each class. Dynamic Island shows time remaining;
expanded shows where you're headed next and the walk. Ends automatically.

**Walking time**
Ships with coordinates for the buildings in your schedule and learns new ones
as you visit them. Feeds three things: leave-by times, tight-transition
warnings, and the gap heights in the day view.

**Notifications that earn the interruption**
Only two kinds fire: a first-class-of-the-day reminder, and a tight-transition
alert one minute before a class ends when the next walk doesn't fit the gap.
A daily "class at 7:30" alert you already know about is noise.

**Siri and Shortcuts**
"When's my next class", "what's my schedule", "when am I free" — the last one
finds your next gap over a configurable minimum.

**Term and break awareness**
Set first and last day, add breaks. Outside those the widget says why it's
empty instead of replaying last week forever.

**Attendance and focus**
Interactive widget buttons mark a class skipped or start a focus session scoped
to that course, both without launching the app.

---

## What your schedule looks like through this

21 events, 10 courses, Monday–Friday, 7:30 to 18:00. Two things the
tight-transition check flags immediately:

- **Wednesday 08:30** — ECE 36200 ends in WTHR 200 and ECE 36200L starts in
  BHEE 162 at the same minute. Zero gap, and those are different buildings.
- **Tuesday and Thursday 17:45** — ECE 20869 ends in UC 114 as SOC 1000D starts
  in EVER 500. Also zero gap, also a walk.

Both would produce a leave-now alert one minute before the earlier class ends,
and both render with an orange gap marker in the day view.

Your longest stretches: Tuesday 08:45–16:30 and Friday 08:30–15:30. Those are
what the free-block intent surfaces.

---

## Build it

```bash
cd Bell
./setup.sh
```

That installs XcodeGen if needed, generates `Bell.xcodeproj` from `project.yml`,
and opens it. Then in Xcode: select each target in turn (Bell, BellWidget),
Signing & Capabilities, pick your Apple ID team. If signing complains about the
bundle ID, change `com.yourteam` to something unique in `project.yml` and
regenerate.

Run on the simulator first. Once that works, plug in your phone and pick it as
the destination.

### Your schedule is already in it

`Resources/Events.xml` is the file from your export, embedded in both targets.
The app runs with your real timetable on first launch — no import step needed.

### Two things about free Apple accounts

**App Groups won't provision.** It needs the paid membership. Bell works around
this: the same `Events.xml` is compiled into both the app and the widget, so
both read the identical schedule with no shared container. `Settings → Storage`
tells you which path is live. The cost is that changing your schedule means
replacing `Resources/Events.xml` and rebuilding rather than importing in-app.

**The app expires after 7 days.** Free provisioning profiles are short-lived —
the app and its widget stop working after a week until you rebuild from Xcode.
This is Apple's limit, not something the code can route around. Rebuilding takes
about thirty seconds. If that grates, the $99 membership removes it and also
unlocks App Groups, at which point uncomment the block in
`Support/Bell.entitlements`, add the same group to `BellWidget.entitlements`,
and in-app import starts working.

### Set your term dates

`Shared/BundledTimetable.swift` holds term start, term end, and breaks — the
export doesn't carry them. The dates in there are placeholders. Replace them
with Purdue's published academic calendar before you build, or the widget will
happily show classes through Thanksgiving.

### File map

```
project.yml                the Xcode project definition
setup.sh                   generate and open
Resources/Events.xml       your schedule, compiled into both targets
Support/                   Info.plists and entitlements

Shared/
  Models.swift             ClassEvent, TaskEvent, Timetable
  TimetableImporter.swift  ZIP + plist decoding
  BundledTimetable.swift   bundle fallback, term dates, breaks
  ScheduleEngine.swift     dated occurrences, gaps, leave times, refresh points
  Campus.swift             building coordinates and walking estimates
  Palette.swift            the luminance-first color system
  SharedStore.swift        storage, with bundle fallback
  ClassActivity.swift      Live Activity + Dynamic Island
  Intents.swift            Siri, Shortcuts, interactive buttons, attendance
  Notifier.swift           notification scheduling

BellApp/                   entry point, day rail, week view, settings
BellWidget/                timeline provider, tint-safe components, all families
```

### If the first build fails

I have no Swift toolchain here, so none of this has been compiled. The
scaffolding is mechanical and should be sound; the SwiftUI is where errors will
surface. Most likely spots, in order: `WeekGridView`'s offset arithmetic,
`ProgressRail`'s `GeometryReader` sizing, and the `Gauge` in the circular
accessory view. All are contained — none of them touch the parsing or scheduling
logic, which is the part that took the thinking.

---

## Testing the thing that started this

Simulator → long-press home screen → Edit → Customize → Tinted, slider hard
left. Then check: can you still tell which block is which course? If two blocks
read as the same gray, two courses landed on adjacent luminance steps — widen
the stride in `Palette.assign(courses:)`.

`Palette.relativeLuminance(_:)` is there so you can assert the separation in a
unit test rather than eyeballing it.
