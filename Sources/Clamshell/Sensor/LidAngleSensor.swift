import Foundation
import IOKit
import IOKit.hid

/// Reads the MacBook's built-in lid angle sensor over IOKit HID.
///
/// The sensor is an undocumented HID device Apple exposes on the Sensor usage
/// page (0x20) with usage 0x8A, named `las`. It answers two reports that both
/// carry the hinge angle:
///
///   - **Report 7** returns the angle in hundredths of a degree, as a
///     little-endian `UInt16` at bytes 1...2. Measured live: 112.59 to 112.72
///     while report 1 sat flat at 113.
///   - **Report 1** returns whole degrees in the same layout. The field is
///     really 9 bits wide, so the value is masked; the upper bits are padding
///     the descriptor never declares.
///
/// Report 7 is preferred because the entire visual is driven by this number and
/// whole-degree steps are visible in the fold. Report 1 is the fallback for any
/// Mac whose sensor hub does not answer 7.
///
/// Reading needs no entitlement, no root and triggers no TCC prompt — opening
/// the individual device succeeds even though opening the whole HID manager
/// does not. A read costs about half a millisecond, so polling at display rate
/// is comfortable.
///
/// Because Apple does not document any of this, treat a missing device or a
/// failed read as "this Mac has no lid sensor" rather than as an error.
final class LidAngleSensor {

    /// HID Sensor usage page.
    private static let sensorUsagePage = 0x20
    /// Undocumented usage Apple assigns to the lid angle sensor.
    private static let lidAngleUsage = 0x8A

    /// Which report the device is answering, and therefore how to scale it.
    private enum AngleReport {
        /// Hundredths of a degree.
        case precise
        /// Whole degrees, 9-bit field.
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

    /// The device declares a maximum input report of 8 bytes. Reading into a
    /// buffer sized to the reply we expect would be a hazard if a different
    /// sensor hub ever answered with more, so allocate the declared maximum.
    private static let bufferSize = 8

    private var device: IOHIDDevice?
    private var report: AngleReport = .precise

    /// True when a real sensor was found and opened.
    var isAvailable: Bool { device != nil }

    /// Resolution of the readings actually being taken, in degrees.
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

        // Deliberately no IOHIDManagerOpen: it returns kIOReturnNotPermitted for
        // an unprivileged process, while opening the matched device still works.
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }

        // Several sensors on this hub share a vendor and product ID, so matching
        // alone proves nothing. Trust the device only once it answers with a
        // plausible angle, and let that probe pick the best report available.
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
        // A fully-open MacBook tops out near 130 degrees; anything past 180 is a
        // garbage read from a device that matched but is not really a lid sensor.
        guard degrees >= 0, degrees <= 180 else { return nil }
        return degrees
    }

    /// Current hinge angle in degrees, or `nil` if unavailable this instant.
    func currentAngle() -> Double? {
        guard let device else { return nil }
        return Self.readAngle(from: device, using: report)
    }
}
