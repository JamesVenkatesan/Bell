import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The facts of a day, settled before anyone writes a sentence about it.
struct BriefFacts: Equatable {
    var day: Date
    var holiday: String?
    var classes: [ScheduleEngine.Occurrence]
    var cancelled: [ScheduleEngine.Occurrence]
    var wake: WakePlan?
    /// The longest stretch of free time between the first and last class.
    var longestGap: DateInterval?
    var gapSuggestion: GapAdvisor.Suggestion?
    var tightChanges: [(from: ScheduleEngine.Occurrence, to: ScheduleEngine.Occurrence, walkMinutes: Int)]
    var conflicts: [ConflictDetector.Conflict]
    /// Most pressing first.
    var pressures: [DeadlinePressure]

    static func == (a: BriefFacts, b: BriefFacts) -> Bool {
        a.day == b.day && a.holiday == b.holiday && a.classes == b.classes && a.cancelled == b.cancelled
            && a.wake == b.wake && a.longestGap == b.longestGap && a.gapSuggestion == b.gapSuggestion
            && a.tightChanges.map(\.walkMinutes) == b.tightChanges.map(\.walkMinutes)
            && a.conflicts == b.conflicts && a.pressures == b.pressures
    }

    static func build(day: Date,
                      engine: ScheduleEngine,
                      busy: [ExternalEvent],
                      hidden: Set<String>,
                      wake: WakePlan?,
                      now: Date,
                      walkSeconds: (String?, String?) -> TimeInterval = Campus.walkingSeconds) -> BriefFacts {
        let classes = engine.occurrences(on: day).filter { !hidden.contains($0.event.course) }
        let dayBusy = busy.filter { engine.calendar.isDate($0.start, inSameDayAs: day) }

        var gap: DateInterval?
        if let first = classes.first, let last = classes.map(\.end).max() {
            gap = FreeTime.intervals(engine: engine, busy: dayBusy, from: first.end, to: last,
                                     minimumMinutes: 45)
                .max { $0.duration < $1.duration }
        }

        let tight = zip(classes, classes.dropFirst()).compactMap { a, b -> (ScheduleEngine.Occurrence, ScheduleEngine.Occurrence, Int)? in
            let walk = walkSeconds(a.event.building, b.event.building)
            guard walk > 0, b.start.timeIntervalSince(a.end) < walk else { return nil }
            return (a, b, Int((walk / 60).rounded()))
        }

        // Pressure over the next three days: further out isn't this
        // morning's problem.
        let horizon = engine.calendar.date(byAdding: .day, value: 3, to: engine.calendar.startOfDay(for: day)) ?? day
        let pressures = DeadlinePressure.evaluate(
            tasks: engine.timetable.tasks.filter { $0.due < horizon },
            engine: engine, busy: busy, now: now)
            .filter { $0.level != .overdue }

        let suggestion = gap.flatMap { GapAdvisor.suggest(gaps: [$0], pressures: pressures).first }

        return BriefFacts(
            day: day,
            holiday: engine.exception(on: day)?.name,
            classes: classes,
            cancelled: engine.cancelledOccurrences(on: day),
            wake: wake,
            longestGap: gap,
            gapSuggestion: suggestion,
            tightChanges: tight.map { ($0.0, $0.1, $0.2) },
            conflicts: ConflictDetector.conflicts(classes: classes, events: dayBusy, walkSeconds: walkSeconds),
            pressures: Array(pressures.prefix(2)))
    }

    // MARK: - Grounding vocabulary

    /// Every clock time a sentence about this day may contain.
    var allowedTimes: Set<String> {
        var dates: [Date] = classes.flatMap { [$0.start, $0.end] }
        if let wake { dates += [wake.wakeAt, wake.leaveAt] }
        if let longestGap { dates += [longestGap.start, longestGap.end] }
        dates += pressures.map(\.task.due)
        dates += conflicts.flatMap { [$0.event.start, $0.event.end] }
        dates += cancelled.map(\.start)
        return Set(dates.map(BriefWriter.digits))
    }

    var allowedCourses: Set<String> {
        Set(classes.map(\.event.course) + cancelled.map(\.event.course)
            + pressures.compactMap(\.task.course) + conflicts.map(\.occurrence.event.course))
    }

    /// Rooms have the same shape as course codes ("BHEE 170", "ECE 30100"),
    /// so the code check must know them too, or every sentence that names a
    /// room fails it and the model's prose is never used.
    var allowedRooms: Set<String> {
        Set((classes + cancelled).map(\.event.room) + conflicts.compactMap(\.event.location)
            + pressures.compactMap(\.task.location))
    }
}

/// Turns facts into a few sentences.
///
/// Prose, not a list, because a brief read at 7am over coffee should sound
/// like someone who knows your day, and a list of rows is just the timeline
/// again. The template is always written first and is complete on its own;
/// the model's version is used only if it passes `isGrounded`.
enum BriefWriter {

    /// "4:20 PM". With the half of the day, because "free from 11:20 to
    /// 10:00" read as a stretch that ends before it starts. Built by hand
    /// rather than with `formatted`, whose narrow no-break space before PM
    /// makes the text awkward to match and to test.
    static func clock(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return digits(date) + (hour < 12 ? " AM" : " PM")
    }

    /// "4:20": what the grounding check compares, so a model writing "4:20pm"
    /// or "4:20 in the afternoon" is matched on the time itself.
    static func digits(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = (c.hour ?? 0) % 12 == 0 ? 12 : (c.hour ?? 0) % 12
        return String(format: "%d:%02d", hour, c.minute ?? 0)
    }

    // MARK: - Template

    static func template(_ facts: BriefFacts, now: Date) -> String {
        let calendar = Calendar.current
        // Relative to `now`, not the system clock, so an evening preview of
        // tomorrow says "tomorrow" and a test can say when "now" is.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let dayWord = calendar.isDate(facts.day, inSameDayAs: now) ? "today"
            : calendar.isDate(facts.day, inSameDayAs: tomorrow) ? "tomorrow"
            : "on " + facts.day.formatted(.dateTime.weekday(.wide))

        if let holiday = facts.holiday {
            return "\(holiday): no classes \(dayWord)." + pressureSentence(facts).map { " " + $0 }.orEmpty
        }
        guard let first = facts.classes.first, let last = facts.classes.last else {
            return "No classes \(dayWord)." + pressureSentence(facts).map { " " + $0 }.orEmpty
        }

        var sentences: [String] = []
        let count = facts.classes.count
        let room = first.event.room.isEmpty ? "" : " in \(first.event.room)"
        sentences.append("\(countWord(count).capitalizedFirst) class\(count == 1 ? "" : "es") \(dayWord), "
                         + "starting with \(first.event.course) at \(clock(first.start))\(room).")

        if let wake = facts.wake {
            let walk: String = switch wake.walkSource {
            case .home: "a \(wake.walkMinutes) minute walk from home"
            case .lastLocation: "a \(wake.walkMinutes) minute walk from where your phone was last"
            case .estimate: "a guessed \(wake.walkMinutes) minute walk"
            }
            sentences.append("Up by \(clock(wake.wakeAt)) and out by \(clock(wake.leaveAt)), allowing \(walk).")
        }

        if let tight = facts.tightChanges.first {
            sentences.append("The change from \(tight.from.event.course) to \(tight.to.event.course) is tight: "
                             + "\(Int(tight.to.start.timeIntervalSince(tight.from.end) / 60)) minutes for a "
                             + "\(tight.walkMinutes) minute walk.")
        }

        if let conflict = facts.conflicts.first {
            sentences.append("\(conflict.event.title) at \(clock(conflict.event.start)) clashes with "
                             + "\(conflict.occurrence.event.course).")
        }

        if let gap = facts.longestGap {
            var sentence = "You're free from \(clock(gap.start)) to \(clock(gap.end))"
            if let suggestion = facts.gapSuggestion, let task = suggestion.task {
                sentence += ", which is the time for \(task.title)"
            } else if facts.gapSuggestion?.text == "Time for lunch" {
                sentence += ", over lunch"
            }
            sentences.append(sentence + ".")
        }

        if let pressure = pressureSentence(facts, skipping: facts.gapSuggestion?.task) {
            sentences.append(pressure)
        }

        if !facts.cancelled.isEmpty {
            sentences.append("\(facts.cancelled.map(\.event.course).joined(separator: " and ")) is cancelled.")
        }

        sentences.append("Done at \(clock(last.end)).")
        return sentences.joined(separator: " ")
    }

    private static func pressureSentence(_ facts: BriefFacts, skipping: TaskEvent? = nil) -> String? {
        guard let pressure = facts.pressures.first(where: { $0.task.id != skipping?.id && $0.level >= .tight })
        else { return nil }
        let due = Calendar.current.isDate(pressure.task.due, inSameDayAs: facts.day)
            ? "due at \(clock(pressure.task.due))"
            : "due \(pressure.task.due.formatted(.dateTime.weekday(.wide))) at \(clock(pressure.task.due))"
        return "\(pressure.task.title) is \(due), with about \(Int(pressure.freeHours.rounded())) free "
            + "hours left before it."
    }

    private static func countWord(_ n: Int) -> String {
        ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][safe: n] ?? "\(n)"
    }

    // MARK: - Grounding

    /// True when every clock time and course code in `prose` is one the
    /// facts contain. Measured, not trusted: a brief that invents "your 2:30"
    /// is worse than the plain template, because you'd act on it.
    static func isGrounded(_ prose: String, in facts: BriefFacts) -> Bool {
        let times = matches(#"\b\d{1,2}:\d{2}\b"#, in: prose)
        guard times.allSatisfy(facts.allowedTimes.contains) else { return false }

        let codes = matches(#"\b[A-Z]{2,5} \d{3,5}[A-Z]?\b"#, in: prose)
        let allowed = Set(facts.allowedCourses.map { $0.replacingOccurrences(of: "TA: ", with: "") })
        let rooms = facts.allowedRooms
        return codes.allSatisfy { code in
            allowed.contains(code) || rooms.contains { $0.contains(code) }
        }
    }

    /// Times and course codes can be right while the meaning is wrong. Run
    /// for real, the model turned "Up by 6:25 AM and out by 7:10 AM" into
    /// "You were up by 6:25 AM", at 2:30 in the morning. When nothing in the
    /// brief has happened yet, past-tense phrasing about the user is a
    /// rewrite that changed the facts, and the template is used instead.
    static func keepsTense(_ prose: String, facts: BriefFacts, now: Date) -> Bool {
        let firstEvent = facts.wake?.wakeAt ?? facts.classes.first?.start
        guard let firstEvent, firstEvent > now else { return true }
        let past = #"\b(you were|you was|you've been|you had|you went|you got|was up|were out|you left|you woke)\b"#
        return prose.range(of: past, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: - Model

    /// The template, rephrased by the on-device model when that helps, and
    /// the template itself otherwise. Never nil, never ungrounded.
    static func write(_ facts: BriefFacts, now: Date) async -> (text: String, byModel: Bool) {
        let plain = template(facts, now: now)
        #if canImport(FoundationModels)
        guard IntelligentParser.isAvailable else { return (plain, false) }
        let session = LanguageModelSession(instructions: """
            You rewrite a student's daily schedule summary so it reads naturally, like a \
            friend who knows their day. Two to four sentences of prose, no lists, no \
            greeting, no emoji. Use only the facts given. Keep every time and every \
            course code exactly as written. Do not add advice the facts don't support. \
            Keep the tense of the summary: what is still ahead stays in the future.
            """)
        let prompt = "It is now \(clock(now)).\n\nSummary:\n\(plain)"
        guard let response = try? await session.respond(to: prompt),
              isGrounded(response.content, in: facts),
              keepsTense(response.content, facts: facts, now: now),
              response.content.count <= plain.count * 2
        else { return (plain, false) }
        return (response.content.trimmingCharacters(in: .whitespacesAndNewlines), true)
        #else
        return (plain, false)
        #endif
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
