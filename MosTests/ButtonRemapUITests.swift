import XCTest
@testable import Mos_Debug

final class ButtonRemapUITests: XCTestCase {

    // MARK: - 显示解析

    func testDisplayResolver_unbound() {
        let presentation = ButtonEffectDisplayResolver.resolve(effect: nil, isEnabled: false, isRecording: false)
        XCTAssertEqual(presentation.kind, .unbound)
        XCTAssertEqual(presentation.title, NSLocalizedString("unbound", comment: ""))
    }

    func testDisplayResolver_disabledEffectShowsUnbound() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .smartZoom,
            isEnabled: false,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .unbound)
    }

    func testDisplayResolver_recordingPrompt() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: nil,
            isEnabled: false,
            isRecording: true
        )
        XCTAssertEqual(presentation.kind, .recordingPrompt)
    }

    func testDisplayResolver_systemShortcut() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .systemShortcut(identifier: "copy"),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertFalse(presentation.title.isEmpty)
    }

    func testDisplayResolver_smartZoom() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .smartZoom,
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertEqual(presentation.title, NSLocalizedString("button_effect_smart_zoom", comment: ""))
    }

    func testDisplayResolver_lookUp() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .lookUp,
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertEqual(presentation.title, NSLocalizedString("button_effect_look_up", comment: ""))
    }

    func testDisplayResolver_navigationSwipe() {
        let back = ButtonEffectDisplayResolver.resolve(
            effect: .navigationSwipe(direction: .left),
            isEnabled: true,
            isRecording: false
        )
        let forward = ButtonEffectDisplayResolver.resolve(
            effect: .navigationSwipe(direction: .right),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(back.title, NSLocalizedString("button_effect_navigation_back", comment: ""))
        XCTAssertEqual(forward.title, NSLocalizedString("button_effect_navigation_forward", comment: ""))
    }

    func testDisplayResolver_mediaEvent() {
        let event = MediaSystemEvent.playPause
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .systemDefinedEvent(type: event.type, flags: 0),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertEqual(presentation.title, NSLocalizedString(event.titleKey, comment: ""))
    }

    func testDisplayResolver_mouseButtonClicks() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .mouseButtonClicks(buttonNumber: 3, count: 2),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertTrue(presentation.title.contains("×2"))
    }

    func testDisplayResolver_customKeyRendersBadge() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .customKey(code: 56, modifiers: 0),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .keyCombo)
        XCTAssertFalse(presentation.badgeComponents.isEmpty)
    }

    func testDisplayResolver_mosScroll() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .mosScroll(role: .dash),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .namedAction)
    }

    func testDisplayResolver_openTargetStalePath() {
        let payload = OpenTargetPayload(
            path: "/nonexistent/SomeApp.app",
            bundleID: nil,
            arguments: "",
            kind: .application
        )
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: .openTarget(payload: payload),
            isEnabled: true,
            isRecording: false
        )
        XCTAssertEqual(presentation.kind, .openTarget)
        XCTAssertFalse(presentation.title.isEmpty)
    }

    // MARK: - 菜单结构

    private func makeStubMenu(triggerDuration: ButtonTriggerDuration = .click) -> NSMenu {
        let menu = NSMenu()
        ButtonEffectMenuBuilder.buildMenu(
            into: menu,
            target: NSObject(),
            action: #selector(NSObject.description),
            showLogiActions: true,
            triggerDuration: triggerDuration,
            delegate: nil
        )
        return menu
    }

    func testMenuBuilder_hasPlaceholderUnboundAndSections() {
        let menu = makeStubMenu()

        // 占位符 / 分割线 / 未绑定 / 分割线 / 手势 / 媒体 / 连击 / 分割线 / 系统分类…
        XCTAssertGreaterThanOrEqual(menu.items.count, 9)
        XCTAssertEqual(menu.items[0].title, "")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertNil(menu.items[2].representedObject)

        let gestureItem = menu.items[4]
        XCTAssertEqual(
            gestureItem.title,
            NSLocalizedString("button_effect_section_gestures", comment: "")
        )
        XCTAssertNotNil(gestureItem.submenu)
        XCTAssertEqual(gestureItem.submenu?.items.count, 4)

        let mediaItem = menu.items[5]
        XCTAssertEqual(
            mediaItem.title,
            NSLocalizedString("button_effect_section_media", comment: "")
        )
        XCTAssertEqual(mediaItem.submenu?.items.count, MediaSystemEvent.allCases.count)

        let comboItem = menu.items[6]
        XCTAssertEqual(
            comboItem.title,
            NSLocalizedString("button_effect_section_click_combo", comment: "")
        )
        XCTAssertEqual(comboItem.submenu?.items.count, 10)
    }

    func testMenuBuilder_gestureItemsCarryEffects() {
        let menu = makeStubMenu()
        let gestureSubmenu = menu.items[4].submenu

        let effects = gestureSubmenu?.items.compactMap { $0.representedObject as? ButtonEffect }
        XCTAssertEqual(effects, [
            .smartZoom,
            .lookUp,
            .navigationSwipe(direction: .left),
            .navigationSwipe(direction: .right),
        ])
    }

    func testMenuBuilder_mediaItemsCarrySystemDefinedEvents() {
        let menu = makeStubMenu()
        let mediaSubmenu = menu.items[5].submenu
        let effects = mediaSubmenu?.items.compactMap { $0.representedObject as? ButtonEffect }
        XCTAssertEqual(effects?.count, MediaSystemEvent.allCases.count)
        for effect in effects ?? [] {
            guard case .systemDefinedEvent = effect else {
                XCTFail("Expected systemDefinedEvent effect, got \(effect)")
                return
            }
        }
    }

    func testMenuBuilder_dragItemsCarryDragEffects() {
        let menu = makeStubMenu(triggerDuration: .drag)
        // 占位符/分割线/未绑定/分割线/双指滑动/三指滑动 (一级)
        XCTAssertEqual(menu.items.count, 6)
        let effects = menu.items[4...5].compactMap { $0.representedObject as? ButtonEffect }
        XCTAssertEqual(effects, [
            .drag(mode: .twoFingerSwipe),
            .drag(mode: .threeFingerSwipe),
        ])
    }

    func testMenuBuilder_scrollModificationItemsCarryKinds() {
        let menu = makeStubMenu(triggerDuration: .scroll)
        XCTAssertEqual(menu.items.count, 6)
        let effects = menu.items[4...5].compactMap { $0.representedObject as? ButtonEffect }
        XCTAssertEqual(effects, [
            .scrollModification(kind: .zoom),
            .scrollModification(kind: .fourFingerPinch),
        ])
    }

    func testMenuBuilder_comboItemsCarryMouseButtonClicks() {
        let menu = makeStubMenu()
        let comboSubmenu = menu.items[6].submenu
        let effects = comboSubmenu?.items.compactMap { $0.representedObject as? ButtonEffect }
        guard let effects else {
            XCTFail("No combo items")
            return
        }
        for effect in effects {
            guard case .mouseButtonClicks(let button, let count) = effect else {
                XCTFail("Expected mouseButtonClicks, got \(effect)")
                return
            }
            XCTAssertTrue([2, 3].contains(count))
            XCTAssertTrue([0, 1, 2, 3, 4].contains(Int(button)))
        }
    }

    func testMenuBuilder_clickMenuExcludesDragAndScrollSections() {
        let menu = makeStubMenu(triggerDuration: .click)
        let titles = menu.items.map { $0.title }
        XCTAssertFalse(titles.contains(NSLocalizedString("button_effect_drag_two_finger", comment: "")))
        XCTAssertFalse(titles.contains(NSLocalizedString("button_effect_scroll_zoom", comment: "")))
    }

    func testMenuBuilder_dragAndScrollMenusExcludeOtherSections() {
        let dragMenu = makeStubMenu(triggerDuration: .drag)
        XCTAssertEqual(
            dragMenu.items[4].title,
            NSLocalizedString("button_effect_drag_two_finger", comment: "")
        )
        XCTAssertNil(dragMenu.items[4].submenu)

        let scrollMenu = makeStubMenu(triggerDuration: .scroll)
        XCTAssertEqual(
            scrollMenu.items[4].title,
            NSLocalizedString("button_effect_scroll_zoom", comment: "")
        )
        XCTAssertNil(scrollMenu.items[4].submenu)
    }

}
