# Bell: visual language and widget plan

Status: proposed, awaiting approval. Nothing below is built yet.

## The idea

**The next bell is the interface.**

Every screen is organised around one live number: the minutes until the next
bell, meaning the next class starting, ending, or the moment you have to
leave. It is set enormous, in a full-bleed slab of the current course's
colour, and the slab physically drains as the time runs out. That slab is the
one place Bell is loud. Everything else (the timetable, the week, settings) is
a strict, quiet, typographic timetable that stays readable in a corridor.

Not Boring's lesson, applied: one focal element with real personality and
saturated colour, owned completely. Flighty's lesson: dense, time-structured
data drawn at true scale on a physical track, with hierarchy from type and
position rather than boxes. Apple Weather and Fitness: in a widget, one big
number, one supporting line, and nothing that isn't load-bearing.

## Palette

Two grounds: Bell follows the system appearance rather than forcing dark.
Most glances happen in daylight, in corridors, and saturated colour reads
best on a light ground.

| Role | Day (light) | Night (dark) |
|---|---|---|
| Ground | Platform `#F2F3F5` (cool grey, not cream) | Black `#000000` |
| Raised (rare: sheets, the bar) | `#FFFFFF` | `#141416` |
| Ink | `#0B0B0C` | `#F5F6F7` |
| Ink 2 (secondary) | `#5B5E64` (5.9:1) | `#A3A6AC` (8.6:1) |
| Ink 3 (tertiary, large/non-text only) | `#8A8D93` | `#6B6E74` |
| Rule | `#D9DBDF` | `#26282C` |
| **Signal** (now, leave now, clashes) | Vermilion `#FF4F1F` | Vermilion `#FF5A2B` |

One signal colour, not four. "Urgent", "conflict" and "settled" were separate
hues; now urgency is vermilion plus a glyph, and "fine" is simply ink.

Course ramp: ten saturated colours at evenly spaced perceptual lightness
(CIELAB L* 92 → 29, steps of exactly 7), solved for rather than picked.
Smallest adjacent luminance gap 0.032 (the tinted-mode test needs > 0.02).
Text on each is chosen by contrast and is ≥ 4.5:1 on all ten.

| # | Name | Hex | L* | Text |
|---|---|---|---|---|
| 1 | Lemon | `#FFEA5F` | 92 | ink 16.0 |
| 2 | Lime | `#8CED1D` | 85 | ink 13.3 |
| 3 | Aqua | `#18D8BF` | 78 | ink 10.9 |
| 4 | Tangerine | `#FF9326` | 71 | ink 8.8 |
| 5 | Sky | `#16A2F9` | 64 | ink 7.1 |
| 6 | Pink | `#FA3986` | 57 | ink 5.6 |
| 7 | Jade | `#0B8854` | 50 | white 4.5 |
| 8 | Violet | `#7A34F4` | 43 | white 5.8 |
| 9 | Cobalt | `#1241DB` | 36 | white 7.5 |
| 10 | Plum | `#731781` | 29 | white 9.7 |

No red in the ramp, so vermilion only ever means "now / act".
Assignment spreads courses across the whole ramp (6 courses take steps
1, 3, 4, 6, 8, 10) instead of the first six, which were all light.

AI-proposed content is marked by **shape, not hue**: a sparkle glyph and a
dashed outline in ink. It no longer needs its own colour, and can't be
confused with a course.

## Type

One family, SF Pro, made expressive with its width axis rather than a
second typeface.

| Role | Spec | Used for |
|---|---|---|
| Bell | SF Pro **Compressed Black**, 120 pt (small widget 64, Live Activity 56), tabular, tracking −3% | The countdown number. Only ever this. |
| Display | SF Pro Expanded Bold 34 | Screen titles ("Monday"), course name on its page |
| Title | SF Pro Expanded Semibold 22 | Course codes in hero and cards |
| Headline | SF Pro Semibold 17 | Row titles |
| Body | SF Pro Regular 15 | Prose (the brief), descriptions |
| Label | SF Pro Medium 13, sentence case | Section labels, metadata |
| Data | SF Pro Medium, tabular digits, 11–17 | Every time and count |
| Micro | SF Pro Semibold 11 | Widget captions only |

No tracked-out all-caps labels anywhere. Sections are named in sentence case
at Label size; hierarchy comes from size, weight and width.
All sizes scale with Dynamic Type except the Bell number (capped, because it
is already the largest thing on screen; its accessibility label carries it).

## Shape, space, depth

- Course colour appears as solid **slabs**: the hero, timeline blocks, week
  cells, the course page header. Radius 4 on timetable blocks (they're data,
  not buttons), concentric display radius on the hero only.
- No shadows. No card-around-every-group. Groups are separated by space
  (24 / 32) and, where alignment can't do it, a single hairline rule.
- Glass only on what content scrolls under (the collapsed Bell bar, the week
  header, the ask bar), as now.
- Grid: 16 pt margins, a fixed 52 pt time column on every timeline, so times
  line up from screen to screen.

## Motion and haptics

- The Bell number rolls with a numeric content transition each minute.
- The slab drains continuously (no stepping).
- **The one moment of character:** at a transition (class starts or ends)
  while the app is open, the slab "rings": a short damped horizontal swing,
  three cycles, then the colour wipes to the next course with
  `Haptic.confirm`. Reduce Motion: a plain cross-fade, no swing.
- Everything else keeps the existing curves and five-case haptic vocabulary.

## Screens

- **Today**: the Bell slab fills the top ~40%: number, "until ECE 30200
  starts", room, leave-by. It collapses into a 56 pt glass bar on scroll.
  Below: the day as a single vertical track at true scale, Flighty-style:
  time column left, slabs on the track, gaps as an empty track with their
  meaning in words, the now line in vermilion.
- **Week**: five columns of saturated slabs; today's column header inverted
  (ink ground, ground text); past classes drop to 34% as now.
- **Course**: the hero zooms into a full-bleed course-colour header (display
  type in the course's legible ink), then attendance as a row of marks,
  work, the map.
- **Inbox, Settings, Calendar, Location, Mornings**: system forms on the new
  ground, labels in sentence case; the only colour is the signal.
- **Onboarding**: three full-bleed slabs in ramp colours, one idea each, the
  Bell number demonstrated live on the first.
- **Live Activity**: black ground, the Bell number at 56 pt in the course
  colour, a slab progress bar, next class in one line.

## Quality floor

Small iPhones (SE width, 320 pt): the Bell number steps down and the track
narrows its time column. Visible keyboard focus on every control. Reduce
Motion respected (no swing, no drain animation, cross-fades only). Contrast:
all text ≥ 4.5:1, Bell number ≥ 3:1 at minimum on its slab (large text).

## Review of this plan

The first draft was the default: dark ground, a gradient hero card with a
countdown, SF Rounded, cards in a vertical stack. It hedged everywhere and
committed nowhere. What changed and why:

1. **Hero card became a full-bleed slab that drains.** A card is decoration
   around a number; a slab that empties is the number. It's the one place
   that can afford to be expressive because it carries one fact.
2. **Forced dark became system appearance, light by default.** The dark-navy
   look was the "competent and forgettable" part, and daylight corridor
   glances favour light grounds with saturated colour.
3. **Rounded became Compressed and Expanded widths.** Rounded is friendly
   and generic; compressed black numerals read at a distance and give Bell a
   voice no other schedule app has, without a bundled font.
4. **Four semantic hues became one signal.** Fewer colours outside the ramp
   is what lets the ramp be loud.
5. **Dropped:** a split-flap departure-board treatment (that is Flighty's
   borrowed vernacular), and a Swiss-railway red dot (a borrowed icon).
   Kept the railway-timetable discipline for the quiet parts, since that's
   the native language of schedules, not a borrowed one.

Is it a point of view? Yes: a schedule app whose personality is a single
countdown slab, loud where it can afford to be and strict where it can't.
The risk is that a draining slab reads as a progress bar. The ring at
transitions and the size of the number are what keep it from being one.

# Widgets: one question each

| # | Family | Name | The question it answers | Focal point |
|---|---|---|---|---|
| 1 | Small | **Bell** | How long until the next bell? | The countdown number on the course slab |
| 2 | Small | **Behind me** | How much of today is done? | "3 of 5" with the day as filling segments |
| 3 | Medium | **Free** | When am I actually free today? | The longest free stretch, at true scale on a 8am–10pm track |
| 4 | Medium | **Due** | What's due that isn't a class? | The most pressing item and the free hours left before it; tap to tick off |
| 5 | Large | **The rest of today** | What happens next, in order? | The day's track with now marked; mark the class just finished as attended |
| 6 | Large | **Week** | How does the whole week look? | Today's column; one line naming the heaviest day |
| 7 | Lock, rectangular | **Leave** | When do I have to leave, and for where? | The leave-by time |
| 8 | Lock, circular | **Term** | How far through the term am I? | Week number in a ring of term progress |

Overlap check, and why these survive it:

- **Bell vs Leave:** Bell is the countdown to the next transition and who
  it's for; Leave is the walk (when to go, how long, where to). Different
  moments: Bell is read in the room, Leave in your pocket before you move.
- **Behind me vs The rest of today:** one is a ratio and an end time, the
  other is the sequence. Neither shows the other's answer.
- **Free vs The rest of today:** Free shows no classes at all, only the
  spaces between them, so it answers "when", not "what".
- Rejected: a separate "am I going to make this walk" medium. It's the Leave
  question at a larger size, which is the padding the brief warns about.
  Walk feasibility lives inside Leave ("13 min walk, leave 3:12").
- Rejected: an attendance widget. Its data depends on geofencing working on
  the device, so it would be empty for anyone who hasn't turned that on.

Interactive (AppIntent, no app launch): Due ticks a task done; The rest of
today marks the just-finished class attended or missed. The widget process
can't open the SwiftData store, so the intent writes to an App Group queue
the widget reflects immediately and the app applies on its next run.

Every one: exact-boundary timelines (start, end, leave-by, midnight), true
empty states (break, weekend, after the last class, out of term),
containerBackground, accentable group on the focal element, no images.

Widget gallery in Settings: all eight in full colour and in an approximated
tinted mode. The approximation is honest about its limit: the app can render
each widget's tinted layout, but not the system's own tint compositing, so
the home screen is the final check.
