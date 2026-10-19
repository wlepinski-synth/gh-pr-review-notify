import Foundation

/// Runs `tick` every `interval()` minutes, waiting longer (up to 8x) while ticks fail.
/// While paused nothing runs; resuming ticks straight away.
@MainActor
final class Poller {
    private var task: Task<Void, Never>?
    private var interval: (@MainActor () -> Int)?
    private var tick: (@MainActor () async -> Bool)?
    private(set) var isPaused = false

    func start(interval: @escaping @MainActor () -> Int, tick: @escaping @MainActor () async -> Bool) {
        self.interval = interval
        self.tick = tick
        schedule()
    }

    func pause() {
        isPaused = true
        task?.cancel()
        task = nil
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        schedule()
    }

    private func schedule() {
        guard task == nil, !isPaused, let interval, let tick else { return }
        task = Task { @MainActor in
            var failures = 0
            while !Task.isCancelled {
                failures = await tick() ? 0 : failures + 1
                let backoff = Double(min(1 << failures, 8))
                try? await Task.sleep(for: .seconds(Double(interval()) * 60 * backoff))
            }
        }
    }
}
