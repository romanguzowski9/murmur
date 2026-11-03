import AudioToolbox
import CoreAudio
import Foundation
import MurmurCore

/// Core Audio input devices, and a listener for devices being connected or removed.
enum AudioDevices {
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), isAlive(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return InputDevice(id: id, uid: uid, name: name, transport: transport(id))
        }
    }

    static func current(preference: String) -> InputDevice? {
        MicrophonePicker.pick(inputDevices(), preference: preference, systemDefault: defaultInputID())
    }

    /// The input device selected in System Settings → Sound → Input.
    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) != noErr || alive != 0
    }

    private static func transport(_ id: AudioDeviceID) -> DeviceTransport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .unknown }
        switch value {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .wired
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuity
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: return .virtual
        default: return .unknown
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Keeps the chosen microphone up to date in the background, so pressing the hotkey never waits on Core Audio
/// (Bluetooth devices can take seconds to answer while AirPods switch into microphone mode).
final class MicrophoneMonitor {
    /// Called on the main queue when the chosen microphone changes.
    var onChange: ((InputDevice?) -> Void)?
    private(set) var current: InputDevice?
    private(set) var devices: [InputDevice] = []
    var preference = MicrophonePicker.automatic {
        didSet { refresh() }
    }

    private let queue = DispatchQueue(label: "murmur.devices")
    private var pending: DispatchWorkItem?

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, queue) { [weak self] _, _ in self?.scheduleRefresh() }
        }
        refresh()
    }

    /// Device changes arrive in bursts (AirPods add and reconfigure several devices); act once they settle.
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        let preference = self.preference
        queue.async { [weak self] in
            let list = AudioDevices.inputDevices()
            let picked = MicrophonePicker.pick(list, preference: preference, systemDefault: AudioDevices.defaultInputID())
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = list
                guard picked?.uid != self.current?.uid else { return }
                self.current = picked
                self.onChange?(picked)
            }
        }
    }
}
