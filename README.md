# Bell

**The next bell is the interface.**

Bell is an iOS timetable app built around one question: *how long until I have to be somewhere?* It reads your university schedule from wherever it lives, knows how long the walk to your next room takes, and turns your day into a single number you can read from across the room.

Open it and you see that number, huge, on a slab of your course's colour. The colour drains as the time runs out. When it hits zero, the bell rings.

Everything runs on your phone. There's no account, no server and no analytics. Your schedule says where you are every hour of the week, so it never leaves the device.

---

## Why Bell

Most timetable apps are calendars with a different skin. They show you *what* is happening. Bell tells you *what to do about it*.

- **Leave-by, not start time.** If your next class is a ten-minute walk away, Bell counts down to when you need to leave, not to when the lecture starts.
- **Free time at true scale.** Gaps in the day are drawn at their real length, so a forty-minute window looks like forty minutes, and your other calendars' events are folded in.
- **It only interrupts when it matters.** "Class at 9:30" every Monday is noise. "This walk is 11 minutes and you have 10" is not. Bell sends the second kind and stays quiet otherwise.
- **The day reads as a day in progress.** Finished classes stay visible, dimmed and struck through. The current or next class is at full weight, and the rest sit just below it.

---

## Features

### Today

A hero countdown to the next bell: the next start, the next end, or the moment you should leave. The numerals are drawn twice and masked at the colour's level, so as it sinks you can see the line pass through the digits. When the bell changes while the app is open, the slab swings like a struck bell (unless you've turned on Reduce Motion).

Below it is a live timeline with a moving "now" line, your morning brief, what's due soon, and gaps you can actually use.

### Week

A zoomable, scrubbable grid of the whole week. Pinch to zoom around your fingers and drag to scrub through the hours. Tap any class and it zooms open into its course page, with attendance history, upcoming work and a map of the room.

### Import from anything

Bell tries four readers in order of quality and uses the best one your document supports:

1. **Calendar feeds (ICS).** Subscribe once and adds and drops flow in on their own. This path is exact.
2. **Registrar PDFs.** A table reader rebuilt from the PDF's real line geometry recovers course, days, times, room and instructor.
3. **Weekly-grid screenshots**, read with Vision, and clearly flagged as approximate.
4. **Anything else**, read with rules and cross-checked against Apple's on-device model. Bell trusts the result based on how well two independent readers agree, not on the model's opinion of itself.

Every import is shown as a diff before it's applied. A room change reads as a change, not as a delete and an add. Removals are never accepted by default, because a class the parser missed looks exactly like a class you dropped.

### Inbox

Share a syllabus line, an email or a screenshot to Bell, or paste or type it in. Bell pulls out the deadline, course and kind of work. Exams, finals and other must-not-miss items are added automatically and **always labelled as automatic**, so you never mistake one for something you entered yourself. Anything less certain waits in a review queue.

Optionally, Bell can watch your Gmail through the same pipeline (see [Gmail](#gmail-optional)).

### Daily intelligence

- **Morning brief**, written as prose rather than a list. Every number in it is computed and tested in code first. The on-device model only rephrases it, and its version is used only if every time and course it mentions is in the facts.
- **Adaptive wake-up**, set as a real alarm that sounds through silent mode, worked out from your first class and the walk to get there.
- **Deadline pressure.** It compares the work due against the free hours you actually have before it's due.
- **Ask your schedule.** "When am I free Thursday?" gets an exact answer, not a guess.
- **Weekly review.**

### Location

- **Auto-attendance.** Arriving at the building near the start of class marks you present. It never marks you absent on its own, and it never overrides a mark you made yourself.
- **Escalating alerts:** a heads-up, then leave now, then running late. If you leave from somewhere unexpected, the walk is re-estimated from there.
- **Buildings resolve themselves.** Bell learns a building's position from accurate fixes taken while you're in class, or looks it up in Apple Maps.
- **Live Activity and Dynamic Island** run for the length of each class, showing the time left and what's next.

### Calendar

Bell keeps your classes four weeks ahead in a calendar of its own, so they show up in every calendar app. It reads your Google, Outlook and iCloud calendars through iOS (no API keys) to find clashes, including ones caused by travel time. Delete a class from your calendar and Bell reads that as a cancellation, with a one-tap undo.

---

## Eight widgets, eight questions

Each widget answers exactly one question and has one focal point.

| Widget | Size | The question |
|---|---|---|
| **Bell** | Small | How long until the next bell? |
| **Behind me** | Small | How much of today is done? |
| **Free** | Medium | Where's my free time today? |
| **Due** | Medium | What's due soon? *(tick tasks off from the widget)* |
| **Today** | Large | What's the rest of today? *(mark attendance from the widget)* |
| **Week** | Large | What does this week look like? |
| **Leave** | Lock screen, rectangular | When do I leave? |
| **Term** | Lock screen, circular | How far through the term am I? |

- **No polling.** Timeline entries are generated only at the moments something changes: each class start and end, each leave-by time, each deadline, and midnight. Countdowns tick on their own between those moments, so a widget is never a minute stale mid-lecture.
- **Tinted mode is designed in, not bolted on.** iOS tinted mode throws away hue and keeps only brightness. Bell's course colours sit on a ten-step ramp evenly spaced in perceived lightness, so your courses stay distinguishable even when they've all been tinted the same colour. A test enforces it.
- **Honest empty states.** No classes, on a break, out of term and no schedule yet each say so, rather than showing a blank tile or replaying last week.

A gallery in **Settings** previews all eight in full colour and in tinted mode.

---

## Design

Bell is deliberately quiet everywhere except one place.

- **One loud thing.** The bell numeral, in Compressed Black, appears only in the hero. Everything else is neutral surfaces and plain type.
- **One signal colour.** Vermilion means *now*, *urgent* or *conflict*, and nothing else.
- **Brightness carries meaning; hue is decoration.** This started as a constraint from widget tinting and turned out to be right everywhere, because a schedule is read at a glance, at arm's length.
- **Motion is considered.** Nothing moves linearly, there's no bounce except on arrival, and Reduce Motion is respected everywhere. Haptics come from a five-case vocabulary rather than a buzz on every tap.
- **Accessible by default.** Text colour on every course colour is chosen by contrast ratio, numbers that change use monospaced digits so they don't jitter, keyboard focus is visible, and layouts are checked on small iPhones.

The full design rationale, including the palette, type scale and the ideas that were rejected, is in [`Design/PLAN.md`](Design/PLAN.md).

---

## Built with

SwiftUI with Liquid Glass and zoom transitions · SwiftData · WidgetKit and interactive AppIntents · ActivityKit · Foundation Models (on-device) · EventKit · Core Location (`CLMonitor`) · AlarmKit · PDFKit · Vision · MapKit

There are no third-party dependencies at runtime. The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Architecture in one paragraph

The app and the widget are separate processes. SwiftData lives only in the app, and after every write the app publishes a flat JSON snapshot to the shared App Group, which is the only thing the widget reads. That keeps widget timelines fast and avoids the blank widgets SwiftData produces inside extensions. Taps on widget buttons are queued in the App Group and applied by the app. All scheduling logic is pure value types, so it can be tested without a device.

### Tested

**365 tests**, most of which encode a bug that really happened. They include the parsers run against real registrar PDFs and a real calendar feed, the palette's lightness spacing, the widget refresh boundaries, and every widget rendered in both colour modes.

---

## Getting started

You need a Mac with Xcode 27 and an iPhone on iOS 26 or later. A free Apple ID is enough. You don't need a paid developer account.

```bash
git clone https://github.com/JamesVenkatesan/Bell-Timetable-App.git
cd Bell-Timetable-App
./setup.sh          # installs XcodeGen if needed, generates the project, opens Xcode
```

1. **Provide a starting schedule.** The build expects `Resources/Events.xml`, which is gitignored because it's personal. Unzip a `.timetable` export into `Resources/`, or use any placeholder and import your real schedule in the app afterwards.
2. **Signing.** Change `DEVELOPMENT_TEAM` in `project.yml` to your own team, and change the `com.yourteam` bundle identifiers to something unique. Then run `xcodegen generate`.
3. **Run.** Try it on a simulator first, then on your phone. The first time you install on a device, turn on **Developer Mode** and trust your Apple ID under **VPN & Device Management**.
4. **Import your schedule** from Settings: a calendar feed if your university offers one (the best option), otherwise a PDF or a screenshot.

Run the tests with:

```bash
xcodebuild -scheme Bell -destination 'platform=iOS Simulator,name=iPhone 17' test
```

### Gmail (optional)

Reading Gmail is the one feature that needs credentials, because Google requires an OAuth client. You create your own in Google Cloud: an iOS client with the Gmail read-only scope, with yourself added as a test user. Then paste its client ID into **Settings → Email**. Bell only ever requests read access, and it stores its tokens in the Keychain. If you'd rather skip this, sharing an email to Bell does the same job with no setup.

### Free Apple account notes

App Groups, local notifications, geofencing, Live Activities and Foundation Models all work on a free account. Free provisioning profiles expire after seven days, so you'll need to rebuild from Xcode about once a week. Push notifications aren't available on a free account, which means a Live Activity can only start while the app is open.

---

## Privacy

- No account, no backend and no analytics.
- Schedule parsing and every AI feature run on device, using Apple's Foundation Models.
- Your other calendars are read into memory only. They're never stored, and never written into the widget snapshot.
- Your real schedule files, measured building coordinates and test fixtures are all gitignored.

---

## Project layout

```
Shared/
  Domain/        pure schedule logic: engine, next bell, free time, diffs
  Capture/       PDF, ICS, grid and model readers (app only)
  Persistence/   SwiftData store and the widget snapshot
  Widgets/       widget model, actions and all eight views
  Design/        tokens, motion and haptics
BellApp/         Today, Week, Course, Inbox, Calendar, Intelligence,
                 Location, Email, Onboarding, Settings
BellWidget/      timeline provider and widget bundle
BellShare/       share extension
BellTests/       365 tests
Design/PLAN.md   the design system and why
```
