import Foundation
import IOKit
import IOKit.hid

/// Reads the MacBook's built-in lid angle sensor over IOKit HID.
///
/// The sensor is an undocumented HID device Apple exposes on the Sensor usage
/// page (0x20) with usage 0x8A, named `las`. It answers feature report 1 with
/// three bytes: `[reportID, angleLow, angleHigh]`, where the trailing two bytes
/// are a little-endian `UInt16` holding the hinge angle in whole degrees.
///
/// Reading needs no entitlement, no root and triggers no TCC prompt — opening
/// the individual device succeeds even though opening the whole HID manager
/// does not. Reads are cheap enough to poll at display rate; measured
/// throughput on an M2 is roughly 1,900 reads per second.
///
/// Because Apple does not document any of this, treat a missing device or a
/// failed read as "this Mac has no lid sensor" rather than as an error.
final class LidAngleSensor {

    /// HID Sensor usage page.
    private static let sensorUsagePage = 0x20
    /// Undocumented usage Apple assigns to the lid angle sensor.
    private static let lidAngleUsage = 0x8A
    /// The only feature report that carries the angle.
    private static let angleReportID: CFIndex = 1
    private static let angleReportLength = 3

    private var device: IOHIDDevice?

    /// True when a real sensor was found and opened.
    var isAvailable: Bool { device != nil }

    init() {
        device = Self.openSensorDevice()
    }

    deinit {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private static func openSensorDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: sensorUsagePage,
            kIOHIDPrimaryUsageKey as String: lidAngleUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        // Deliberately no IOHIDManagerOpen: it returns kIOReturnNotPermitted for
        // an unprivileged process, while opening the matched device still works.
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }

        // Only trust the device if it actually answers the angle report.
        guard readAngle(from: device) != nil else {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        return device
    }

    private static func readAngle(from device: IOHIDDevice) -> Double? {
        var length = angleReportLength
        var buffer = [UInt8](repeating: 0, count: angleReportLength)
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, angleReportID, &buffer, &length
        )
        guard result == kIOReturnSuccess, length >= angleReportLength else { return nil }

        let degrees = Double(UInt16(buffer[1]) | (UInt16(buffer[2]) << 8))
        // A fully-open MacBook tops out near 130 degrees; anything past 180 is a
        // garbage read from a device that matched but is not really a lid sensor.
        guard degrees <= 180 else { return nil }
        return degrees
    }

    /// Current hinge angle in degrees, or `nil` if unavailable this instant.
    func currentAngle() -> Double? {
        guard let device else { return nil }
        return Self.readAngle(from: device)
    }
}
