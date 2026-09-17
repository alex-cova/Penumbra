import Foundation

protocol DistractionFreeCancellation: AnyObject {
    func cancel()
}

protocol DistractionFreeScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DistractionFreeCancellation
}

private final class UncheckedClosure: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

private final class TimerCancellation: DistractionFreeCancellation {
    private var timer: Timer?

    init(delay: TimeInterval, action: @escaping () -> Void) {
        let action = UncheckedClosure(action)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action.run() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        cancel()
    }
}

private struct RunLoopDistractionFreeScheduler: DistractionFreeScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DistractionFreeCancellation {
        TimerCancellation(delay: delay, action: action)
    }
}

/// State machine for distraction-free chrome. Rendering remains owned by `TextView` and its host.
final class DistractionFreeController {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            idleCancellation?.cancel()
            idleCancellation = nil
            setChromeVisible(true, animated: false)
        }
    }
    var idleDelay: TimeInterval = 1.5
    var fadeDuration: TimeInterval = 0.3
    var onVisibilityChange: ((Bool, TimeInterval) -> Void)?
    private(set) var isChromeVisible = true

    private let scheduler: DistractionFreeScheduling
    private var idleCancellation: DistractionFreeCancellation?

    init(scheduler: DistractionFreeScheduling = RunLoopDistractionFreeScheduler()) {
        self.scheduler = scheduler
    }

    func typingDidBegin() {
        guard isEnabled else { return }
        setChromeVisible(false, animated: true)
        idleCancellation?.cancel()
        idleCancellation = scheduler.schedule(after: max(idleDelay, 0)) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.idleCancellation = nil
            self.setChromeVisible(true, animated: true)
        }
    }

    func mouseDidMove() {
        guard isEnabled else { return }
        idleCancellation?.cancel()
        idleCancellation = nil
        setChromeVisible(true, animated: true)
    }

    func invalidate() {
        idleCancellation?.cancel()
        idleCancellation = nil
    }

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible
        onVisibilityChange?(visible, animated ? fadeDuration : 0)
    }

    deinit {
        invalidate()
    }
}
