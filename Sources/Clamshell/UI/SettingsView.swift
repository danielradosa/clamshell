import SwiftUI

struct SettingsView: View {

    @ObservedObject private var settings = Settings.shared
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            preview
                .frame(width: 268)
                .padding(20)
                .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            ScrollView {
                controls.padding(20)
            }
            .frame(width: 372)
        }
        .frame(width: 640, height: 560)
        .onAppear { model.beginPreview() }
        .onDisappear { model.endPreview() }
    }

    private var preview: some View {
        VStack(spacing: 16) {
            LidPreview(fold: model.previewFold, style: settings.style)
                .frame(height: 200)

            VStack(spacing: 3) {
                if model.hasSensor {
                    Text("\(Int(model.liveAngle))°")
                        .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    Text("Live lid angle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "laptopcomputer.slash")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("No lid sensor")
                        .font(.callout.weight(.medium))
                    Text("Drag below to preview")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.isScrubbing) {
                    Text("Preview an angle by hand").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $model.scrubAngle, in: 0...120)
                    Text("\(Int(model.scrubAngle))°")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .disabled(!model.isScrubbing)
                .opacity(model.isScrubbing ? 1 : 0.4)
            }

            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(isOn: $settings.enabled) {
                Text("Enable the fold effect").font(.body.weight(.medium))
            }
            .toggleStyle(.switch)

            section("Style") {
                Picker("", selection: $settings.styleID) {
                    ForEach(FoldStyle.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(FoldStyle.named(settings.styleID).blurb)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 30, alignment: .top)
            }

            section("Intensity") {
                slider("Blur", "camera.filters", $settings.blurScale, 0...2)
                slider("Depth", "cube", $settings.perspectiveScale, 0...2)
                slider("Shadow", "moon.fill", $settings.shadowScale, 0...2)
                slider("Edge", "square.dashed", $settings.edgeScale, 0...3)
            }

            section("Behaviour") {
                labelled("Clears above", value: "\(Int(settings.engageAngle))°") {
                    Slider(value: $settings.engageAngle, in: 30...115)
                }
                Text("Open the lid past this angle and the effect gets out of the way.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labelled("Opening animation",
                         value: String(format: "%.2fs", settings.unfoldDuration)) {
                    Slider(value: $settings.unfoldDuration, in: 0.3...1.5)
                }
                Text("A lid opens faster than the screen switches on, so the unfold runs on its own clock.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.soundEnabled) {
                    Text("Click when the effect clears").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Divider()

            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
                    .controlSize(.regular)
            }
        }
        .disabled(!settings.enabled)
        .opacity(settings.enabled ? 1 : 0.5)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content()
        }
    }

    private func slider(_ title: String, _ symbol: String,
                        _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(title).font(.callout)
            } icon: {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            Slider(value: value, in: range)

            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func labelled<Content: View>(
        _ title: String, value: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

struct LidPreview: View {
    let fold: Double
    let style: FoldStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black)

                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.30, green: 0.42, blue: 0.86),
                                 Color(red: 0.66, green: 0.34, blue: 0.74),
                                 Color(red: 0.92, green: 0.48, blue: 0.42)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        LinearGradient(colors: [.clear, .black.opacity(style.shadowStrength * fold)],
                                       startPoint: .bottom, endPoint: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 5)))
                    .blur(radius: style.blurRadius * fold * 0.06)
                    .brightness(-style.darkening * fold * 0.7)
                    .rotation3DEffect(.degrees(fold * 82), axis: (x: 1, y: 0, z: 0),
                                      anchor: .bottom, perspective: style.perspective * 0.7)
                    .padding(14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
