import SwiftUI

/// The settings panel: style presets, intensity sliders and a live preview.
struct SettingsView: View {

    @ObservedObject private var settings = Settings.shared
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            preview
            controls
        }
        .padding(24)
        .frame(width: 640, height: 520)
        .onAppear { model.beginPreview() }
        .onDisappear { model.endPreview() }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 14) {
            LidPreview(fold: model.previewFold, style: settings.style)
                .frame(width: 240, height: 190)

            if model.hasSensor {
                Text("\(Int(model.liveAngle))°")
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                Text("Live from the lid sensor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No lid sensor on this Mac")
                    .font(.callout)
                Text("Showing a looping demo instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: $model.scrubAngle, in: 0...120) {
                Text("Angle")
            }
            .disabled(!model.isScrubbing)

            Toggle("Drag to preview an angle", isOn: $model.isScrubbing)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .frame(width: 240)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable the fold effect", isOn: $settings.enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                Text("Style").font(.headline)
                Picker("", selection: $settings.styleID) {
                    ForEach(FoldStyle.all) { style in
                        Text(style.name).tag(style.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(FoldStyle.named(settings.styleID).blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 28, alignment: .top)
            }

            Divider()

            labelledSlider("Depth", value: $settings.perspectiveScale, range: 0...2)
            labelledSlider("Blur", value: $settings.blurScale, range: 0...2)
            labelledSlider("Shadow", value: $settings.shadowScale, range: 0...2)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clears above").font(.callout)
                    Spacer()
                    Text("\(Int(settings.engageAngle))°")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.engageAngle, in: 30...110)
                Text("Open the lid past this angle and the effect gets out of the way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opening animation").font(.callout)
                    Spacer()
                    Text(String(format: "%.2fs", settings.unfoldDuration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.unfoldDuration, in: 0.3...1.5)
                Text("A lid is opened faster than the screen can switch on, so the unfold plays on its own clock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Click when the effect clears", isOn: $settings.soundEnabled)
                .toggleStyle(.checkbox)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelledSlider(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// A small, cheap approximation of the real effect, drawn with SwiftUI rather
/// than Metal. It exists to make the sliders legible while adjusting them; the
/// real thing runs on the GPU over the live desktop.
struct LidPreview: View {
    let fold: Double
    let style: FoldStyle

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.black)

            GeometryReader { geo in
                let angle = fold * 82.0
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.36, green: 0.52, blue: 0.86),
                                Color(red: 0.62, green: 0.36, blue: 0.72),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(style.shadowStrength * fold)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    )
                    .blur(radius: style.blurRadius * fold * fold * 0.35)
                    .brightness(-style.darkening * fold * 0.8)
                    .rotation3DEffect(
                        .degrees(angle),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: .bottom,
                        perspective: style.perspective * 0.9
                    )
                    .padding(12)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
