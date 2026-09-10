import Foundation
import Combine
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var previewFold: Double = 0
    @Published var liveAngle: Double = 0

    @Published var isScrubbing: Bool {
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
        self.isScrubbing = (controller?.hasSensor ?? false) == false
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
        controller?.setMode(controller?.hasSensor == true
                            ? .sensor : .manual(AngleSource.restingAngle))
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
            controller.setMode(controller.hasSensor
                               ? .sensor : .manual(AngleSource.restingAngle))
        }
    }
}
