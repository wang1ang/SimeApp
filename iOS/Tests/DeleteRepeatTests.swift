import UIKit
import XCTest

final class DeleteRepeatTests: XCTestCase {
    private func makeRepeat(canDelete: @escaping () -> Bool = { true },
                            onDelete: @escaping () -> Void) -> DeleteRepeat {
        DeleteRepeat(initialDelay: 0.02, interval: 0.01,
                     canDelete: canDelete, deleteOnce: onDelete)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testStartDeletesOnceThenRepeats() {
        var count = 0
        let repeater = makeRepeat { count += 1 }
        repeater.start()
        XCTAssertEqual(count, 1)
        spin(0.15)
        XCTAssertGreaterThan(count, 2)
        repeater.stop()
    }

    func testStopEndsRepeat() {
        var count = 0
        let repeater = makeRepeat { count += 1 }
        repeater.start()
        spin(0.08)
        repeater.stop()
        XCTAssertFalse(repeater.isRunning)
        let stopped = count
        spin(0.1)
        XCTAssertEqual(count, stopped)
    }

    func testStopBeforeInitialDelayLeavesSingleDelete() {
        var count = 0
        let repeater = makeRepeat { count += 1 }
        repeater.start()
        repeater.stop()
        spin(0.1)
        XCTAssertEqual(count, 1)
    }

    // A lost touch-up must not keep deleting what the user types next.
    func testRepeatStopsItselfWhenNothingLeftToDelete() {
        var remaining = 3
        let repeater = makeRepeat(canDelete: { remaining > 0 }) { remaining -= 1 }
        repeater.start()
        spin(0.15)
        XCTAssertEqual(remaining, 0)
        XCTAssertFalse(repeater.isRunning)
        remaining = 2
        spin(0.1)
        XCTAssertEqual(remaining, 2)
    }

    func testRestartDoesNotStackTimers() {
        var count = 0
        let repeater = makeRepeat { count += 1 }
        repeater.start()
        repeater.start()
        XCTAssertEqual(count, 2)
        repeater.stop()
        spin(0.1)
        XCTAssertEqual(count, 2)
    }

    // Releasing on another key fires that key and still ends the source press,
    // which is what stops a held ⌫.
    func testDragReleaseEndsSourceAndFiresTarget() {
        let source = KeyButton()
        let target = KeyButton()
        var events: [String] = []
        source.addAction(UIAction { _ in events.append("source.touchUpOutside") },
                         for: .touchUpOutside)
        source.addAction(UIAction { _ in events.append("source.touchUpInside") },
                         for: .touchUpInside)
        target.addAction(UIAction { _ in events.append("target.touchUpInside") },
                         for: .touchUpInside)

        var count = 0
        let repeater = makeRepeat { count += 1 }
        source.addAction(UIAction { _ in repeater.start() }, for: .touchDown)
        source.addAction(UIAction { _ in repeater.stop() },
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])

        source.sendActions(for: .touchDown)
        XCTAssertTrue(repeater.isRunning)
        source.releaseOnto(target)

        XCTAssertEqual(events, ["source.touchUpOutside", "target.touchUpInside"])
        XCTAssertFalse(repeater.isRunning)
        XCTAssertFalse(source.isHighlighted)
        XCTAssertFalse(target.isHighlighted)
    }
}
