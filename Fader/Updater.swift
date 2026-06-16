import SwiftUI
import Sparkle

// In-app updates via Sparkle — install is MANUAL only (no background auto-install;
// SUEnableAutomaticChecks is false in Info.plist). What IS automatic is a lightweight,
// UI-less PROBE of the signed appcast on launch so we can tell the user "an update is
// available." They still choose when to install: clicking "Check for Updates" / the
// install button runs the real check, which offers a one-click download → install →
// relaunch (with changelog). So: we notify, the user decides — nothing updates behind
// their back. Same setup as Relay; updates need no App Store / Apple notarization.

@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterModel()

    private(set) var controller: SPUStandardUpdaterController!

    /// True once a silent probe finds a newer build on the appcast.
    @Published var updateAvailable = false
    /// The version string of that newer build, for the install button label.
    @Published var latestVersion: String?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// User-initiated check — shows Sparkle's UI (the install prompt with release notes).
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Silent probe — no UI. Asks the appcast "is there anything newer?" and reports via
    /// the delegate methods below, which flip `updateAvailable`.
    func checkSilently() {
        guard canCheck else { return }
        controller.updater.checkForUpdateInformation()
    }

    // MARK: SPUUpdaterDelegate (called on the main thread)
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateAvailable = true
            self.latestVersion = item.displayVersionString
        }
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
            self.latestVersion = nil
        }
    }
}
