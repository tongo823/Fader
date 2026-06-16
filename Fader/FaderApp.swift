import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = AudioEngine()
    let permission = AudioPermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        permission.request { [weak self] granted in
            if granted { self?.engine.start() }
        }
        UpdaterModel.shared.checkSilently()   // UI-less: just flips "update available"

        // If the user grants permission later (e.g. via System Settings), pick it up
        // without requiring a relaunch.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.startIfPermitted()
        }
    }

    func startIfPermitted() {
        permission.refresh()
        if permission.status == .authorized { engine.start() }   // start() is idempotent
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Fader", systemImage: "speaker.wave.2.fill") {
            MixerView()
                .environmentObject(delegate.engine)
                .environmentObject(delegate.permission)
        }
        .menuBarExtraStyle(.window)

        Window("Fader Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
