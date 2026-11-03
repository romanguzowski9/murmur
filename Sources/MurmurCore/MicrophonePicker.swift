import Foundation

public enum DeviceTransport: String, Codable {
    case bluetooth, usb, wired, continuity, builtIn, virtual, unknown
}

public struct InputDevice: Equatable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var transport: DeviceTransport

    public init(id: UInt32, uid: String, name: String, transport: DeviceTransport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

/// Chooses the microphone Murmur records from. "auto" prefers a connected headset (AirPods and other Bluetooth
/// devices), then the input selected in macOS (System Settings → Sound → Input), then an external wired/USB mic, then
/// the built-in one. Virtual devices (Teams/Zoom drivers, loopback tools) are never picked automatically.
public enum MicrophonePicker {
    public static let automatic = "auto"

    static func rank(_ transport: DeviceTransport) -> Int {
        switch transport {
        case .bluetooth: return 4
        case .usb, .wired: return 3
        case .continuity: return 2
        case .builtIn, .unknown: return 1
        case .virtual: return 0
        }
    }

    public static func pick(_ devices: [InputDevice], preference: String, systemDefault: UInt32? = nil) -> InputDevice? {
        if preference != automatic, let chosen = devices.first(where: { $0.uid == preference }) { return chosen }
        let usable = devices.filter { $0.transport != .virtual }
        let headsets = usable.filter { $0.transport == .bluetooth }
        if let selected = headsets.first(where: { $0.id == systemDefault }) ?? headsets.max(by: { $0.id < $1.id }) {
            return selected
        }
        if let selected = usable.first(where: { $0.id == systemDefault }) { return selected }
        // Same kind: the newest device (highest Core Audio ID) is most likely the one just connected.
        return usable.max { (rank($0.transport), $0.id) < (rank($1.transport), $1.id) }
    }
}
