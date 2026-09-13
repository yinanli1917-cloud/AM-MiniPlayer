/**
 * [INPUT]: Foundation only — no Translation/SwiftUI dependency.
 * [OUTPUT]: TranslationRequestCoalescer — a pure, testable debounce gate.
 * [POS]: Services — used by LyricsService.requestTranslation (task A5 part 2).
 *
 * Extracted from LyricsView's inline generation-counter
 * (updateTranslationSessionConfig/scheduleTranslationRequest) so the
 * coalescing decision can be driven by a fake/injected clock in headless
 * tests instead of a real `DispatchQueue.main.asyncAfter`. Behavior is
 * unchanged: a burst of `trigger()` calls within `delay` collapses to the
 * LAST call — earlier callers' `fire` closures are dropped because the
 * generation check fails once a newer trigger has landed.
 */

import Foundation

@MainActor
public final class TranslationRequestCoalescer {
    public let delay: TimeInterval
    private let sleep: (TimeInterval) async -> Void
    private var generation = 0

    public init(
        delay: TimeInterval,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    /// Bumps the generation and schedules `fire` after `delay`. If `trigger`
    /// is called again before the delay elapses, THIS call's `fire` is
    /// dropped — only the newest survives. Returns the scheduling task so
    /// tests can `await` it deterministically instead of racing a real timer.
    @discardableResult
    public func trigger(fire: @escaping () -> Void) -> Task<Void, Never> {
        generation += 1
        let token = generation
        return Task { @MainActor [sleep, delay] in
            await sleep(delay)
            guard token == self.generation else { return }
            fire()
        }
    }
}
