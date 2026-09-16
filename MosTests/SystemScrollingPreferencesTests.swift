import XCTest
@testable import Mos_Debug

final class SystemScrollingPreferencesTests: XCTestCase {

    override func tearDown() {
        SystemScrollingPreferences.resetReaderForTesting()
        super.tearDown()
    }

    func testBoolValue_missingDefaultsToNatural() {
        XCTAssertTrue(SystemScrollingPreferences.boolValue(from: nil))
    }

    func testBoolValue_readsBool() {
        XCTAssertTrue(SystemScrollingPreferences.boolValue(from: true))
        XCTAssertFalse(SystemScrollingPreferences.boolValue(from: false))
    }

    func testBoolValue_readsIntegerNSNumber() {
        XCTAssertTrue(SystemScrollingPreferences.boolValue(from: NSNumber(value: 1)))
        XCTAssertFalse(SystemScrollingPreferences.boolValue(from: NSNumber(value: 0)))
    }

    func testReaderOverride_isUsedByEnabledFlag() {
        SystemScrollingPreferences.naturalScrollingReader = { false }
        XCTAssertFalse(SystemScrollingPreferences.isNaturalScrollingEnabled)
        SystemScrollingPreferences.naturalScrollingReader = { true }
        XCTAssertTrue(SystemScrollingPreferences.isNaturalScrollingEnabled)
    }
}
