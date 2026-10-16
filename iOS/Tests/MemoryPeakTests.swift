import XCTest
import Darwin
@testable import Sime

/// Peak footprint growth of keyboard operations, each on a fresh engine. The
/// extension is killed at 77 MB on device and already sits near 50 MB, so a
/// transient spike crashes it even if freed right after. Simulator numbers
/// catch spikes, not the exact device ceiling.
final class MemoryPeakTests: XCTestCase {
    // Measured operations stay under 1 MB; building the Cutter adds 20+ MB.
    private let budgetMB = 8.0
    private let bundle = Bundle(for: MemoryPeakTests.self)
    private let shuangpin = InputScheme.microsoftShuangpin

    private func fullPinyin() throws -> Composition {
        guard let decoder = NativePinyinDecoder(bundle: bundle) else { throw XCTSkip() }
        return Composition(decoder: decoder, inputScheme: .fullPinyin)
    }

    private func microsoftShuangpin() throws -> Composition {
        guard let decoder = NativePinyinDecoder(bundle: bundle,
                                                indexName: shuangpin.shuangpinIndexName) else {
            throw XCTSkip()
        }
        return Composition(decoder: decoder, inputScheme: shuangpin)
    }

    private func type(_ keys: String, into composition: Composition) {
        keys.forEach { composition.append(String($0)) }
    }

    private func assertPeak(_ label: String, file: StaticString = #filePath, line: UInt = #line,
                            _ body: () throws -> Void) rethrows {
        let growth = try PeakFootprint.growthMB(of: body)
        XCTAssertLessThan(growth, budgetMB,
                          String(format: "%@ grew the footprint by %.1f MB at peak", label, growth),
                          file: file, line: line)
    }

    func testFirstDecode() throws {
        try assertPeak("full pinyin first decode") {
            type("womendezhongguo", into: try fullPinyin())
        }
        try assertPeak("shuangpin first decode") {
            type("womfdevsgo", into: try microsoftShuangpin())
        }
    }

    func testLongInput() throws {
        try assertPeak("long input") {
            type("jintiantianqihenhaowomenyiqiquchifanbaranhouzaiqukandianying",
                 into: try fullPinyin())
        }
    }

    func testCorrectionBubble() throws {
        try assertPeak("correction bubble") {
            let c = try microsoftShuangpin()
            type("x;jwbi", into: c)
            c.activateCharacter(1)
            _ = c.displayCandidates
        }
    }

    func testCommitAndAssociation() throws {
        try assertPeak("commit and association") {
            let c = try fullPinyin()
            c.predictionEnabled = true
            type("womendezhongguo", into: c)
            _ = c.commitBestOrRaw()
            _ = c.displayCandidates
        }
    }

    func testInsertedSymbolContext() throws {
        try assertPeak("inserted symbol context") {
            let c = try fullPinyin()
            type("nihao", into: c)
            _ = c.commitBestOrRaw()
            c.appendInsertedContext("，")
        }
    }

    func testHostContextUpdate() throws {
        try assertPeak("host context update") {
            try fullPinyin().updateHostContext(from: "今天天气很好")
        }
    }

    func testIdleBackspaceInsideAToken() throws {
        try assertPeak("idle backspace") {
            let c = try fullPinyin()
            type("boboji", into: c)
            _ = c.commitBestOrRaw()
            c.deleteContextBackward()
        }
    }
}

/// Samples phys_footprint (what Jetsam counts) on a background thread.
enum PeakFootprint {
    static func currentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func growthMB(of body: () throws -> Void) rethrows -> Double {
        // Return pages freed by earlier tests so malloc reuse can't hide growth.
        malloc_zone_pressure_relief(nil, 0)
        let baseline = currentMB()
        let lock = NSLock()
        var peak = baseline
        var running = true
        let sampler = Thread {
            while true {
                lock.lock()
                let keepGoing = running
                lock.unlock()
                guard keepGoing else { break }
                let now = currentMB()
                lock.lock()
                peak = max(peak, now)
                lock.unlock()
                usleep(200)
            }
        }
        sampler.start()
        defer {
            lock.lock()
            running = false
            lock.unlock()
        }
        try body()
        lock.lock()
        let observed = max(peak, currentMB())
        lock.unlock()
        return observed - baseline
    }
}
