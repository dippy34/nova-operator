import Foundation

/// One capture at a time, including across microphone permission and final-result awaits.
/// Generations reject callbacks from a cancelled or replaced recognition task.
struct VoiceCaptureState {
    enum Phase { case idle, starting, listening, finishing }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0
    var listening: Bool { phase == .listening }
    var transitioning: Bool { phase == .starting || phase == .finishing }

    mutating func beginStart() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .starting
        return generation
    }
    func accepts(_ id: UInt64) -> Bool { id == generation && phase != .idle }
    mutating func didStart(_ id: UInt64) -> Bool {
        guard accepts(id), phase == .starting else { return false }
        phase = .listening
        return true
    }
    mutating func beginFinishing() -> UInt64? {
        guard phase == .listening else { return nil }
        phase = .finishing
        return generation
    }
    @discardableResult mutating func finish(_ id: UInt64) -> Bool {
        guard accepts(id) else { return false }
        phase = .idle
        return true
    }
    mutating func cancel() {
        generation &+= 1
        phase = .idle
    }
}

/// Audio callbacks update a tiny mailbox, never an ObservableObject or the main queue.
/// Only the listening overlay samples it (15 Hz); old buffers cannot revive its glow.
final class VoiceMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?
    private var value: CGFloat = 0
    var level: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func begin(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        generation = id; value = 0
    }
    func update(_ level: CGFloat, for id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard generation == id, level.isFinite else { return }
        let clamped = min(1, max(0, level))
        value += (clamped - value) * 0.24
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        generation = nil; value = 0
    }
}
