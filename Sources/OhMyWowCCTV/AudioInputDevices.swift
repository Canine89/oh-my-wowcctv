import CoreAudio
import Foundation

/// macOS 오디오 입력 장치 목록과 시스템 기본 입력 장치 (CoreAudio).
/// OBS 의 coreaudio_input_capture 는 device_id 로 이 UID 를 쓰고, "default" 면 시스템 기본 입력을 따라간다.
enum AudioInputDevices {
    struct Device: Equatable {
        let uid: String
        let name: String
    }

    static func list() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    static func defaultInput() -> Device? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        return Device(uid: uid, name: name)
    }

    /// 표시용 이름: "default" → "시스템 기본 (AirPods)", UID → 장치 이름
    static func displayName(for deviceID: String) -> String {
        if deviceID == "default" { return "시스템 기본" + (defaultInput().map { " (\($0.name))" } ?? "") }
        return list().first { $0.uid == deviceID }?.name ?? deviceID
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return status == noErr ? (value as String) : nil
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buffer).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
