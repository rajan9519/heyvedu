import CoreAudio
import Foundation
import Observation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Live list of input devices plus the user's preferred device (persisted by UID,
/// since AudioDeviceIDs are not stable across reconnects).
@Observable
final class AudioDeviceManager {
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var defaultInputDevice: AudioInputDevice?

    /// nil means "follow the system default input".
    var selectedDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: Self.selectedDeviceKey) }
    }

    @ObservationIgnored private var listening = false
    private static let selectedDeviceKey = "selectedInputDeviceUID"

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.selectedDeviceKey)
    }

    func start() {
        refresh()
        guard !listening else { return }
        listening = true
        addSystemListener(selector: kAudioHardwarePropertyDevices)
        addSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func refresh() {
        inputDevices = CoreAudioQuery.deviceIDs()
            .filter(CoreAudioQuery.hasInputStreams)
            .compactMap(CoreAudioQuery.device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaultInputDevice = CoreAudioQuery.defaultInputDeviceID().flatMap(CoreAudioQuery.device)
    }

    enum InputResolution {
        /// Record from the engine's default input (no device switch needed).
        case systemDefault
        /// Record from this specific device.
        case device(AudioDeviceID)
        /// No input device exists at all.
        case unavailable
    }

    /// Resolves the device to record from right now. `fellBackToDefault` is true when
    /// the user's chosen mic is not connected.
    func resolveInputDevice() -> (resolution: InputResolution, fellBackToDefault: Bool) {
        refresh()
        let fallback: InputResolution = defaultInputDevice == nil ? .unavailable : .systemDefault
        guard let uid = selectedDeviceUID else { return (fallback, false) }
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return (fallback, true) }
        // Selecting the current default explicitly would force a needless reconfiguration.
        if device.id == defaultInputDevice?.id { return (.systemDefault, false) }
        return (.device(device.id), false)
    }

    private func addSystemListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// Thin wrappers over the Core Audio property API.
private nonisolated enum CoreAudioQuery {
    static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
