import Foundation
import AppKit
import AudioToolbox
import Darwin

/// A user-facing app that's producing audio. For browsers/Electron apps the sound
/// actually comes from helper *child* processes (e.g. "Google Chrome Helper"), so one
/// AudioApp can own several audio process objects — all controlled by one slider.
struct AudioApp: Identifiable, Equatable {
    let pid: pid_t                  // the owning (regular) app's pid
    let objectIDs: [AudioObjectID]  // every audio process attributed to this app
    let name: String
    let bundleID: String?
    let bundleURL: URL?

    var id: pid_t { pid }

    static func == (l: AudioApp, r: AudioApp) -> Bool {
        l.pid == r.pid && l.objectIDs == r.objectIDs
    }

    var icon: NSImage {
        let key = (bundleURL?.path ?? "·generic·") as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        let img: NSImage
        if let bundleURL {
            img = NSWorkspace.shared.icon(forFile: bundleURL.path)
            img.size = NSSize(width: 32, height: 32)
        } else {
            img = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        Self.iconCache.setObject(img, forKey: key)
        return img
    }

    private static let iconCache = NSCache<NSString, NSImage>()
}

enum AudioAppScanner {
    /// All regular apps producing audio, with helper-process audio attributed to the
    /// owning app (so YouTube-in-Chrome shows as one "Google Chrome" row). Background
    /// daemons with no regular-app ancestor are dropped.
    static func playingApps() -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundleID = Bundle.main.bundleIdentifier

        // Accumulate object IDs per owning app, preserving discovery order.
        var order: [pid_t] = []
        var grouped: [pid_t: (app: NSRunningApplication, oids: [AudioObjectID])] = [:]

        for oid in (try? AudioObjectID.readProcessList()) ?? [] where oid.isValid {
            guard oid.readIsRunningOutput() else { continue }
            let pid = oid.readPID()
            guard pid != selfPID else { continue }
            guard let owner = owningApp(of: pid, in: byPID), owner.processIdentifier != selfPID else { continue }
            guard owner.bundleIdentifier != selfBundleID else { continue }

            let opid = owner.processIdentifier
            if grouped[opid] == nil { grouped[opid] = (owner, []); order.append(opid) }
            grouped[opid]!.oids.append(oid)
        }

        return order.compactMap { opid in
            guard let entry = grouped[opid] else { return nil }
            let app = entry.app
            let name = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? "pid \(opid)"
            return AudioApp(pid: opid, objectIDs: entry.oids, name: name,
                            bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Walk up the process tree from `pid` until we hit a regular/accessory app
    /// (the browser/Electron parent). Returns nil for pure daemons.
    private static func owningApp(of pid: pid_t, in byPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = byPID[current], app.activationPolicy != .prohibited { return app }
            let parent = parentPID(of: current)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        return r == Int32(size) ? pid_t(info.pbi_ppid) : -1
    }
}
