/// Monotonic seconds, supplied by the caller, make keyboard timing deterministic.
public struct DictationGesture {
    public enum Action: Equatable { case start, stop }
    private enum State {
        case idle, pressed(Double), waiting(Double), latched
    }
    private var state: State = .idle
    public let holdThreshold: Double = 0.25
    public let doubleTapWindow: Double = 0.35

    public init() {}

    public mutating func press(at time: Double) -> [Action] {
        switch state {
        case .idle:
            state = .pressed(time)
            return [.start]
        case .waiting(let deadline) where time <= deadline:
            state = .latched
            return []
        case .waiting:
            state = .pressed(time)
            return [.stop, .start]
        case .latched:
            state = .idle
            return [.stop]
        case .pressed:
            return [] // Ignore keyboard repeat.
        }
    }

    public mutating func release(at time: Double) -> [Action] {
        guard case .pressed(let began) = state else { return [] }
        if time - began >= holdThreshold {
            state = .idle
            return [.stop]
        }
        state = .waiting(time + doubleTapWindow)
        return []
    }

    public mutating func tick(at time: Double) -> [Action] {
        guard case .waiting(let deadline) = state, time > deadline else { return [] }
        state = .idle
        return [.stop]
    }

    public mutating func cancel() -> [Action] {
        if case .idle = state { return [] }
        state = .idle
        return [.stop]
    }
}
