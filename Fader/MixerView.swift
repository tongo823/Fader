import SwiftUI
import AppKit

struct MixerView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var permission: AudioPermission
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            switch permission.status {
            case .denied:
                permissionBlocked
            default:
                if engine.masterAvailable {
                    masterRow
                    Divider().padding(.horizontal, 16)
                }
                content
            }

            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: 300)
        .animation(.snappy(duration: 0.28), value: engine.apps)
        .onAppear {
            permission.refresh()
            if permission.status == .authorized { engine.start() }   // catch a late grant
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Fader")
                .font(.system(size: 14, weight: .semibold))
            if !engine.apps.isEmpty {
                Text("\(engine.apps.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            Button {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    // MARK: Master

    private var masterRow: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.masterVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("OUTPUT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Slider(value: Binding(get: { Double(engine.masterVolume) },
                                      set: { engine.setMaster(Float($0)) }), in: 0...1)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: App list

    @ViewBuilder private var content: some View {
        if engine.apps.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Nothing is playing")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .transition(.opacity)
        } else {
            VStack(spacing: 1) {
                ForEach(engine.apps) { app in
                    AppRow(app: app)
                        .environmentObject(engine)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: Permission blocked

    private var permissionBlocked: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 24)).foregroundStyle(.orange)
            Text("Audio access needed").font(.system(size: 13, weight: .semibold))
            Text("Fader needs Audio Recording permission to adjust each app's volume. It never records or sends audio anywhere.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 22)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Fader") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

// MARK: - App row

struct AppRow: View {
    static let maxVolume: Float = 1.5   // 150% ceiling; 100% sits at the detent

    let app: AudioApp
    @EnvironmentObject var engine: AudioEngine
    @State private var hovering = false

    private var muted: Bool { engine.isMuted(app) }
    private var level: Float { engine.meters[app.pid] ?? 0 }
    private var atUnity: Bool { abs(engine.volume(for: app) - 1.0) < 0.001 }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(engine.volume(for: app)) },
            set: { raw in
                // Magnetic detent: snap to exactly 100% when close, so it's easy to
                // land on unity and deliberate to push past it into boost.
                let snapped = abs(raw - 1.0) < 0.06 ? 1.0 : raw
                engine.setVolume(Float(snapped), for: app)
            })
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: app.icon)
                .resizable().frame(width: 29, height: 29)
                .opacity(muted ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(Int(engine.volume(for: app) * 100))%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : (atUnity ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)))
                }
                ZStack {
                    UnityTick(fraction: CGFloat(1.0 / Double(Self.maxVolume)))
                    Slider(value: volumeBinding, in: 0...Double(Self.maxVolume))
                        .controlSize(.small)
                        .disabled(muted)
                }
                .frame(height: 20)
                LevelMeter(level: muted ? 0 : level)
                    .frame(height: 2.5)
            }

            Button { engine.toggleMute(app) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(muted ? Color.red : .secondary)
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.06 : 0))
        )
        .onHover { hovering = $0 }
    }
}

/// A small tick mark on the slider track marking the 100% (unity) position.
struct UnityTick: View {
    let fraction: CGFloat
    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 7
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 2, height: 8)
                .position(x: inset + (geo.size.width - inset * 2) * fraction, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(1, level)))
                        .animation(.linear(duration: 0.08), value: level)
                }
        }
    }
}
