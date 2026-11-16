import Foundation

/// Local calendar-day arithmetic for the replace-window streams. "Day" means the device's local
/// calendar day (23 or 25 hours on DST changes), as the protocol requires.
struct DayMath {
    let calendar: Calendar
    private let formatter: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        self.formatter = f
    }

    /// `YYYY-MM-DD` of the local day containing a Unix timestamp.
    func day(forTimestamp ts: Int64) -> String {
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Unix seconds of local midnight starting `day`.
    func midnight(of day: String) -> Int64? {
        guard let d = formatter.date(from: day) else { return nil }
        return Int64(calendar.startOfDay(for: d).timeIntervalSince1970)
    }

    func nextDay(_ day: String) -> String? {
        guard let d = formatter.date(from: day), let n = calendar.date(byAdding: .day, value: 1, to: d) else {
            return nil
        }
        return formatter.string(from: n)
    }

    /// Whole local days from `a` to `b` (0 when equal, negative if b is earlier).
    func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = formatter.date(from: a), let db = formatter.date(from: b) else { return 0 }
        return calendar.dateComponents([.day], from: da, to: db).day ?? 0
    }
}
