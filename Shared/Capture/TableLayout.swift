import CoreGraphics
import Foundation

/// Puts a registrar table back together from where its text sits on the page.
///
/// PDFKit doesn't hand a table over row by row. In real UniTime prints it
/// emits the left half of every row (course, type, CRN, days, times, dates)
/// as one block and the right half (room, instructor, notes, credit) as
/// another, with wrapped cells ("BHEE" / "170") split across lines. In the
/// token stream a row's room arrives dozens of tokens after its CRN, or
/// shuffled among other rows' rooms, so `TableReader` (which walks outward
/// from each CRN) found no room and no instructor for any row. Every
/// existing test passed because they all fed hand-written strings where the
/// room follows its row.
///
/// Position is what survives. A room cell sits at the height of its CRN, and
/// a wrapped cell stays inside its row's band. So: find the header, use each
/// CRN line as a row anchor, give every line to the row whose band it falls
/// in, and write each row out as one line in reading order. `TableReader`
/// then parses it with its existing rules, untouched.
enum TableLayout {

    /// The text of the table, one row per line, or nil when this page has no
    /// recognisable registrar table (leave it to the other readers).
    static func reflow(_ lines: [TextExtraction.Fragment]) -> String? {
        guard let room = lines.first(where: { trimmed($0.text) == "Room" }) else { return nil }
        let roomX = room.frame.minX

        // Column starts on the right-hand side, from the header line. Lines
        // are bucketed by these, so a column reads top to bottom even if
        // its lines' x positions differ by a hair.
        let headerBand = lines.filter { abs($0.frame.midY - room.frame.midY) < room.frame.height }
        let columns = headerBand.map(\.frame.minX).filter { $0 >= roomX - 0.002 }.sorted()

        let anchors = lines
            .filter { $0.frame.minX < roomX && TableReader.tokenize($0.text).contains(where: TableReader.isCRN) }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard !anchors.isEmpty else { return nil }

        // The last row has no next anchor to end its band, so it borrows the
        // typical row pitch. The page footer sits well below that.
        let gaps = zip(anchors, anchors.dropFirst()).map { $1.frame.minY - $0.frame.minY }.sorted()
        let pitch = gaps.isEmpty ? 0.04 : gaps[gaps.count / 2]
        let tolerance = room.frame.height * 0.5

        var rows: [String] = []
        for (index, anchor) in anchors.enumerated() {
            let top = anchor.frame.minY - tolerance
            let bottom = index + 1 < anchors.count ? anchors[index + 1].frame.minY - tolerance
                                                   : anchor.frame.minY + pitch - tolerance
            let band = lines.filter { $0.frame.minY >= top && $0.frame.minY < bottom }

            let left = band.filter { $0.frame.minX < roomX - 0.002 }
                .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            let right = band.filter { $0.frame.minX >= roomX - 0.002 }
                .sorted { (column($0, columns), $0.frame.minY) < (column($1, columns), $1.frame.minY) }

            rows.append((left + right).map { trimmed($0.text) }.joined(separator: " "))
        }
        return rows.joined(separator: "\n")
    }

    private static func column(_ line: TextExtraction.Fragment, _ starts: [CGFloat]) -> Int {
        starts.lastIndex { $0 <= line.frame.minX + 0.005 } ?? 0
    }

    private static func trimmed(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
