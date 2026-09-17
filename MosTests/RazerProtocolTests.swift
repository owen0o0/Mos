import XCTest
@testable import Mos_Debug

final class RazerProtocolTests: XCTestCase {

    func testReportLayout_andCRC() {
        let report = RazerReport.make(
            commandClass: 0x04,
            commandID: 0x85,
            dataSize: 0x07,
            transactionID: 0x1F,
            args: [0x00]
        )
        XCTAssertEqual(report.bytes.count, 90)
        XCTAssertEqual(report.bytes[1], 0x1F)
        XCTAssertEqual(report.bytes[6], 0x04)
        XCTAssertEqual(report.bytes[7], 0x85)
        XCTAssertEqual(report.bytes[8], 0x00)
        // CRC = XOR bytes[2...87] (88 为 CRC 自身, 计算时为 0)
        var expected: UInt8 = 0
        for index in 2..<88 {
            expected ^= report.bytes[index]
        }
        XCTAssertEqual(report.bytes[88], expected)
        XCTAssertEqual(report.crc, expected)
    }

    func testSetDPIEncoding() {
        let report = RazerCommand.setDPI(3200, transactionID: 0x1F)
        XCTAssertEqual(report.commandClass, 0x04)
        XCTAssertEqual(report.commandID, 0x05)
        XCTAssertEqual(report.arguments.prefix(7), [0x00, 0x0C, 0x80, 0x0C, 0x80, 0x00, 0x00])
    }

    func testSetDPIClamped() {
        let report = RazerCommand.setDPI(100_000, transactionID: 0x1F)
        let x = (Int(report.arguments[1]) << 8) | Int(report.arguments[2])
        XCTAssertEqual(x, 45000)
    }

    func testSetPollRateEncoding() {
        XCTAssertEqual(RazerCommand.setPollRate(1000, transactionID: 0x1F).arguments[0], 0x01)
        XCTAssertEqual(RazerCommand.setPollRate(500, transactionID: 0x1F).arguments[0], 0x02)
        XCTAssertEqual(RazerCommand.setPollRate(125, transactionID: 0x1F).arguments[0], 0x08)
    }

    func testBatteryCommand() {
        let report = RazerCommand.battery(transactionID: 0x3F)
        XCTAssertEqual(report.commandClass, 0x07)
        XCTAssertEqual(report.commandID, 0x80)
        XCTAssertEqual(report.transactionID, 0x3F)
    }

    func testResponseParsing_battery() {
        // 实测响应: 02 3f 00 00 00 02 07 80 00 c5 ...
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = 0x02
        bytes[1] = 0x3F
        bytes[6] = 0x02
        bytes[7] = 0x07
        bytes[8] = 0x80
        bytes[8] = 0x00
        bytes[9] = 0xC5
        let response = RazerResponse(bytes: bytes)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.batteryPercent, Int(197.0 / 255.0 * 100.0))
    }

    func testResponseParsing_charging() {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = 0x02
        bytes[9] = 0x01
        XCTAssertEqual(RazerResponse(bytes: bytes).isCharging, true)
        bytes[9] = 0x00
        XCTAssertEqual(RazerResponse(bytes: bytes).isCharging, false)
    }

    func testResponseStatus_busyShouldRetryGetOnly() {
        XCTAssertTrue(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.busy))
        XCTAssertTrue(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.newCommand))
        XCTAssertTrue(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.timeout))
        XCTAssertFalse(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.successful))
        XCTAssertFalse(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.failure))
        XCTAssertFalse(RazerUSBRetry.shouldRetryGet(status: RazerReportStatus.notSupported))
        XCTAssertEqual(RazerUSBRetry.waitMicroseconds(attempt: 0), 12_000)
        XCTAssertGreaterThan(RazerUSBRetry.waitMicroseconds(attempt: 3), RazerUSBRetry.waitMicroseconds(attempt: 0))
    }

    func testHotPlug_firstMatchDoesNotDropExisting() {
        let change = RazerHotPlugReconcile.apply(current: [1, 2], event: .appeared([3]))
        XCTAssertEqual(change.add, [3])
        XCTAssertEqual(change.remove, [])
    }

    func testHotPlug_unrelatedAppearanceDoesNotRemoveMice() {
        let change = RazerHotPlugReconcile.apply(current: [10], event: .appeared([]))
        XCTAssertEqual(change.add, [])
        XCTAssertEqual(change.remove, [])
    }

    func testHotPlug_terminatedOnlyRemovesThoseIDs() {
        let change = RazerHotPlugReconcile.apply(current: [1, 2], event: .disappeared([1, 99]))
        XCTAssertEqual(change.add, [])
        XCTAssertEqual(change.remove, [1])
    }

    func testHotPlug_fullSnapshotAddsAndRemoves() {
        let change = RazerHotPlugReconcile.apply(current: [1, 2], event: .fullSnapshot([2, 3]))
        XCTAssertEqual(change.add, [3])
        XCTAssertEqual(change.remove, [1])
    }

    func testDeviceStateMerge_batteryOnlyPreservesDPIAndPollRate() {
        var state = RazerDeviceState(
            locationID: 1,
            productID: 0x00B7,
            name: "DeathAdder V3 Pro",
            supportsBattery: true,
            supportsDPI: true,
            supportsPollRate: true,
            batteryPercent: 80,
            isCharging: false,
            dpi: 3200,
            pollRate: 1000
        )
        state.apply(batteryPercent: 42)
        XCTAssertEqual(state.batteryPercent, 42)
        XCTAssertEqual(state.isCharging, false)
        XCTAssertEqual(state.dpi, 3200)
        XCTAssertEqual(state.pollRate, 1000)
    }

    func testResponseParsing_dpi() {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[9] = 0x0C
        bytes[10] = 0x80
        bytes[11] = 0x0C
        bytes[12] = 0x80
        let response = RazerResponse(bytes: bytes)
        XCTAssertEqual(response.dpi?.x, 3200)
        XCTAssertEqual(response.dpi?.y, 3200)
    }

    func testResponseParsing_pollRate() {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[8] = 0x02
        XCTAssertEqual(RazerResponse(bytes: bytes).pollRate, 500)
        bytes[8] = 0x01
        XCTAssertEqual(RazerResponse(bytes: bytes).pollRate, 1000)
        bytes[8] = 0x08
        XCTAssertEqual(RazerResponse(bytes: bytes).pollRate, 125)
    }

    // MARK: - 硬件验证 (无雷蛇鼠标时跳过)

    func testManagerEnumeratesRazerMouse_whenHardwarePresent() throws {
        let manager = RazerDeviceManager.shared
        manager.onDevicesChanged = nil
        manager.start()
        manager.refreshAll()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !manager.devices.isEmpty { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let snapshot = manager.devices
        manager.stop()

        guard let device = snapshot.first else {
            throw XCTSkip("未检测到支持的雷蛇鼠标, 跳过硬件验证")
        }
        // DeathAdder V3 Pro 系列 PID
        XCTAssertTrue([0x00B6, 0x00B7, 0x00C2, 0x00C3].contains(device.productID))
        XCTAssertNotNil(device.batteryPercent)
        XCTAssertNotNil(device.dpi)
        XCTAssertNotNil(device.pollRate)
    }

    // MARK: - 设备页 UI

    func testDevicesViewControllerLoadsFromStoryboard() throws {
        let storyboard = NSStoryboard(name: "Main", bundle: .main)
        let controller = storyboard.instantiateController(withIdentifier: "devices")
            as? PreferencesDevicesViewController
        XCTAssertNotNil(controller, "设备页应从 storyboard 正常加载")
        XCTAssertEqual(PreferencesDevicesViewController.preferredSize, NSSize(width: 450, height: 320))
        _ = controller?.view
        controller?.viewWillAppear()
        XCTAssertEqual(controller?.view.frame.size, NSSize(width: 450, height: 320))
        XCTAssertEqual(controller?.preferredContentSize, NSSize(width: 450, height: 320))
    }

    func testDeviceCardAppearance_usesCustomBoxMetricsInsteadOfLegacyBorderType() {
        let box = NSBox()
        DeviceCardAppearance.apply(to: box)

        XCTAssertEqual(box.boxType, .custom)
        XCTAssertEqual(box.cornerRadius, DeviceCardAppearance.cornerRadius)
        XCTAssertEqual(box.borderWidth, DeviceCardAppearance.borderWidth)
        XCTAssertFalse(box.isTransparent)
        XCTAssertEqual(box.borderColor, .separatorColor)
    }
}
