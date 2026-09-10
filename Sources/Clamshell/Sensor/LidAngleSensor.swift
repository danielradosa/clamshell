import Foundation
import IOKit
import IOKit.hid

final class LidAngleSensor {
    private static let sensorUsagePage = 0x20
    private static let lidAngleUsage = 0x8A

    private enum AngleReport {
        case precise
        case coarse

        var id: CFIndex { self == .precise ? 7 : 1 }
        var minimumLength: Int { 3 }

        func degrees(from buffer: [UInt8]) -> Double {
            let raw = UInt16(buffer[1]) | (UInt16(buffer[2]) << 8)
            switch self {
            case .precise: return Double(raw) / 100.0
            case .coarse:  return Double(raw & 0x1FF)
            }
        }
    }

    private static let bufferSize = 8

    private var device: IOHIDDevice?
    private var report: AngleReport = .precise

    var isAvailable: Bool { device != nil }

    var resolution: Double { report == .precise ? 0.01 : 1.0 }

    init() {
        if let (device, report) = Self.openSensorDevice() {
            self.device = device
            self.report = report
        }
    }

    deinit {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private static func openSensorDevice() -> (IOHIDDevice, AngleReport)? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: sensorUsagePage,
            kIOHIDPrimaryUsageKey as String: lidAngleUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }

        for report in [AngleReport.precise, .coarse] where readAngle(from: device, using: report) != nil {
            return (device, report)
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        return nil
    }

    private static func readAngle(from device: IOHIDDevice, using report: AngleReport) -> Double? {
        var length = bufferSize
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, report.id, &buffer, &length
        )
        guard result == kIOReturnSuccess, length >= report.minimumLength else { return nil }

        let degrees = report.degrees(from: buffer)
        guard degrees >= 0, degrees <= 180 else { return nil }
        return degrees
    }

    func currentAngle() -> Double? {
        guard let device else { return nil }
        return Self.readAngle(from: device, using: report)
    }
}
