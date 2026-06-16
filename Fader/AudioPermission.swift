import Foundation
import Combine

/// Wraps the TCC audio-capture permission (same private SPI AudioCap uses).
/// Core Audio process taps require `kTCCServiceAudioCapture`.
final class AudioPermission: ObservableObject {
    enum Status { case unknown, denied, authorized }
    @Published private(set) var status: Status = .unknown

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private let service = "kTCCServiceAudioCapture" as CFString

    func refresh() {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
    }

    /// Requests permission (shows the system prompt if undetermined).
    func request(_ completion: @escaping (Bool) -> Void) {
        refresh()
        if status == .authorized { completion(true); return }
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { completion(false); return }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        request(service, nil) { [weak self] granted in
            DispatchQueue.main.async {
                self?.status = granted ? .authorized : .denied
                completion(granted)
            }
        }
    }
}
