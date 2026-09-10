import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

enum Diagnostics {
    static let reportURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Clamshell-diagnostics.txt")

    static func run() async {
        var lines: [String] = []
        func note(_ text: String) { lines.append(text) }

        note("Clamshell diagnostics")
        note("=====================")
        note("bundle path      : \(Bundle.main.bundlePath)")
        note("bundle id        : \(Bundle.main.bundleIdentifier ?? "nil")")
        note("executable       : \(Bundle.main.executablePath ?? "nil")")
        note("")

        note("CGPreflightScreenCaptureAccess() : \(CGPreflightScreenCaptureAccess())")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            note("SCShareableContent               : OK, \(content.displays.count) display(s), \(content.windows.count) window(s)")
            for display in content.displays {
                note("   display \(display.displayID): \(display.width)x\(display.height) points")
            }
            note("")
            note("VERDICT: screen recording permission IS granted for this bundle.")
        } catch {
            let nsError = error as NSError
            note("SCShareableContent               : FAILED")
            note("   domain \(nsError.domain) code \(nsError.code)")
            note("   \(error.localizedDescription)")
            note("")
            if nsError.code == -3801 {
                note("VERDICT: permission is DENIED or not yet answered (SCStreamErrorUserDeclined).")
            } else {
                note("VERDICT: capture unavailable for a reason other than permission.")
            }
        }

        note("")
        note("Lid angle sensor")
        let sensor = LidAngleSensor()
        note("   available     : \(sensor.isAvailable)")
        note("   resolution    : \(sensor.resolution) degrees")
        note("   current angle : \(sensor.currentAngle().map { String(format: "%.2f", $0) } ?? "nil")")

        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(text.utf8))
    }
}
