import Foundation

// Hold-to-repeat for ⌫: one delete on start, then repeats after a delay.
final class DeleteRepeat {
    private let initialDelay: TimeInterval
    private let interval: TimeInterval
    private let canDelete: () -> Bool
    private let deleteOnce: () -> Void
    private var initialTimer: Timer?
    private var repeatTimer: Timer?
    // Ignore callbacks of timers that fired after a lost touch-up stopped them.
    private var generation = 0

    init(initialDelay: TimeInterval = 0.35, interval: TimeInterval = 0.08,
         canDelete: @escaping () -> Bool, deleteOnce: @escaping () -> Void) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.canDelete = canDelete
        self.deleteOnce = deleteOnce
    }

    var isRunning: Bool { initialTimer != nil || repeatTimer != nil }

    func start() {
        stop()
        let current = generation
        deleteOnce()
        let initial = Timer(timeInterval: initialDelay, repeats: false) { [weak self] _ in
            guard let self, self.generation == current else { return }
            self.initialTimer = nil
            let repeating = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in
                guard let self, self.generation == current else { return }
                // Nothing left to delete: stop, so a lost touch-up can't eat
                // whatever is typed next.
                guard self.canDelete() else {
                    self.stop()
                    return
                }
                self.deleteOnce()
            }
            self.repeatTimer = repeating
            RunLoop.main.add(repeating, forMode: .common)
        }
        initialTimer = initial
        RunLoop.main.add(initial, forMode: .common)
    }

    func stop() {
        generation &+= 1
        initialTimer?.invalidate()
        initialTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
