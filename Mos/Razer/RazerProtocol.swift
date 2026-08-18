//
//  RazerProtocol.swift
//  Mos
//  Razer USB 协议: 90 字节 razer_report 构造 / CRC / 响应解析
//
//  报文格式 (与 openrazer/librazermacos 一致):
//  [0]=status [1]=transaction_id [2..3]=remaining_packets [4]=protocol_type
//  [5]=data_size [6]=command_class [7]=command_id [8..87]=arguments(80)
//  [88]=crc(XOR bytes 2..88) [89]=reserved
//  Created by Codex on 2026/8/18.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Foundation

/// 90 字节 razer_report
struct RazerReport {
    var bytes: [UInt8]

    init() {
        bytes = [UInt8](repeating: 0, count: 90)
    }

    var status: UInt8 {
        get { bytes[0] }
        set { bytes[0] = newValue }
    }
    var transactionID: UInt8 {
        get { bytes[1] }
        set { bytes[1] = newValue }
    }
    var protocolType: UInt8 {
        get { bytes[4] }
        set { bytes[4] = newValue }
    }
    var dataSize: UInt8 {
        get { bytes[5] }
        set { bytes[5] = newValue }
    }
    var commandClass: UInt8 {
        get { bytes[6] }
        set { bytes[6] = newValue }
    }
    var commandID: UInt8 {
        get { bytes[7] }
        set { bytes[7] = newValue }
    }
    /// 载荷 (80 字节)
    var arguments: [UInt8] {
        get { Array(bytes[8..<88]) }
        set {
            for index in 0..<80 {
                bytes[8 + index] = index < newValue.count ? newValue[index] : 0
            }
        }
    }
    var crc: UInt8 {
        get { bytes[88] }
        set { bytes[88] = newValue }
    }

    /// 构造命令报文并计算 CRC
    static func make(
        commandClass: UInt8,
        commandID: UInt8,
        dataSize: UInt8,
        transactionID: UInt8,
        args: [UInt8] = []
    ) -> RazerReport {
        var report = RazerReport()
        report.transactionID = transactionID
        report.protocolType = 0
        report.dataSize = dataSize
        report.commandClass = commandClass
        report.commandID = commandID
        var payload = args
        if payload.count < 80 {
            payload.append(contentsOf: repeatElement(0, count: 80 - payload.count))
        }
        report.arguments = Array(payload.prefix(80))
        report.crc = Self.checksum(of: report.bytes)
        return report
    }

    /// CRC: bytes[2...88] 逐字节 XOR
    static func checksum(of bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for index in 2...88 where index < bytes.count {
            crc ^= bytes[index]
        }
        return crc
    }
}

// MARK: - 命令构造 (DeathAdder V3 Pro 系列)

enum RazerCommand {
    /// 电量 (0-255, 返回 arguments[1])
    static func battery(transactionID: UInt8) -> RazerReport {
        .make(commandClass: 0x07, commandID: 0x80, dataSize: 0x02, transactionID: transactionID)
    }

    /// 充电状态 (返回 arguments[1], 1 = 充电中)
    static func charging(transactionID: UInt8) -> RazerReport {
        .make(commandClass: 0x07, commandID: 0x84, dataSize: 0x02, transactionID: transactionID)
    }

    /// 读取 DPI (返回 arguments[1..2] = dpi_x BE)
    static func getDPI(transactionID: UInt8) -> RazerReport {
        .make(commandClass: 0x04, commandID: 0x85, dataSize: 0x07, transactionID: transactionID, args: [0x00])
    }

    /// 设置 DPI (NOSTORE)
    static func setDPI(_ dpi: Int, transactionID: UInt8) -> RazerReport {
        let value = min(max(dpi, 100), 45000)
        let x = UInt16(value)
        return .make(
            commandClass: 0x04,
            commandID: 0x05,
            dataSize: 0x07,
            transactionID: transactionID,
            args: [0x00, UInt8((x >> 8) & 0xFF), UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8(x & 0xFF), 0x00, 0x00]
        )
    }

    /// 读取回报率 (返回 arguments[0]: 0x01=1000, 0x02=500, 0x08=125)
    static func getPollRate(transactionID: UInt8) -> RazerReport {
        .make(commandClass: 0x00, commandID: 0x85, dataSize: 0x01, transactionID: transactionID)
    }

    /// 设置回报率
    static func setPollRate(_ pollRate: Int, transactionID: UInt8) -> RazerReport {
        let encoded: UInt8
        switch pollRate {
        case 1000: encoded = 0x01
        case 500: encoded = 0x02
        case 125: encoded = 0x08
        default: encoded = 0x02
        }
        return .make(commandClass: 0x00, commandID: 0x05, dataSize: 0x01, transactionID: transactionID, args: [encoded])
    }
}

// MARK: - 响应解析

/// GET_REPORT 响应 (含报告 ID 前缀; 载荷偏移与请求报文一致: 8/9/10)
struct RazerResponse {
    let bytes: [UInt8]

    var arguments: [UInt8] {
        guard bytes.count > 8 else { return [] }
        return Array(bytes[8..<min(bytes.count, 88)])
    }

    /// 电量百分比 (0-100)
    var batteryPercent: Int? {
        guard arguments.count > 1 else { return nil }
        return Int(Double(arguments[1]) / 255.0 * 100.0)
    }

    /// 是否充电中
    var isCharging: Bool? {
        guard arguments.count > 1 else { return nil }
        return arguments[1] == 1
    }

    /// DPI (dpi_x, dpi_y)
    var dpi: (x: Int, y: Int)? {
        guard arguments.count > 2 else { return nil }
        let x = (Int(arguments[1]) << 8) | Int(arguments[2])
        let y = (Int(arguments[3]) << 8) | Int(arguments[4])
        return (x, y)
    }

    /// 回报率 (Hz)
    var pollRate: Int? {
        guard let first = arguments.first else { return nil }
        switch first {
        case 0x01: return 1000
        case 0x02: return 500
        case 0x08: return 125
        default: return nil
        }
    }
}
