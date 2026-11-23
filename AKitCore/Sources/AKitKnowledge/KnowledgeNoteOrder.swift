import Foundation

/// The order of notes in the note list (K42): notes whose title starts with a number
/// (`(1) Entry`, `2. Form`, `3) Submit`, `[4] Captcha`) first, by that number, so a run of tasks
/// reads 1, 2, 3 … 10 and stays together; then the other notes by title, digits as numbers.
extension KnowledgeBase.NoteEntry {
    /// The number the title starts with, nil when it starts otherwise. A date (`2026-11-18 …`)
    /// or a version (`1.5 …`) is no number here: the number ends in `)`, `]` or `.` and a space.
    public var number: Int? {
        guard let match = title.firstMatch(of: /^\s*[(\[]?(\d{1,3})[)\].](?:\s|$)/) else { return nil }
        return Int(match.1)
    }

    /// The notes in list order.
    public static func inListOrder(_ notes: [Self]) -> [Self] {
        notes.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
        }
    }
}
