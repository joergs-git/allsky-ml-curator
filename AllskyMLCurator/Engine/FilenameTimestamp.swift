import Foundation

/// Parses a UTC capture timestamp out of an allsky filename. Multiple
/// patterns are tried in priority order; if none match the caller can
/// fall back to the file's modification date.
///
/// Assumed timezone: UTC. Most allsky capture pipelines write UTC into
/// filenames — including the sibling `astro-weather` daemon — so that's
/// the default. If a deployment uses local time the user can work
/// around it by converting before ingest or by naming conventions that
/// carry the offset explicitly.
enum FilenameTimestamp {

    /// Attempt to parse a timestamp from a filename (with or without
    /// path components / extension). Returns `nil` if no supported
    /// pattern matches.
    static func parse(_ filename: String) -> Date? {
        for pattern in patterns {
            if let date = tryParse(pattern: pattern, in: filename) {
                return date
            }
        }
        return nil
    }

    // MARK: - Patterns

    /// Each pattern captures `(year, month, day, hour, minute, second)`
    /// in that order as its first six groups.
    private static let patterns: [String] = [
        // "2024-06-21_11-30-45" or "2024-06-21T11-30-45" or "2024-06-21 11:30:45"
        #"(\d{4})-(\d{2})-(\d{2})[ _T](\d{2})[:_\-](\d{2})[:_\-](\d{2})"#,
        // "20240621_113045" or "20240621T113045"
        #"(\d{4})(\d{2})(\d{2})[ _T]?(\d{2})(\d{2})(\d{2})"#,
        // "2024-06-21-11-30-45"
        #"(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})"#
    ]

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func tryParse(pattern: String, in filename: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              match.numberOfRanges >= 7 else {
            return nil
        }

        let ns = filename as NSString
        func component(_ index: Int) -> Int? {
            let r = match.range(at: index)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }

        guard
            let year   = component(1),
            let month  = component(2),
            let day    = component(3),
            let hour   = component(4),
            let minute = component(5),
            let second = component(6)
        else { return nil }

        // Guard against spurious numeric matches that aren't real dates.
        guard (1970...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...61).contains(second)
        else { return nil }

        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year   = year
        components.month  = month
        components.day    = day
        components.hour   = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }
}
