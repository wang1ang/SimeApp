import XCTest

final class InputSettingsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "InputSettingsTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    // The keyboard must persist its choice without App Group write access.
    func testKeyboardSwitchOverridesOlderAppChoice() {
        let shared = makeDefaults(), local = makeDefaults()
        let store = SchemeStore(shared: shared, local: local)
        store.setScheme(.sogouShuangpin, by: .app, at: Date(timeIntervalSince1970: 100))
        store.setScheme(.fullPinyin, by: .keyboard, at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(shared.string(forKey: "inputScheme"), "sogouShuangpin")
        let relaunched = SchemeStore(shared: shared, local: local)
        XCTAssertEqual(relaunched.scheme, .fullPinyin)
        XCTAssertEqual(relaunched.lastShuangpinScheme, .sogouShuangpin)
    }

    func testLaterAppChoiceOverridesKeyboardSwitch() {
        let store = SchemeStore(shared: makeDefaults(), local: makeDefaults())
        store.setScheme(.fullPinyin, by: .keyboard, at: Date(timeIntervalSince1970: 100))
        store.setScheme(.xiaoheShuangpin, by: .app, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.scheme, .xiaoheShuangpin)
        XCTAssertEqual(store.lastShuangpinScheme, .xiaoheShuangpin)
    }

    func testLegacyUntimestampedSharedValueStillApplies() {
        let shared = makeDefaults()
        shared.set("sogouShuangpin", forKey: "inputScheme")
        let store = SchemeStore(shared: shared, local: makeDefaults())
        XCTAssertEqual(store.scheme, .sogouShuangpin)
        store.setScheme(.fullPinyin, by: .keyboard)
        XCTAssertEqual(store.scheme, .fullPinyin)
    }

    func testDefaults() {
        let store = SchemeStore(shared: makeDefaults(), local: makeDefaults())
        XCTAssertEqual(store.scheme, .fullPinyin)
        XCTAssertEqual(store.lastShuangpinScheme, .microsoftShuangpin)
    }
}
