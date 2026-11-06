import Foundation

/// M32: a rough time left for a meeting's processing: the pieces left times the seconds one
/// piece takes (measured in this run, else remembered from earlier runs, else a first guess),
/// plus the summary.
public enum ProcessingEstimate {
    /// How a meeting is processed: each way has its own speed.
    public enum Way: String, Sendable {
        case cloud, localGPU, localCPU

        public init(_ settings: MeetingsSettings) {
            self = settings.transcription == .cloud ? .cloud : settings.localGPU ? .localGPU : .localCPU
        }

        /// The first guess for one 5-minute piece, rest included. Local GPU: measured on an M4
        /// (about 30 s of work, as long a rest); CPU only: about 4× the audio, per track; cloud:
        /// one 30-minute call of about a minute for 6 pieces.
        public var firstGuess: TimeInterval {
            switch self {
            case .cloud: 12
            case .localGPU: 70
            case .localCPU: 1300
            }
        }
    }

    /// The summary call (OpenRouter or Pi), a first guess.
    public static let summarySeconds: TimeInterval = 40

    /// Seconds left: `perPiece` for each piece not done, and the summary unless it is done.
    public static func remaining(done: Int, total: Int, perPiece: TimeInterval, summaryLeft: Bool = true) -> TimeInterval {
        Double(max(0, total - done)) * perPiece + (summaryLeft ? summarySeconds : 0)
    }

    /// The seconds one piece took in this run: the time since the run started over the pieces
    /// it did; nil before the first one.
    public static func measured(piecesDone: Int, since start: Date, now: Date = Date()) -> TimeInterval? {
        guard piecesDone > 0 else { return nil }
        return now.timeIntervalSince(start) / Double(piecesDone)
    }

    /// `≈ 1 min`, `≈ 6 min`, `≈ 1 h 10 min`.
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? String(format: "≈ %d h %02d min", minutes / 60, minutes % 60) : "≈ \(minutes) min"
    }

    // MARK: Remembered speed

    static func key(_ way: Way) -> String { "meetings.secondsPerPiece.\(way.rawValue)" }

    /// The speed remembered from earlier runs on this Mac, else the first guess.
    public static func perPiece(_ way: Way, defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: key(way))
        return value > 0 ? value : way.firstGuess
    }

    /// Keeps a run's speed, mixed with the earlier one so one odd run does not swing it.
    public static func remember(_ seconds: TimeInterval, for way: Way, defaults: UserDefaults = .standard) {
        guard seconds > 0, seconds.isFinite else { return }
        let old = defaults.double(forKey: key(way))
        defaults.set(old > 0 ? old * 0.5 + seconds * 0.5 : seconds, forKey: key(way))
    }
}
