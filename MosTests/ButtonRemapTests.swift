import XCTest
@testable import Mos_Debug

final class ButtonRemapTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        Options.shared.buttons.remaps = []
        ButtonUtils.shared.invalidateCache()
    }

    override func tearDown() {
        Options.shared.buttons.remaps = []
        ButtonUtils.shared.invalidateCache()
        super.tearDown()
    }

    private func makeRemap(
        button: UInt16 = 3,
        level: Int = 1,
        duration: ButtonTriggerDuration = .click,
        effect: ButtonEffect,
        modifiers: UInt = 0
    ) -> ButtonRemap {
        return ButtonRemap(
            trigger: ButtonTrigger(buttonNumber: button, level: level, duration: duration),
            precondition: ButtonPrecondition(keyboardModifiers: modifiers),
            effect: effect
        )
    }

    // MARK: - Codable roundtrip

    func testCodableRoundtrip_allEffectCases() throws {
        let effects: [ButtonEffect] = [
            .systemShortcut(identifier: "copy"),
            .customKey(code: 56, modifiers: 0x100000),
            .customMouseButton(buttonNumber: 3, modifiers: 0x200000),
            .mouseButtonClicks(buttonNumber: 5, count: 3),
            .mosScroll(role: .dash),
            .systemDefinedEvent(type: 19, flags: 0),
            .smartZoom,
            .lookUp,
            .navigationSwipe(direction: .right),
            .openTarget(payload: OpenTargetPayload(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", arguments: "", kind: .application)),
            .logiAction(identifier: "logiSmartShiftToggle"),
            .drag(mode: .threeFingerSwipe),
            .scrollModification(kind: .zoom),
            .scrollModification(kind: .fourFingerPinch)
        ]

        for effect in effects {
            let remap = makeRemap(effect: effect)
            let data = try encoder.encode(remap)
            let decoded = try decoder.decode(ButtonRemap.self, from: data)
            XCTAssertEqual(decoded, remap, "Roundtrip failed for \(effect)")
        }
    }

    func testCodable_legacyScrollRoleCompatibility() throws {
        for role in ScrollRole.allCases {
            let remap = makeRemap(effect: .mosScroll(role: role))
            let data = try encoder.encode(remap)
            let decoded = try decoder.decode(ButtonRemap.self, from: data)
            XCTAssertEqual(decoded, remap)
        }
    }

    func testCodable_triggerDurationsDragAndScroll() throws {
        for duration in [ButtonTriggerDuration.drag, .scroll] {
            let remap = ButtonRemap(
                trigger: ButtonTrigger(buttonNumber: 3, level: 1, duration: duration),
                effect: .drag(mode: .twoFingerSwipe)
            )
            let data = try encoder.encode(remap)
            let decoded = try decoder.decode(ButtonRemap.self, from: data)
            XCTAssertEqual(decoded, remap)
            XCTAssertEqual(decoded.trigger.duration, duration)
        }
    }

    // MARK: - Precondition matching

    func testMatchPriority_requiresAllConfiguredModifiers() {
        let precondition = ButtonPrecondition(keyboardModifiers: UInt(CGEventFlags.maskCommand.rawValue))

        XCTAssertNil(precondition.matchPriority(for: CGEventFlags(rawValue: 0)))
        XCTAssertNotNil(precondition.matchPriority(for: CGEventFlags.maskCommand))
    }

    func testMatchPriority_allowsExtraModifiersWithPriority() {
        let command = ButtonPrecondition(keyboardModifiers: UInt(CGEventFlags.maskCommand.rawValue))
        let commandShift = ButtonPrecondition(keyboardModifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue))

        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        let commandPriority = command.matchPriority(for: eventFlags)
        let commandShiftPriority = commandShift.matchPriority(for: eventFlags)

        XCTAssertNotNil(commandPriority)
        XCTAssertNotNil(commandShiftPriority)
        XCTAssertGreaterThan(commandShiftPriority!, commandPriority!)
    }

    // MARK: - ButtonUtils remap 查询

    func testButtonUtils_maxLevel_andBestMatch() {
        let commandMask = UInt(CGEventFlags.maskCommand.rawValue)
        let click = makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "copy"))
        let doubleClick = makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "paste"))
        let commandClick = makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "selectAll"), modifiers: commandMask)
        let hold = makeRemap(button: 3, level: 1, duration: .hold, effect: .systemShortcut(identifier: "bold"))
        Options.shared.buttons.remaps = [click, doubleClick, commandClick, hold]
        ButtonUtils.shared.invalidateCache()

        XCTAssertTrue(ButtonUtils.shared.hasButtonRemaps)

        // 无修饰键: 单击/双击 匹配
        let plain = CGEventFlags(rawValue: 0)
        XCTAssertEqual(ButtonUtils.shared.maxLevel(for: 3, modifiers: plain), 2)
        XCTAssertEqual(
            ButtonUtils.shared.remap(for: 3, level: 1, duration: .click, modifiers: plain)?.effect,
            .systemShortcut(identifier: "copy")
        )
        XCTAssertEqual(
            ButtonUtils.shared.remap(for: 3, level: 2, duration: .click, modifiers: plain)?.effect,
            .systemShortcut(identifier: "paste")
        )
        XCTAssertEqual(
            ButtonUtils.shared.remap(for: 3, level: 1, duration: .hold, modifiers: plain)?.effect,
            .systemShortcut(identifier: "bold")
        )

        // ⌘ 修饰: 无前置条件的基础绑定仍可匹配 (Mos 鼠标语义允许额外修饰键),
        // 因此 maxLevel 仍为 2; 但 level-1 最佳匹配优先选 ⌘ 专用绑定
        let command = CGEventFlags.maskCommand
        XCTAssertEqual(ButtonUtils.shared.maxLevel(for: 3, modifiers: command), 2)
        XCTAssertEqual(
            ButtonUtils.shared.remap(for: 3, level: 1, duration: .click, modifiers: command)?.effect,
            .systemShortcut(identifier: "selectAll")
        )

        // 未配置按钮 → 无匹配
        XCTAssertEqual(ButtonUtils.shared.maxLevel(for: 4, modifiers: plain), 0)
        XCTAssertNil(ButtonUtils.shared.remap(for: 4, level: 1, duration: .click, modifiers: plain))
    }

    func testButtonUtils_hasButtonRemaps_falseWhenEmpty() {
        XCTAssertFalse(ButtonUtils.shared.hasButtonRemaps)
    }

    // MARK: - OPTIONS_BUTTONS_DEFAULT 兼容

    func testOptionsButtonsDefault_decodesLegacyJSONWithoutRemaps() throws {
        // 旧版 per-app 数据只有 binding 字段; 新字段缺失时必须回退空数组而非抛错
        let legacyJSON = """
        {"binding":[]}
        """.data(using: .utf8)!

        let decoded = try decoder.decode(OPTIONS_BUTTONS_DEFAULT.self, from: legacyJSON)
        XCTAssertEqual(decoded.remaps, [])
        XCTAssertEqual(decoded.binding, [])
    }

    func testOptionsButtonsDefault_roundtripsBothFields() throws {
        let container = OPTIONS_BUTTONS_DEFAULT()
        container.remaps = [
            makeRemap(effect: .smartZoom),
            makeRemap(button: 4, duration: .hold, effect: .navigationSwipe(direction: .left))
        ]

        let data = try encoder.encode(container)
        let decoded = try decoder.decode(OPTIONS_BUTTONS_DEFAULT.self, from: data)
        XCTAssertEqual(decoded.remaps, container.remaps)
    }
}
