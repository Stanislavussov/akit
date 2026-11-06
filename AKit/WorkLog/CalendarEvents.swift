import AKitKnowledge
import EventKit
import Foundation

/// Import from Calendar (docs/design/worklog.md, W14): the events of some days in the calendars
/// of macOS Calendar (Outlook, Google or iCloud accounts added there), read only, after the
/// person allows AKit to read them. All-day events are left out; an event over midnight is cut
/// to its day.
@MainActor
enum CalendarEvents {
    struct Event: Identifiable, Hashable, Sendable {
        var id: String
        var date: String
        /// Minutes since midnight; `end` may be 1440 (the day's end).
        var start: Int
        var end: Int
        var title: String
        var calendar: String
    }

    enum Access { case granted, denied(String) }

    private static let store = EKEventStore()

    static func requestAccess() async -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted:
            return .denied("AKit may not read your calendars. Allow it in System Settings → Privacy & Security → Calendars, then try again.")
        default:
            do {
                return try await store.requestFullAccessToEvents() ? .granted
                    : .denied("AKit may not read your calendars. Allow it in System Settings → Privacy & Security → Calendars.")
            } catch {
                return .denied("Couldn't ask for calendar access: \(error.localizedDescription)")
            }
        }
    }

    /// The timed events of these days, in time order.
    static func events(on dates: [String]) -> [Event] {
        var result: [Event] = []
        let calendar = Calendar.current
        for date in dates {
            guard let start = KnowledgeWorkLog.date(date), let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            for event in store.events(matching: predicate) where !event.isAllDay {
                guard let from = event.startDate, let to = event.endDate else { continue }
                // Declined invitations are not time spent.
                if event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { continue }
                let first = max(0, Int(from.timeIntervalSince(start) / 60))
                let last = min(24 * 60, Int(to.timeIntervalSince(start) / 60))
                guard last > first else { continue }
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(Event(id: "\(date) \(event.calendarItemIdentifier) \(first)", date: date, start: first, end: last,
                                    title: title.isEmpty ? "Meeting" : title, calendar: event.calendar?.title ?? ""))
            }
        }
        return result.sorted { ($0.date, $0.start, $0.title) < ($1.date, $1.start, $1.title) }
    }
}
