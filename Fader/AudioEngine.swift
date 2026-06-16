import Foundation
import AudioToolbox
import CoreAudio
import Combine

/// Per-tap render metadata read by the real-time IO callback.
private struct RenderSlot {
    var channels: Int       // channels in this tap's stream
    var interleaved: Bool   // true => 1 buffer w/ N channels; false => N buffers
}

/// The audio core: taps every currently-playing app (muting its normal output),
/// then re-renders all of them through ONE private aggregate device, applying a
/// per-app gain. Gain 1.0 == transparent pass-through; 0.0 == silence; >1 boosts.
final class AudioEngine: ObservableObject {

    @Published private(set) var apps: [AudioApp] = []
    @Published var masterVolume: Float = MasterVolume.get()
    @Published private(set) var masterAvailable: Bool = MasterVolume.isAvailable

    /// Per-app UI state, keyed by pid and persisted across tap rebuilds.
    @Published var volumes: [pid_t: Float] = [:]
    @Published var mutes: [pid_t: Bool] = [:]
    /// Live output level per app (0…1), updated ~10×/s for meters.
    @Published var meters: [pid_t: Float] = [:]

    private var tapIDs: [AudioObjectID] = []
    private var slotAppIDs: [pid_t] = []                 // owning-app pid per tap slot
    private var tappedObjectIDs: Set<AudioObjectID> = [] // every process object currently tapped
    private var renderSlots: [RenderSlot] = []
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?

    // Real-time-readable buffers (no ARC / no allocation in the callback).
    private static let maxSlots = 64
    private static let maxFrames = 16384
    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)      // target gain (UI thread writes)
    private let smoothPtr = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)    // ramped gain (audio thread only)
    private let peakPtr = UnsafeMutablePointer<Float>.allocate(capacity: maxSlots)
    private let accL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let accR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)

    private var scanTimer: Timer?
    private var meterTimer: Timer?
    private var pidBundle: [pid_t: String] = [:]   // pid → bundleID, for persistence lookups
    private var currentOutputUID = ""              // default output device, to detect device switches

    init() {
        gainPtr.initialize(repeating: 1, count: Self.maxSlots)
        smoothPtr.initialize(repeating: 1, count: Self.maxSlots)
        peakPtr.initialize(repeating: 0, count: Self.maxSlots)
        accL.initialize(repeating: 0, count: Self.maxFrames)
        accR.initialize(repeating: 0, count: Self.maxFrames)
    }

    func start() {
        guard scanTimer == nil else { return }   // idempotent: safe to call repeatedly
        AudioEngine.destroyOrphanedAggregates()   // clean up anything a prior crash left behind
        rescan()
        // .common mode so meters/rescan keep firing even during menu/tracking loops.
        let st = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.rescan() }
        let mt = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.pollMeters() }
        RunLoop.main.add(st, forMode: .common)
        RunLoop.main.add(mt, forMode: .common)
        scanTimer = st; meterTimer = mt
    }

    /// Destroy any leftover "Fader-Aggregate" devices from a previous (possibly crashed)
    /// session so we never accumulate orphaned aggregate devices.
    static func destroyOrphanedAggregates() {
        let devices = (try? AudioObjectID.system.readDeviceList()) ?? []
        for dev in devices {
            guard let name = try? dev.readString(kAudioObjectPropertyName), name.hasPrefix("Fader-Aggregate") else { continue }
            AudioHardwareDestroyAggregateDevice(dev)
        }
    }

    func stop() {
        scanTimer?.invalidate(); meterTimer?.invalidate()
        teardown()
    }

    // MARK: - Public control

    func volume(for app: AudioApp) -> Float { volumes[app.pid] ?? 1.0 }
    func isMuted(_ app: AudioApp) -> Bool { mutes[app.pid] ?? false }

    func setVolume(_ value: Float, for app: AudioApp) {
        volumes[app.pid] = value
        applyGain(for: app.pid)
        AppPrefs.setVolume(value, for: app.bundleID)
    }

    func toggleMute(_ app: AudioApp) {
        let newValue = !(mutes[app.pid] ?? false)
        mutes[app.pid] = newValue
        applyGain(for: app.pid)
        AppPrefs.setMuted(newValue, for: app.bundleID)
    }

    func setMaster(_ value: Float) {
        masterVolume = value
        MasterVolume.set(value)
    }

    private func applyGain(for pid: pid_t) {
        let muted = mutes[pid] ?? false
        let g: Float = muted ? 0 : (volumes[pid] ?? 1.0)
        for (idx, appID) in slotAppIDs.enumerated() where appID == pid { gainPtr[idx] = g }
    }

    // MARK: - Scanning / rebuild

    private func rescan() {
        let playing = AudioAppScanner.playingApps()
        // Seed each app's level from its saved preference (by bundle ID) the first
        // time we see it this session, before building taps.
        for app in playing {
            pidBundle[app.pid] = app.bundleID
            if volumes[app.pid] == nil { volumes[app.pid] = AppPrefs.volume(for: app.bundleID) ?? 1.0 }
            if mutes[app.pid] == nil { mutes[app.pid] = AppPrefs.muted(for: app.bundleID) ?? false }
        }
        // Rebuild when the set of audio processes changes (a new Chrome tab, an app
        // starting/stopping sound) OR when the default output device changes (headphones
        // plugged in, AirPlay, etc.) — otherwise audio would stay routed to the old device
        // while tapped apps remain muted.
        let outUID = (try? AudioObjectID.readDefaultOutputDevice().readDeviceUID()) ?? ""
        let newObjectIDs = Set(playing.flatMap(\.objectIDs))
        let deviceChanged = !outUID.isEmpty && outUID != currentOutputUID
        if newObjectIDs != tappedObjectIDs || (deviceChanged && !playing.isEmpty) {
            currentOutputUID = outUID
            rebuild(for: playing)
        } else if deviceChanged {
            currentOutputUID = outUID
        }
        if apps != playing { apps = playing }
        let avail = MasterVolume.isAvailable
        if avail != masterAvailable { masterAvailable = avail }
        let m = MasterVolume.get()
        if abs(m - masterVolume) > 0.001 { masterVolume = m }
    }

    private func rebuild(for playing: [AudioApp]) {
        teardown()
        guard !playing.isEmpty else { apps = []; return }

        var tapUIDs: [String] = []
        var newTapIDs: [AudioObjectID] = []
        var newSlotAppIDs: [pid_t] = []
        var newObjectIDs: Set<AudioObjectID> = []
        var newSlots: [RenderSlot] = []

        // One tap per audio process; helpers of the same app share that app's gain.
        for app in playing {
            let muted = mutes[app.pid] ?? false
            let g: Float = muted ? 0 : (volumes[app.pid] ?? 1.0)
            for oid in app.objectIDs where newSlots.count < Self.maxSlots {
                let desc = CATapDescription(stereoMixdownOfProcesses: [oid])
                desc.uuid = UUID()
                desc.muteBehavior = .mutedWhenTapped   // silence the process's normal output; we re-render it
                desc.name = "Fader-\(app.pid)"
                desc.isPrivate = true

                var tapID: AudioObjectID = .unknown
                guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID.isValid else { continue }

                let fmt = (try? tapID.readTapStreamFormat()) ?? AudioStreamBasicDescription()
                let interleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                let channels = max(1, Int(fmt.mChannelsPerFrame))

                let slot = newSlots.count
                newTapIDs.append(tapID)
                tapUIDs.append(desc.uuid.uuidString)
                newSlotAppIDs.append(app.pid)
                newObjectIDs.insert(oid)
                newSlots.append(RenderSlot(channels: channels, interleaved: interleaved))
                gainPtr[slot] = g
                smoothPtr[slot] = g   // start at target so a fresh tap doesn't fade in
                peakPtr[slot] = 0
            }
        }

        guard !newTapIDs.isEmpty else { return }

        // One private aggregate device: real output + all taps.
        guard let outputUID = try? AudioObjectID.readDefaultOutputDevice().readDeviceUID() else { return }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0]
            }
        ]
        var agg: AudioObjectID = .unknown
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr, agg.isValid else {
            // Roll back taps we created.
            newTapIDs.forEach { AudioHardwareDestroyProcessTap($0) }
            return
        }

        tapIDs = newTapIDs
        slotAppIDs = newSlotAppIDs
        tappedObjectIDs = newObjectIDs
        renderSlots = newSlots
        aggregateID = agg

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInput, _, outOutput, _ in
            self?.render(input: inInput, output: outOutput)
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil, ioBlock) == noErr else { teardown(); return }
        AudioDeviceStart(agg, procID)
    }

    private func teardown() {
        if aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
            procID = nil
        }
        tapIDs.forEach { AudioHardwareDestroyProcessTap($0) }
        tapIDs = []; slotAppIDs = []; tappedObjectIDs = []; renderSlots = []
    }

    // MARK: - Real-time render: sum (tap_i * gain_i) -> stereo output

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard outList.count > 0 else { return }

        // Frames available on the output side.
        let outInterleaved = outList[0].mNumberChannels > 1 && outList.count == 1
        let outCh = outInterleaved ? Int(outList[0].mNumberChannels) : outList.count
        let frames = outInterleaved
            ? Int(outList[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(outList[0].mNumberChannels)))
            : Int(outList[0].mDataByteSize) / MemoryLayout<Float>.size
        let n = min(frames, Self.maxFrames)
        guard n > 0 else { return }

        // Zero the stereo accumulator.
        accL.update(repeating: 0, count: n)
        accR.update(repeating: 0, count: n)

        // Walk the input buffer list slot by slot, summing gained stereo.
        // Gain ramps from its previous value to the target across the buffer so
        // slider drags never click/zipper.
        var cursor = 0
        for (idx, slot) in renderSlots.enumerated() {
            let gStart = smoothPtr[idx]
            let gEnd = gainPtr[idx]
            let gStep = n > 0 ? (gEnd - gStart) / Float(n) : 0
            var slotPeak: Float = 0
            if slot.interleaved {
                guard cursor < inList.count else { break }
                let buf = inList[cursor]; cursor += 1
                let ch = max(1, Int(buf.mNumberChannels))
                let avail = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                if let p = buf.mData?.bindMemory(to: Float.self, capacity: avail * ch) {
                    let m = min(n, avail)
                    for f in 0..<m {
                        let g = gStart + gStep * Float(f)
                        let l = p[f * ch]; let r = ch > 1 ? p[f * ch + 1] : l
                        accL[f] += l * g; accR[f] += r * g
                        slotPeak = max(slotPeak, max(abs(l), abs(r)))
                    }
                }
            } else {
                let ch = slot.channels
                guard cursor + ch <= inList.count else { break }   // never read past the buffer list
                let lBuf = inList[cursor]
                let rBuf = ch > 1 ? inList[cursor + 1] : inList[cursor]
                cursor += ch
                let availL = Int(lBuf.mDataByteSize) / MemoryLayout<Float>.size
                let availR = Int(rBuf.mDataByteSize) / MemoryLayout<Float>.size
                let pL = lBuf.mData?.bindMemory(to: Float.self, capacity: availL)
                let pR = rBuf.mData?.bindMemory(to: Float.self, capacity: availR)
                let m = min(n, min(availL, availR))
                if let pL, let pR {
                    for f in 0..<m {
                        let g = gStart + gStep * Float(f)
                        let l = pL[f]; let r = pR[f]
                        accL[f] += l * g; accR[f] += r * g
                        slotPeak = max(slotPeak, max(abs(l), abs(r)))
                    }
                }
            }
            smoothPtr[idx] = gEnd
            if idx < Self.maxSlots { peakPtr[idx] = max(peakPtr[idx], slotPeak * gEnd) }
        }

        // Write the stereo accumulator to the output (soft-limited). Handle mono
        // (downmix), stereo, and multichannel (L/R to first two, silence the rest)
        // for both interleaved and planar device layouts.
        if outInterleaved {
            if let p = outList[0].mData?.bindMemory(to: Float.self, capacity: n * outCh) {
                for f in 0..<n {
                    if outCh == 1 {
                        p[f] = softClip((accL[f] + accR[f]) * 0.5)
                    } else {
                        let l = softClip(accL[f]); let r = softClip(accR[f])
                        for c in 0..<outCh { p[f * outCh + c] = c == 0 ? l : (c == 1 ? r : 0) }
                    }
                }
            }
        } else if outList.count == 1 {
            if let p = outList[0].mData?.bindMemory(to: Float.self, capacity: n) {
                for f in 0..<n { p[f] = softClip((accL[f] + accR[f]) * 0.5) }   // mono device
            }
        } else {
            for c in 0..<outList.count {
                if let p = outList[c].mData?.bindMemory(to: Float.self, capacity: n) {
                    if c == 0 { for f in 0..<n { p[f] = softClip(accL[f]) } }
                    else if c == 1 { for f in 0..<n { p[f] = softClip(accR[f]) } }
                    else { for f in 0..<n { p[f] = 0 } }   // silence surround channels
                }
            }
        }
    }

    /// Transparent below 0.9, then a smooth tanh knee up to ±1.0. Lets >100%
    /// boost get genuinely louder without harsh digital clipping, while keeping
    /// unity (100%) fully transparent.
    private func softClip(_ x: Float) -> Float {
        let t: Float = 0.9
        if x <= t && x >= -t { return x }
        let s: Float = x < 0 ? -1 : 1
        return s * (t + (1 - t) * tanh((abs(x) - t) / (1 - t)))
    }

    private func pollMeters() {
        guard !slotAppIDs.isEmpty else {
            if !meters.isEmpty { meters = [:] }
            return
        }
        // Aggregate per app: the loudest of its (possibly several) taps.
        var next: [pid_t: Float] = [:]
        for (idx, pid) in slotAppIDs.enumerated() {
            next[pid] = max(next[pid] ?? 0, peakPtr[idx])
            peakPtr[idx] = 0
        }
        meters = next
    }

    deinit {
        teardown()
        gainPtr.deallocate(); smoothPtr.deallocate(); peakPtr.deallocate()
        accL.deallocate(); accR.deallocate()
    }
}
