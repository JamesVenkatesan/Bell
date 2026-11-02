import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a schedule with Apple's on-device model.
///
/// Runs entirely on the device: no key, no network, no per-request cost, and
/// nothing about your timetable leaves the phone. That last point isn't
/// incidental — a class schedule is a record of where you are at every hour of
/// the week, and sending it to someone's server to be parsed would be a poor
/// trade for a feature this small.
///
/// The model's job is deliberately narrow. It isn't asked to understand a
/// schedule, judge what matters, or resolve ambiguity. It's asked to turn
/// semi-structured text into rows, which is the thing a small model does well
/// and a regular expression does badly the moment a layout varies.
///
/// Everything beyond that — what changed, what to trust, what to write — is
/// ordinary code, where it can be tested.
enum IntelligentParser {

    /// Whether the on-device model can run here. False on hardware without
    /// Apple Intelligence, when the user has it switched off, while the model
    /// is still downloading, and in the simulator.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Why it isn't available, in words worth showing a user.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to use smart import."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading."
            case .unavailable:
                return "The on-device model isn't available right now."
            }
        }
        #endif
        return "Smart import needs iOS 26 or later."
    }

    // MARK: - Parsing

    static func parse(_ text: String) async -> [ParsedEvent] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), isAvailable {
            return await parseWithModel(text)
        }
        #endif
        return []
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private static func parseWithModel(_ text: String) async -> [ParsedEvent] {
        let session = LanguageModelSession(instructions: instructions)
        var all: [ParsedEvent] = []

        // The context window is small — a few thousand tokens — and a full
        // timetable page can exceed it. Chunking also helps accuracy: a short
        // prompt about twelve lines produces better rows than a long one about
        // a hundred, because there is less for attention to get lost in.
        for chunk in chunks(of: text) {
            guard let extracted = await extract(chunk, with: session) else { continue }
            all.append(contentsOf: extracted)
        }

        return all
    }

    @available(iOS 26, *)
    private static func extract(_ chunk: String,
                                with session: LanguageModelSession) async -> [ParsedEvent]? {
        do {
            let response = try await session.respond(
                to: "Extract every class meeting from this schedule text:\n\n\(chunk)",
                generating: ExtractedSchedule.self)

            return response.content.meetings.flatMap(\.parsedEvents)
        } catch {
            // One bad chunk shouldn't lose the rest of the page. The
            // heuristic parser has already covered this text anyway, so a
            // failure here degrades confidence rather than the result.
            return nil
        }
    }

    private static let instructions = """
        You read university class schedules and extract the meetings.

        Rules:
        - Day letters follow the registrar convention: M=Monday, T=Tuesday, \
        W=Wednesday, R=Thursday, F=Friday. R is Thursday, not Tuesday.
        - "MWF" means three separate meetings. "TR" means two.
        - Report times in 24-hour HH:mm. "3:30p" is "15:30".
        - A course code is a subject and a number, like "ECE 30100".
        - A room is a building code and a number, like "WTHR 200". The course \
        comes before the room on a line.
        - Online or remote classes may have no room. Leave the room empty.
        - Report only meetings you can actually see. Never invent a class, a \
        time or a room to fill a gap.
        """

    /// Splits on line boundaries, never mid-line: half a table row is worse
    /// than no row, because it parses into something plausible and wrong.
    private static func chunks(of text: String, linesPerChunk: Int = 14) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.count > 4 }   // page furniture, stray marks

        guard !lines.isEmpty else { return [] }

        return stride(from: 0, to: lines.count, by: linesPerChunk).map { start in
            let end = min(start + linesPerChunk, lines.count)
            return lines[start ..< end].joined(separator: "\n")
        }
    }
    #endif
}

// MARK: - Generated shape

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
struct ExtractedSchedule {
    @Guide(description: "Every class meeting visible in the text")
    var meetings: [ExtractedMeeting]
}

@available(iOS 26, *)
@Generable
struct ExtractedMeeting {
    @Guide(description: "Course code, subject and number, like ECE 30100")
    var courseCode: String

    @Guide(description: "Room, like WTHR 200. Empty string if online or not shown.")
    var room: String

    @Guide(description: "Day letters: M T W R F, where R is Thursday. MWF for three days.")
    var days: String

    @Guide(description: "Start time, 24-hour, HH:mm")
    var startTime: String

    @Guide(description: "End time, 24-hour, HH:mm")
    var endTime: String
}

@available(iOS 26, *)
extension ExtractedMeeting {
    /// One meeting per day letter. Anything that doesn't convert cleanly is
    /// dropped rather than guessed — a row the model half-produced is a row
    /// that will be wrong in a way that's hard to spot on review.
    var parsedEvents: [ParsedEvent] {
        guard
            let start = Self.seconds(from: startTime),
            let end = Self.seconds(from: endTime),
            end > start
        else { return [] }

        let course = courseCode.trimmingCharacters(in: .whitespaces)
        guard !course.isEmpty else { return [] }

        let letters: [Character: Int] = ["M": 0, "T": 1, "W": 2, "R": 3, "F": 4, "S": 5, "U": 6]
        let days = days.uppercased().compactMap { letters[$0] }
        guard !days.isEmpty else { return [] }

        return Set(days).sorted().map { day in
            ParsedEvent(
                event: ClassEvent(course: course,
                                  room: room.trimmingCharacters(in: .whitespaces),
                                  dayIndex: day,
                                  startSecond: start,
                                  endSecond: end,
                                  weekIndex: 0),
                // Set by the reconciler once both parsers have had their say.
                confidence: 0.5)
        }
    }

    private static func seconds(from value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ..< 24).contains(hour), (0 ..< 60).contains(minute)
        else { return nil }

        return hour * 3600 + minute * 60
    }
}
#endif
