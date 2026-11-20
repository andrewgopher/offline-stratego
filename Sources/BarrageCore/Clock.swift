import Foundation

public struct TimeControl: Codable, Hashable {
    /// Starting time per player in seconds; `nil` means no clock.
    public var initialSeconds: Int?
    public var incrementSeconds: Int

    public init(initialSeconds: Int?, incrementSeconds: Int = 0) {
        self.initialSeconds = initialSeconds
        self.incrementSeconds = incrementSeconds
    }

    public static let unlimited = TimeControl(initialSeconds: nil)

    public static let presets: [TimeControl] = [
        .unlimited,
        TimeControl(initialSeconds: 60, incrementSeconds: 1),
        TimeControl(initialSeconds: 120, incrementSeconds: 1),
        TimeControl(initialSeconds: 180, incrementSeconds: 0),
        TimeControl(initialSeconds: 180, incrementSeconds: 2),
        TimeControl(initialSeconds: 300, incrementSeconds: 0),
        TimeControl(initialSeconds: 300, incrementSeconds: 3),
        TimeControl(initialSeconds: 600, incrementSeconds: 0),
        TimeControl(initialSeconds: 600, incrementSeconds: 5),
        TimeControl(initialSeconds: 900, incrementSeconds: 10),
        TimeControl(initialSeconds: 1800, incrementSeconds: 0),
    ]

    public var isUnlimited: Bool { initialSeconds == nil }

    /// "5+3", "Unlimited", ...
    public var label: String {
        guard let initial = initialSeconds else { return "Unlimited" }
        let minutes: String
        if initial % 60 == 0 {
            minutes = String(initial / 60)
        } else {
            minutes = String(format: "%.1f", Double(initial) / 60)
        }
        return "\(minutes)+\(incrementSeconds)"
    }

    /// "5 min + 3 s", "Unlimited", ...
    public var displayName: String {
        guard let initial = initialSeconds else { return "Unlimited" }
        let minutes = initial % 60 == 0 ? "\(initial / 60) min" : String(format: "%.1f min", Double(initial) / 60)
        return incrementSeconds > 0 ? "\(minutes) + \(incrementSeconds) s" : minutes
    }
}

/// A two-sided game clock driven by explicit timestamps so it is deterministic and testable.
public struct GameClock: Codable, Hashable {
    public private(set) var redSeconds: Double
    public private(set) var blueSeconds: Double
    public private(set) var running: Side?
    public private(set) var runningSince: Date?

    public init(red: Double, blue: Double) {
        self.redSeconds = red
        self.blueSeconds = blue
    }

    /// Remaining time for `side` at `now` (may be negative once the time has run out).
    public func remaining(_ side: Side, at now: Date) -> Double {
        var value = side == .red ? redSeconds : blueSeconds
        if running == side, let since = runningSince {
            value -= now.timeIntervalSince(since)
        }
        return value
    }

    public var isRunning: Bool { running != nil }

    /// Stops whichever side is running, banking its elapsed time.
    public mutating func stop(at now: Date) {
        if let side = running {
            set(side, remaining(side, at: now))
        }
        running = nil
        runningSince = nil
    }

    public mutating func start(_ side: Side, at now: Date) {
        stop(at: now)
        running = side
        runningSince = now
    }

    /// Overwrites a side's banked time. Stop the clock first if that side is running.
    public mutating func set(_ side: Side, _ seconds: Double) {
        if side == .red { redSeconds = seconds } else { blueSeconds = seconds }
    }

    public mutating func add(_ seconds: Double, to side: Side) {
        set(side, (side == .red ? redSeconds : blueSeconds) + seconds)
    }
}
