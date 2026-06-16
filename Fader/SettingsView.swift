import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var updater = UpdaterModel.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            section("General") {
                Toggle("Launch Fader at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in LoginItem.set(newValue) }
            }

            section("Updates") {
                HStack {
                    Text("Current version").foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(updater.currentVersion)").monospacedDigit()
                }
                HStack {
                    if updater.updateAvailable {
                        Label("v\(updater.latestVersion ?? "?") available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Button("Install Update") { updater.checkForUpdates() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Button("Check for Updates") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                        Spacer()
                    }
                }
                Text("Fetches the latest signed build from GitHub and installs it in one click.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            section("About") {
                Link("Fader on GitHub", destination: URL(string: "https://github.com/hatimhtm/Fader")!)
                Text("Per-app volume for macOS. Free & open source.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(22)
        .frame(width: 380, height: 300)
        .onDisappear { NSApp.setActivationPolicy(.accessory) }   // back to menu-bar-only
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.vertical.3").font(.system(size: 18, weight: .semibold))
            Text("Fader Settings").font(.system(size: 17, weight: .semibold))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
