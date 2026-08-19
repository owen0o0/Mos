//
//  RazerUSBTransport.swift
//  Mos
//  Razer USB 设备句柄: 枚举 / 打开 / 控制传输 (IOUSBDeviceInterface 原始 vtable)
//
//  IOUSBDeviceInterface 在 Swift 中的导入成员调用在部分系统上会崩溃,
// 因此这里按 vtable 函数指针偏移直接调用 (与 librazermacos 相同布局):
//  Release=24 USBDeviceOpen=64 USBDeviceClose=72 DeviceRequest=208
//  Created by Codex on 2026/8/18.
//  Copyright © 2026 Caldis. All rights reserved.
//

import IOKit
import IOKit.usb
import CoreFoundation
import Foundation

/// Razer USB 设备句柄 (IOUSBDeviceInterface 封装, 线程安全由调用方保证)
final class RazerUSBDevice {

    // MARK: - UUID 常量 (对应头文件宏, Swift 不可直接引用)

    private static let ioCFPlugInInterfaceID: CFUUID = {
        CFUUIDCreateFromUUIDBytes(nil, CFUUIDBytes(
            byte0: 0xC2, byte1: 0x44, byte2: 0xE8, byte3: 0x58,
            byte4: 0x10, byte5: 0x9C, byte6: 0x11, byte7: 0xD4,
            byte8: 0x91, byte9: 0xD4, byte10: 0x00, byte11: 0x50,
            byte12: 0xE4, byte13: 0xC6, byte14: 0x42, byte15: 0x6F
        ))
    }()

    private static let deviceUserClientTypeID: CFUUID = {
        CFUUIDCreateFromUUIDBytes(nil, CFUUIDBytes(
            byte0: 0x9d, byte1: 0xc7, byte2: 0xb7, byte3: 0x80,
            byte4: 0x9e, byte5: 0xc0, byte6: 0x11, byte7: 0xd4,
            byte8: 0xa5, byte9: 0x4f, byte10: 0x00, byte11: 0x0a,
            byte12: 0x27, byte13: 0x05, byte14: 0x28, byte15: 0x61
        ))
    }()

    private static let deviceInterfaceID: CFUUID = {
        CFUUIDCreateFromUUIDBytes(nil, CFUUIDBytes(
            byte0: 0x5c, byte1: 0x81, byte2: 0x87, byte3: 0xd0,
            byte4: 0x9e, byte5: 0xf3, byte6: 0x11, byte7: 0xd4,
            byte8: 0x8b, byte9: 0x45, byte10: 0x00, byte11: 0x0a,
            byte12: 0x27, byte13: 0x05, byte14: 0x28, byte15: 0x61
        ))
    }()

    // MARK: - vtable 函数指针类型

    private typealias FnSelf = @convention(c) (UnsafeMutableRawPointer?) -> IOReturn
    private typealias FnSelfU16 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt16>?) -> IOReturn
    private typealias FnDeviceRequest = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<IOUSBDevRequest>?) -> IOReturn

    // MARK: - 状态

    let productID: UInt16
    let productName: String
    let locationID: UInt32

    /// vtable self 指针 (IOUSBDeviceInterface**)
    private let selfPtr: UnsafeMutableRawPointer
    /// 接口结构体指针 (*selfPtr)
    private let interfacePtr: UnsafeMutablePointer<IOUSBDeviceInterface>
    private var isOpen = false
    /// 最近一次控制传输结果 (供管理器判断句柄是否失效)
    private(set) var lastControlError: IOReturn = kIOReturnSuccess

    /// 控制传输失败且句柄大概率失效 (设备断开 / 休眠 / 被占用)
    var isStale: Bool {
        switch lastControlError {
        case kIOReturnNotOpen, kIOReturnNoDevice, kIOReturnAborted,
             kIOReturnIOError, kIOReturnNotResponding, kIOReturnExclusiveAccess:
            return true
        default:
            return false
        }
    }

    // MARK: - 构造

    /// 从 IOUSBDevice service 建立句柄 (需要匹配的 Razer 设备)
    init?(locationID: UInt32, service: io_service_t) {
        let name: String
        if let productName = IORegistryEntryCreateCFProperty(
            service,
            "USB Product Name" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            name = productName
        } else if let productName = IORegistryEntryCreateCFProperty(
            service,
            "USB Product String" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            name = productName
        } else {
            name = "Razer Mouse"
        }

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let pluginResult = IOCreatePlugInInterfaceForService(
            service,
            Self.deviceUserClientTypeID,
            Self.ioCFPlugInInterfaceID,
            &plugin,
            &score
        )
        guard pluginResult == KERN_SUCCESS, let plugin, let plug = plugin.pointee else {
            return nil
        }

        var interfaceRaw: UnsafeMutableRawPointer?
        let hr = plug.pointee.QueryInterface(
            plugin,
            CFUUIDGetUUIDBytes(Self.deviceInterfaceID),
            &interfaceRaw
        )
        _ = plug.pointee.Release(plugin)
        guard hr == 0, let interfaceRaw else { return nil }

        // interfaceRaw 指向接口指针槽 (IOUSBDeviceInterface**); 结构体在 *interfaceRaw
        guard let interface = interfaceRaw
            .assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
            .pointee else {
            return nil
        }

        selfPtr = interfaceRaw
        interfacePtr = interface
        productID = Self.readUInt16(interface, selfPtr: interfaceRaw, offset: 112) ?? 0
        productName = name
        self.locationID = locationID
    }

    deinit {
        if isOpen {
            _ = Self.callSelf(interfacePtr, selfPtr: selfPtr, offset: 72) // USBDeviceClose
        }
        _ = Self.callSelf(interfacePtr, selfPtr: selfPtr, offset: 24) // Release
    }

    // MARK: - 打开 / 关闭

    func open() -> Bool {
        guard !isOpen else { return true }
        let result = Self.callSelf(interfacePtr, selfPtr: selfPtr, offset: 64) // USBDeviceOpen
        isOpen = result == kIOReturnSuccess
        return isOpen
    }

    func close() {
        guard isOpen else { return }
        _ = Self.callSelf(interfacePtr, selfPtr: selfPtr, offset: 72) // USBDeviceClose
        isOpen = false
    }

    // MARK: - 控制传输

    /// SET_REPORT (写 90 字节 razer_report)
    func sendReport(_ report: RazerReport, index: UInt16 = 0) -> IOReturn {
        var request = IOUSBDevRequest()
        request.bRequest = 0x09 // HID_REQ_SET_REPORT
        request.bmRequestType = 0x21 // USB_TYPE_CLASS | USB_RECIP_INTERFACE | DIR_OUT
        request.wValue = 0x300
        request.wIndex = index
        request.wLength = 90
        var bytes = report.bytes
        let result = bytes.withUnsafeMutableBytes { rawBuffer in
            request.pData = rawBuffer.baseAddress
            return deviceRequest(&request)
        }
        return result
    }

    /// 发送请求并读取响应 (GET_REPORT)
    func getResponse(for request: RazerReport, index: UInt16 = 0, waitMicroseconds: useconds_t = 31_000) -> RazerResponse? {
        let sendResult = sendReport(request, index: index)
        guard sendResult == kIOReturnSuccess else { return nil }
        usleep(waitMicroseconds)

        var getRequest = IOUSBDevRequest()
        getRequest.bRequest = 0x01 // HID_REQ_GET_REPORT
        getRequest.bmRequestType = 0xA1 // USB_TYPE_CLASS | USB_RECIP_INTERFACE | DIR_IN
        getRequest.wValue = 0x300
        getRequest.wIndex = index
        getRequest.wLength = 90
        var buffer = [UInt8](repeating: 0, count: 90)
        let result = buffer.withUnsafeMutableBytes { rawBuffer in
            getRequest.pData = rawBuffer.baseAddress
            return deviceRequest(&getRequest)
        }
        guard result == kIOReturnSuccess else { return nil }
        return RazerResponse(bytes: buffer)
    }

    private func deviceRequest(_ request: inout IOUSBDevRequest) -> IOReturn {
        guard let slot = Self.vtableFunction(interfacePtr, offset: 208) else {
            lastControlError = kIOReturnError
            return kIOReturnError
        }
        let result = unsafeBitCast(slot, to: FnDeviceRequest.self)(selfPtr, &request)
        lastControlError = result
        return result
    }

    // MARK: - vtable 工具

    private static func vtableFunction(
        _ interface: UnsafeMutablePointer<IOUSBDeviceInterface>,
        offset: Int
    ) -> UnsafeRawPointer? {
        return UnsafeMutableRawPointer(interface)
            .advanced(by: offset)
            .assumingMemoryBound(to: UnsafeRawPointer?.self)
            .pointee
    }

    private static func callSelf(
        _ interface: UnsafeMutablePointer<IOUSBDeviceInterface>,
        selfPtr: UnsafeMutableRawPointer,
        offset: Int
    ) -> IOReturn {
        guard let slot = vtableFunction(interface, offset: offset) else {
            return kIOReturnError
        }
        return unsafeBitCast(slot, to: FnSelf.self)(selfPtr)
    }

    private static func readUInt16(
        _ interface: UnsafeMutablePointer<IOUSBDeviceInterface>,
        selfPtr: UnsafeMutableRawPointer,
        offset: Int
    ) -> UInt16? {
        guard let slot = vtableFunction(interface, offset: offset) else { return nil }
        var value: UInt16 = 0
        _ = unsafeBitCast(slot, to: FnSelfU16.self)(selfPtr, &value)
        return value
    }
}
