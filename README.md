# Bell

A location-aware iOS timetable app. It knows your class schedule, it knows
where you are, and it works out how long it will actually take you to get to
your next room.

Built for a Purdue ECE schedule, on top of the standard `.timetable` export
format — so it works for any schedule in that format, at any university.

---

## What it does

**Tells you how far you are from your next class, in minutes.**
Not distance on a map. A number you can act on. The widget reads *12 min away*,
and that figure feeds straight into when it tells you to leave.

**Knows the campus.** Every room maps to a real coordinate. Walking estimates
account for path detours, crossings, and the time it takes to get through a
door and up a stairwell — because a straight-line number is optimistic enough
to make you late.

**Only interrupts when it matters.** A reminder that class starts at 7:30 every
Monday is noise. An alert that *this* walk is 11 minutes and you have 10 is
not. Bell fires the second kind and stays quiet otherwise.

**Shows the whole day, not just what's left.** Finished classes stay on the
widget, dimmed. What you're in now is brightest. What's ahead sits in between.
The day reads as a day in progress rather than a shrinking to-do list.

**Adapts to how your phone looks.** Course colours are chosen so they stay
distinguishable whatever theme or tint you've set on your home screen.

---

## Widgets

| Size | What you get |
|---|---|
| Small | Current class with a progress rail, or the next one with a countdown and leave-by time |
| Medium | Everything still ahead, with walking times between rooms |
| Large | Featured class rendered big with live ETA, the full day below it, and when you're free |
| Extra large | The week as a grid, today's column marked |
| Lock screen | Rectangular, circular, and inline — countdown on your lock screen |
| Live Activity | Runs for the length of each class; Dynamic Island shows time remaining and where you're headed next |

Ask Siri *"what's my next class"*, *"what's my schedule"*, or *"when am I
free"* — the last one finds your next real gap.

---

## Under the hood

**Timeline refreshes are scheduled, not polled.** WidgetKit budgets how often a
widget may update, so Bell spends that budget precisely: entries are generated
at each class start, each class end, each leave-by threshold, and midnight.
Nothing in between. The widget never shows a stale minute mid-lecture.

**Location without a battery cost.** The widget requests a fix while iOS has it
awake, rather than running a location manager continuously. The ETA is current
as of the last refresh — accurate to within a few minutes, which is the
resolution that matters for *can I still make it*.

**Term-aware.** Set your first and last day and add your breaks. Outside those
dates the widget says why it's empty instead of replaying last week forever.

**Colours are assigned, not hashed.** Courses are sorted and spread evenly
across a ten-step palette, so a five-course schedule gets five well-separated
colours instead of whatever five a hash lands on. Labs inherit their lecture's
colour.

---

## Install it

You need a Mac with Xcode and an iPhone. No paid Apple Developer account
required.

### 1. Clone and generate the project

```bash
git clone https://github.com/YOUR-USERNAME/bell.git
cd bell
./setup.sh
```

`setup.sh` installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) via
Homebrew if you don't have it, builds `Bell.xcodeproj` from `project.yml`, and
opens Xcode.

If the script won't run, `chmod +x setup.sh` first.

### 2. Set your signing team

In Xcode, click the blue **Bell** project icon, then for **each** of the two
targets — `Bell` and `BellWidget` — open **Signing & Capabilities**, tick
**Automatically manage signing**, and choose your Apple ID under Team.

No team listed? Xcode → Settings → Accounts → **+** → add your Apple ID.

If Xcode says the bundle identifier is unavailable, change `com.yourteam` in
`project.yml` to something unique and regenerate. Keep the widget's identifier
as the app's plus `.widget`.

### 3. Build

Pick an iPhone simulator and hit Run. Once that works, plug your phone in with
a cable, select it as the destination, and run again.

First install on a device needs two things on the phone:

- **Settings → Privacy & Security → Developer Mode** → on. The phone reboots.
- **Settings → General → VPN & Device Management** → tap your Apple ID → Trust.

### 4. Add your own schedule

Replace `Resources/Events.xml` with your own. Unzip a `.timetable` export:

```bash
unzip -o ~/Downloads/YourSchedule.timetable -d Resources/
```

Then set your term dates and breaks in `Shared/BundledTimetable.swift`.

### 5. Add your building coordinates

Open `Shared/RoomCoordinates.swift`. For each building: find it in Google Maps,
right-click the door you actually use, click the coordinates that appear at the
top of the menu, and paste them in:

```swift
"BHEE": (40.428865428011235, -86.911782029119),
```

You can key by building code or by full room (`"BHEE 162"`), and room entries
win — useful where one building's entrances are far apart.

Every walking estimate depends on these, so it's the highest-value ten minutes
you can spend on setup. **Settings → Room coordinates** in the app shows which
rooms are set and which are still estimated.

Rebuild, and grant location access when the app asks. Without it the ETA never
appears.

---

## Two things about free Apple accounts

**The app expires after 7 days.** Free provisioning profiles are short-lived —
the app and its widget stop working after a week until you rebuild from Xcode.
This is Apple's limit. Rebuilding takes about thirty seconds.

**In-app import doesn't reach the widget.** App Groups requires a paid
membership, and without it the widget can't read anything the app saves. Bell
works around this by compiling the same `Events.xml` into both targets — which
is why changing your schedule means replacing that file and rebuilding rather
than importing in the app.

A $99/year membership removes both. If you have one, uncomment the App Groups
block in `Support/Bell.entitlements`, add the same group to
`BellWidget.entitlements`, and set `SharedStore.appGroup` to match.

---

## Project layout

```
project.yml                the Xcode project definition
setup.sh                   generate and open
Resources/Events.xml       your schedule, compiled into both targets
Support/                   Info.plists and entitlements

Shared/                    compiled into both app and widget
  Models.swift             ClassEvent, TaskEvent, Timetable
  TimetableImporter.swift  ZIP + property list decoding
  BundledTimetable.swift   term dates and breaks
  ScheduleEngine.swift     dated occurrences, gaps, leave times, refresh points
  Campus.swift             building coordinates and walking estimates
  LocationProvider.swift   live position and ETA
  RoomCoordinates.swift    your coordinates — edit this one
  Palette.swift            colour assignment
  SharedStore.swift        storage, with bundle fallback
  ClassActivity.swift      Live Activity and Dynamic Island
  Notifier.swift           notification scheduling
  WidgetComponents.swift   shared views

BellApp/                   day rail, week view, settings, Siri intents
BellWidget/                timeline provider and every widget family
```

---

## Roadmap

- **iCalendar import.** UniTime, the system behind Purdue's schedule export,
  publishes a subscribable `.ics` URL. Subscribing rather than importing means
  add/drops and published exam times flow in on their own.
- **Campus-wide coordinates.** A bundled building database plus geocoding
  fallback, so new rooms resolve without editing a source file.
- **Exams and deadlines.** The model already carries `TaskEvent`; nothing
  surfaces it yet.

---

## Requirements

iOS 17+ · Xcode 16+ · macOS with Homebrew

Live Activities need iOS 16.2, Control Centre widgets need iOS 18.
