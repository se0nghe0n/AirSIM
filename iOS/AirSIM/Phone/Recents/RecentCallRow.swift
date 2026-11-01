import Foundation

/// One Recents row, ready to draw.
struct RecentCallRow: Equatable, Identifiable {
    let id: String
    let call: CallRecord
    /// The contact's name, else the number, else "Unknown Number".
    let name: String
    let photo: Data?
    /// Empty when the number is not a contact, so the avatar shows the generic person glyph.
    let avatarName: String
    let time: String

    init(call: CallRecord, contacts: ContactDirectory) {
        let contact = call.number.flatMap { contacts.contact(for: $0) }
        let name = contact?.name ?? contacts.displayName(for: call.number)
        id = call.id
        self.call = call
        self.name = name
        photo = contact?.photoData
        avatarName = contact == nil ? "" : name
        time = RecentCallTimeFormatter.string(for: call.startedAt)
    }

    var number: String? { call.number }
    var isMissed: Bool { call.missed }
    var dialNumber: String? { RecentCallDialPolicy.numberToDial(call.number) }

    /// "↙ Missed" or "↗ AirSIM Audio".
    var subtitle: String { "\(directionArrow) \(kind)" }
    /// The plain-cell text, also read by VoiceOver: "Missed · ↙ · 10:42".
    var detail: String { "\(kind) · \(directionArrow) · \(time)" }

    private var kind: String { call.missed ? "Missed" : "AirSIM Audio" }
    private var directionArrow: String { call.direction == "incoming" ? "↙" : "↗" }
}

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        // localization.md: use FormatStyle for time and date display so output follows the user locale;
        // 12-hour regions (e.g., en_US) output "2:30 PM" without dropping AM/PM, while 24-hour regions remain "14:30".
        if day == currentDay {
            return date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            )
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "Yesterday"
        }
        if day.year == currentDay.year {
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
        // Cross-year dates follow locale field ordering (e.g., MM/dd/yyyy in English instead of yyyy/MM/dd).
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}
