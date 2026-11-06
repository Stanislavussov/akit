import Foundation

/// M12: when the microphone carried speech. Levels are the RMS of short windows; a window above
/// the gate is speech; gaps shorter than `bridge` join, spans shorter than `shortest` are dropped.
public enum SpeechSpans {
    public static func spans(levels: [Float], window: TimeInterval, gate: Float = 0.015,
                             bridge: TimeInterval = 0.8, shortest: TimeInterval = 0.4) -> [TimeSpan] {
        var raw: [TimeSpan] = []
        var start: Int?
        for (i, level) in levels.enumerated() {
            if level >= gate {
                if start == nil { start = i }
            } else if let s = start {
                raw.append(TimeSpan(start: Double(s) * window, end: Double(i) * window))
                start = nil
            }
        }
        if let s = start { raw.append(TimeSpan(start: Double(s) * window, end: Double(levels.count) * window)) }
        var merged: [TimeSpan] = []
        for span in raw {
            if let last = merged.last, span.start - last.end < bridge {
                merged[merged.count - 1].end = span.end
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.end - $0.start >= shortest }
    }
}
