import Foundation

/// UserDefaults 키와 기본값. 뷰에서는 @AppStorage(Prefs.Key.xxx) 로, 로직에서는 Prefs.xxx 로 접근한다.
enum Prefs {
    enum Key {
        static let wowRetailPath = "wowRetailPath"
        static let obsAppPath = "obsAppPath"
        static let recordingFolder = "recordingFolder"
        static let captureMode = "captureMode"        // "application" | "display"
        static let gameAudio = "gameAudio"
        static let micEnabled = "micEnabled"
        static let showCursor = "showCursor"
        static let hideOBS = "hideOBS"
        static let quitOBSWithWoW = "quitOBSWithWoW"
        static let stopDelaySeconds = "stopDelaySeconds"
        static let renameRecordings = "renameRecordings"
        static let stopOnZoneLeave = "stopOnZoneLeave"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let soundEnabled = "soundEnabled"
        static let testRecordingSeconds = "testRecordingSeconds"
        static let fitCanvasToWindow = "fitCanvasToWindow"
        static let cropTitleBar = "cropTitleBar"
        static let previewFPS = "previewFPS"
        static let leaveGraceSeconds = "leaveGraceSeconds"
        static let micDevice = "micDevice"          // "default" = macOS 시스템 기본 입력, 아니면 CoreAudio UID
        static let micGainDb = "micGainDb"          // OBS 게인 필터 (0~30 dB)
        static let voiceChatEnabled = "voiceChatEnabled"  // 친구 음성(디스코드 등) 녹음
        static let voiceChatApp = "voiceChatApp"          // 그 앱의 번들 ID
    }

    static let defaults: [String: Any] = [
        Key.wowRetailPath: "/Applications/World of Warcraft/_retail_",
        Key.obsAppPath: "/Applications/OBS.app",
        Key.recordingFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/WoW CCTV").path,
        Key.captureMode: "application",
        Key.gameAudio: true,
        Key.micEnabled: true,
        Key.showCursor: true,
        Key.hideOBS: true,
        Key.quitOBSWithWoW: true,
        Key.stopDelaySeconds: 5,
        Key.renameRecordings: true,
        Key.stopOnZoneLeave: true,
        Key.hotkeyEnabled: true,
        Key.soundEnabled: true,
        Key.testRecordingSeconds: 15,
        Key.fitCanvasToWindow: true,
        Key.cropTitleBar: true,
        Key.previewFPS: 30,
        Key.leaveGraceSeconds: 30,
        Key.micDevice: "default",
        Key.micGainDb: 0,
        Key.voiceChatEnabled: true,
        Key.voiceChatApp: VoiceChatApps.defaultBundleID(),
    ]

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    private static var ud: UserDefaults { .standard }

    static var wowRetailPath: String { ud.string(forKey: Key.wowRetailPath) ?? "" }
    static var wowLogsURL: URL { URL(fileURLWithPath: wowRetailPath).appendingPathComponent("Logs") }
    static var wowAddOnsURL: URL { URL(fileURLWithPath: wowRetailPath).appendingPathComponent("Interface/AddOns") }
    static var obsAppURL: URL { URL(fileURLWithPath: ud.string(forKey: Key.obsAppPath) ?? "/Applications/OBS.app") }
    static var recordingFolderURL: URL { URL(fileURLWithPath: ((ud.string(forKey: Key.recordingFolder) ?? "") as NSString).expandingTildeInPath).standardizedFileURL }
    static var hideOBS: Bool { ud.bool(forKey: Key.hideOBS) }
    static var quitOBSWithWoW: Bool { ud.bool(forKey: Key.quitOBSWithWoW) }
    static var stopDelaySeconds: Int { ud.integer(forKey: Key.stopDelaySeconds) }
    static var renameRecordings: Bool { ud.bool(forKey: Key.renameRecordings) }
    static var stopOnZoneLeave: Bool { ud.bool(forKey: Key.stopOnZoneLeave) }
    static var hotkeyEnabled: Bool { ud.bool(forKey: Key.hotkeyEnabled) }
    static var soundEnabled: Bool { ud.bool(forKey: Key.soundEnabled) }
    static var testRecordingSeconds: Int { max(3, ud.integer(forKey: Key.testRecordingSeconds)) }
    static var fitCanvasToWindow: Bool { ud.bool(forKey: Key.fitCanvasToWindow) }
    static var cropTitleBar: Bool { ud.bool(forKey: Key.cropTitleBar) }
    static var previewFPS: Int { min(60, max(5, ud.integer(forKey: Key.previewFPS))) }
    static var leaveGraceSeconds: Int { max(5, ud.integer(forKey: Key.leaveGraceSeconds)) }
    /// 친구 음성 앱 번들 ID. 꺼져 있으면 nil.
    static var voiceChatApp: String? {
        guard ud.bool(forKey: Key.voiceChatEnabled) else { return nil }
        let v = ud.string(forKey: Key.voiceChatApp) ?? ""
        return v.isEmpty ? nil : v
    }

    static var micGainDb: Int { min(30, max(0, ud.integer(forKey: Key.micGainDb))) }
    static var micDevice: String { let v = ud.string(forKey: Key.micDevice) ?? "default"; return v.isEmpty ? "default" : v }

    static var sceneOptions: OBSSceneOptions {
        OBSSceneOptions(
            capture: OBSSceneOptions.Capture(rawValue: ud.string(forKey: Key.captureMode) ?? "") ?? .application,
            gameAudio: ud.bool(forKey: Key.gameAudio),
            mic: ud.bool(forKey: Key.micEnabled),
            showCursor: ud.bool(forKey: Key.showCursor),
            voiceChat: voiceChatApp
        )
    }
}
