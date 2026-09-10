import Foundation
import Combine
import SwiftUI

/// Bridges the running controller to the settings panel.
///
/// While the panel is open it drives the preview from the real sensor, so the
/// user can move the lid and watch the numbers respond. Turning on scrubbing
/// switches the controller to a manual angle instead, which is the only way to
/// judge a style at an angle you cannot comfortably hold the lid at.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var previewFold: Double = 0
    @Published var liveAngle: Double = 0

    @Published var isScrubbing = false {
        didSet { applyMode() }
    }

    @Published var scrubAngle: Double = 60 {
        didSet { if isScrubbing { applyMode() } }
    }

    var hasSensor: Bool { controller?.hasSensor ?? false }

    private weak var controller: FoldController?
    private var ticker: Timer?

    init(controller: FoldController?) {
        self.controller = controller
    }

    func beginPreview() {
        applyMode()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func endPreview() {
        ticker?.invalidate()
        ticker = nil
        isScrubbing = false
        controller?.setMode(controller?.hasSensor == true ? .sensor : .demo)
    }

    private func sample() {
        guard let controller else { return }
        liveAngle = controller.currentRawAngle
        previewFold = FoldCurve.progress(
            angle: liveAngle, engageAngle: Settings.shared.engageAngle
        )
    }

    private func applyMode() {
        guard let controller else { return }
        if isScrubbing {
            controller.setMode(.manual(scrubAngle))
        } else {
            controller.setMode(controller.hasSensor ? .sensor : .demo)
        }
    }
}
