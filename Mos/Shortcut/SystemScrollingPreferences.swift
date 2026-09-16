//
//  SystemScrollingPreferences.swift
//  Mos
//  读取系统"自然滚动"偏好
//  Created by Claude on 2026/9/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Foundation

enum SystemScrollingPreferences {
    static let preferenceKey = "com.apple.swipescrolldirection"

    /// 测试可替换. 生产路径每次从全局域现读, 避免 UserDefaults 缓存导致开关后方向不变.
    static var naturalScrollingReader: () -> Bool = readFromSystem

    static var isNaturalScrollingEnabled: Bool {
        return naturalScrollingReader()
    }

    static func resetReaderForTesting() {
        naturalScrollingReader = readFromSystem
    }

    /// `com.apple.swipescrolldirection` 可能是 Bool 或 0/1 NSNumber.
    /// `as? Bool` 对整数 NSNumber 会失败并被误当成"未设置 → 自然滚动".
    static func boolValue(from value: Any?) -> Bool {
        guard let value = value else { return true }
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return true
    }

    private static func readFromSystem() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue(
            preferenceKey as CFString,
            kCFPreferencesAnyApplication
        )
        return boolValue(from: value)
    }
}
