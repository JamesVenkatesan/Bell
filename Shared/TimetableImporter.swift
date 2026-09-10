import Foundation

/// Reads a `.timetable` export.
///
/// The file is a ZIP archive containing a single `Events.xml`, which is an
/// Apple property list — not arbitrary XML. `PropertyListDecoder` handles it
/// directly once the archive is unpacked.
enum TimetableImporter {

    enum ImportError: LocalizedError {
        case couldNotOpenArchive
        case missingEventsFile
        case malformedPropertyList(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .couldNotOpenArchive:
                "That file isn't a timetable export. Export again from the app's share sheet and pick the .timetable file."
            case .missingEventsFile:
                "The export is missing its Events.xml. Try exporting again."
            case .malformedPropertyList(let error):
                "The export couldn't be read: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Entry point

    static func timetable(from url: URL) throws -> Timetable {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try unpackEventsPlist(at: url)
        return try timetable(fromPropertyList: data)
    }

    static func timetable(fromPropertyList data: Data) throws -> Timetable {
        do {
            let payload = try PropertyListDecoder().decode(ExportPayload.self, from: data)
            return payload.toTimetable()
        } catch {
            throw ImportError.malformedPropertyList(underlying: error)
        }
    }

    // MARK: - Archive handling

    /// Uses `FileManager`'s built-in archive support where possible and falls
    /// back to reading the file directly if the user handed us a bare plist.
    private static func unpackEventsPlist(at url: URL) throws -> Data {
        // Some exports arrive already unwrapped.
        if let data = try? Data(contentsOf: url), looksLikePropertyList(data) {
            return data
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("bell-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Zip.unzip(archive: url, into: destination)

        let contents = try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)

        guard let plist = contents.first(where: { $0.lastPathComponent == "Events.xml" })
                ?? contents.first(where: { $0.pathExtension == "xml" || $0.pathExtension == "plist" })
        else { throw ImportError.missingEventsFile }

        return try Data(contentsOf: plist)
    }

    private static func looksLikePropertyList(_ data: Data) -> Bool {
        let head = data.prefix(6)
        return head.starts(with: Array("<?xml ".utf8)) || head.starts(with: Array("bplist".utf8))
    }

    // MARK: - Wire format
    //
    // Mirrors the plist exactly. Everything user-facing is translated in
    // `toTimetable()` so the rest of the app never sees these shapes.

    private struct ExportPayload: Decodable {
        var WeekEvents: [WireEvent]?
        var TaskEvents: [WireTask]?
        var Settings: WireSettings?

        struct WireEvent: Decodable {
            var title: String
            var info: String?
            var dayNum: Int
            var time: Double
            var endTime: Double
            var weekNum: Int?
        }

        struct WireTask: Decodable {
            var title: String?
            var category: String?
            var dueDate: Date?
        }

        struct WireSettings: Decodable {
            var NumberOfWeeks: Int?
            var WeekendDaysAreActive: Bool?
        }

        func toTimetable() -> Timetable {
            var table = Timetable()
            table.weekCount = max(1, Settings?.NumberOfWeeks ?? 1)
            table.showsWeekends = Settings?.WeekendDaysAreActive ?? false

            table.events = (WeekEvents ?? []).map { wire in
                ClassEvent(
                    course: wire.title.trimmingCharacters(in: .whitespaces),
                    room: (wire.info ?? "").trimmingCharacters(in: .whitespaces),
                    dayIndex: wire.dayNum,
                    startSecond: Int(wire.time.rounded()),
                    endSecond: Int(wire.endTime.rounded()),
                    weekIndex: wire.weekNum ?? 0
                )
            }
            .sorted { ($0.weekIndex, $0.dayIndex, $0.startSecond) < ($1.weekIndex, $1.dayIndex, $1.startSecond) }

            table.tasks = (TaskEvents ?? []).compactMap { wire in
                guard let due = wire.dueDate else { return nil }
                return TaskEvent(
                    title: wire.title ?? "Untitled",
                    course: wire.category,
                    due: due,
                    kind: .other
                )
            }

            return table
        }
    }
}

// MARK: - Minimal ZIP reader
//
// Stored and deflated entries only, which is all these exports use. Avoids
// pulling in a dependency for a 900-byte archive.

enum Zip {
    static func unzip(archive: URL, into directory: URL) throws {
        let data = try Data(contentsOf: archive)

        for entry in try Reader(data: data).entries() {
            let target = directory.appendingPathComponent(entry.name)
            // Refuse entries that would escape the destination directory.
            guard target.standardized.path.hasPrefix(directory.standardized.path) else { continue }

            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try entry.data.write(to: target)
        }
    }

    struct Entry {
        var name: String
        var data: Data
    }

    struct Reader {
        let data: Data

        func entries() throws -> [Entry] {
            var results: [Entry] = []
            var cursor = 0

            while cursor + 30 <= data.count {
                guard read32(at: cursor) == 0x0403_4B50 else { break }

                let method = read16(at: cursor + 8)
                let compressedSize = Int(read32(at: cursor + 18))
                let uncompressedSize = Int(read32(at: cursor + 22))
                let nameLength = Int(read16(at: cursor + 26))
                let extraLength = Int(read16(at: cursor + 28))

                let nameStart = cursor + 30
                let payloadStart = nameStart + nameLength + extraLength
                guard payloadStart + compressedSize <= data.count else { break }

                let name = String(
                    decoding: data[nameStart ..< nameStart + nameLength], as: UTF8.self)
                let payload = Data(data[payloadStart ..< payloadStart + compressedSize])

                if !name.hasSuffix("/") {
                    let decoded: Data
                    switch method {
                    case 0: decoded = payload
                    case 8: decoded = try payload.inflated(expecting: uncompressedSize)
                    default: throw TimetableImporter.ImportError.couldNotOpenArchive
                    }
                    results.append(Entry(name: name, data: decoded))
                }

                cursor = payloadStart + compressedSize
            }

            guard !results.isEmpty else {
                throw TimetableImporter.ImportError.couldNotOpenArchive
            }
            return results
        }

        private func read16(at offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }

        private func read32(at offset: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
        }
    }
}

import Compression

private extension Data {
    /// Raw DEFLATE, as stored in a ZIP local file entry.
    func inflated(expecting capacity: Int) throws -> Data {
        let destinationSize = Swift.max(capacity, count * 8, 4096)
        var output = Data(count: destinationSize)

        let written: Int = try output.withUnsafeMutableBytes { destination in
            try withUnsafeBytes { source -> Int in
                guard
                    let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { throw TimetableImporter.ImportError.couldNotOpenArchive }

                return compression_decode_buffer(
                    destinationBase, destinationSize,
                    sourceBase, count,
                    nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { throw TimetableImporter.ImportError.couldNotOpenArchive }
        return output.prefix(written)
    }
}
