import Foundation

// MARK: - INI

/// 줄 단위로 섹션/키를 고치고 나머지는 그대로 보존하는 아주 작은 INI 편집기 (OBS basic.ini / user.ini 용).
struct INIFile {
    private(set) var lines: [String]

    init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    var text: String { lines.joined(separator: "\n") }

    private static func sectionName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    private func sectionRange(_ section: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { Self.sectionName($0) == section }) else { return nil }
        var end = start + 1
        while end < lines.count, Self.sectionName(lines[end]) == nil { end += 1 }
        return start..<end
    }

    func get(_ section: String, _ key: String) -> String? {
        guard let range = sectionRange(section) else { return nil }
        for line in lines[range] {
            if let eq = line.firstIndex(of: "="), String(line[..<eq]) == key {
                return String(line[line.index(after: eq)...])
            }
        }
        return nil
    }

    mutating func set(_ section: String, _ key: String, _ value: String) {
        if let range = sectionRange(section) {
            for i in range where lines[i].hasPrefix(key + "=") {
                lines[i] = "\(key)=\(value)"
                return
            }
            // 섹션 끝의 빈 줄 앞에 삽입
            var insertAt = range.upperBound
            while insertAt > range.lowerBound + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert("\(key)=\(value)", at: insertAt)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(key)=\(value)")
            lines.append("")
        }
    }

    mutating func removeSection(_ section: String) {
        guard let range = sectionRange(section) else { return }
        lines.removeSubrange(range)
    }

    var sections: [String] { lines.compactMap(Self.sectionName) }

    func write(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - OBS 파일 경로

enum OBSPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/obs-studio")
    static let userINI = root.appendingPathComponent("user.ini")
    static let profiles = root.appendingPathComponent("basic/profiles")
    static let scenes = root.appendingPathComponent("basic/scenes")
    static let webSocketConfig = root.appendingPathComponent("plugin_config/obs-websocket/config.json")

    static let cctvName = "OhMyWowCCTV"
    static var cctvProfileDir: URL { profiles.appendingPathComponent(cctvName) }
    static var cctvProfileINI: URL { cctvProfileDir.appendingPathComponent("basic.ini") }
    static var cctvSceneCollection: URL { scenes.appendingPathComponent("\(cctvName).json") }
}

// MARK: - obs-websocket 설정

struct OBSWebSocketConfig {
    var serverEnabled: Bool
    var authRequired: Bool
    var port: Int
    var password: String

    static func load() -> OBSWebSocketConfig? {
        guard let data = try? Data(contentsOf: OBSPaths.webSocketConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return OBSWebSocketConfig(
            serverEnabled: json["server_enabled"] as? Bool ?? false,
            authRequired: json["auth_required"] as? Bool ?? true,
            port: json["server_port"] as? Int ?? 4455,
            password: json["server_password"] as? String ?? ""
        )
    }

    var clientConfig: OBSClient.Config {
        OBSClient.Config(host: "127.0.0.1", port: port, password: authRequired ? password : "")
    }

    /// 서버가 꺼져 있으면 켠다. 파일이 없으면 무작위 비밀번호로 새로 만든다. OBS 가 꺼져 있을 때만 호출할 것.
    @discardableResult
    static func ensureEnabled() throws -> OBSWebSocketConfig {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: OBSPaths.webSocketConfig),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = j
        }
        var changed = false
        if json["server_enabled"] as? Bool != true { json["server_enabled"] = true; changed = true }
        if json["server_port"] == nil { json["server_port"] = 4455; changed = true }
        if json["auth_required"] == nil { json["auth_required"] = true; changed = true }
        if (json["server_password"] as? String ?? "").isEmpty {
            json["server_password"] = Self.randomPassword(); changed = true
        }
        if json["first_load"] as? Bool != false { json["first_load"] = false; changed = true }
        if json["alerts_enabled"] == nil { json["alerts_enabled"] = false; changed = true }
        if changed {
            try FileManager.default.createDirectory(at: OBSPaths.webSocketConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: OBSPaths.webSocketConfig, options: .atomic)
        }
        return load()!
    }

    private static func randomPassword() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<20).map { _ in chars.randomElement()! })
    }
}

// MARK: - user.ini (현재 프로필/장면 모음)

struct OBSUserBasic: Codable, Equatable {
    var profile: String?
    var profileDir: String?
    var sceneCollection: String?
    var sceneCollectionFile: String?

    static func read() -> OBSUserBasic? {
        guard let ini = try? INIFile(contentsOf: OBSPaths.userINI) else { return nil }
        return OBSUserBasic(
            profile: ini.get("Basic", "Profile"),
            profileDir: ini.get("Basic", "ProfileDir"),
            sceneCollection: ini.get("Basic", "SceneCollection"),
            sceneCollectionFile: ini.get("Basic", "SceneCollectionFile")
        )
    }

    var isCCTV: Bool { profileDir == OBSPaths.cctvName || sceneCollectionFile == "\(OBSPaths.cctvName).json" }

    /// CCTV 가 아닌 첫 번째 프로필/장면 모음 (사용자가 원래 쓰던 것으로 되돌릴 때의 대안)
    static func fallbackNonCCTV() -> OBSUserBasic? {
        let fm = FileManager.default
        var result = OBSUserBasic()
        if let dirs = try? fm.contentsOfDirectory(atPath: OBSPaths.profiles.path) {
            for dir in dirs.sorted() where dir != OBSPaths.cctvName {
                if let ini = try? INIFile(contentsOf: OBSPaths.profiles.appendingPathComponent(dir).appendingPathComponent("basic.ini")) {
                    result.profileDir = dir
                    result.profile = ini.get("General", "Name") ?? dir
                    break
                }
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: OBSPaths.scenes.path) {
            for file in files.sorted() where file.hasSuffix(".json") && file != "\(OBSPaths.cctvName).json" {
                if let data = try? Data(contentsOf: OBSPaths.scenes.appendingPathComponent(file)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result.sceneCollectionFile = file
                    result.sceneCollection = json["name"] as? String ?? String(file.dropLast(5))
                    break
                }
            }
        }
        return result.profileDir == nil && result.sceneCollectionFile == nil ? nil : result
    }

    func write() throws {
        var ini = (try? INIFile(contentsOf: OBSPaths.userINI)) ?? INIFile(text: "")
        if let profile { ini.set("Basic", "Profile", profile) }
        if let profileDir { ini.set("Basic", "ProfileDir", profileDir) }
        if let sceneCollection { ini.set("Basic", "SceneCollection", sceneCollection) }
        if let sceneCollectionFile { ini.set("Basic", "SceneCollectionFile", sceneCollectionFile) }
        try ini.write(to: OBSPaths.userINI)
    }
}

// MARK: - CCTV 전용 프로필

enum OBSProfileWriter {
    /// 사용자의 현재 프로필을 바탕으로 CCTV 프로필을 만든다. 이미 있으면 우리가 관리하는 키만 갱신한다.
    static func ensure(recordingFolder: URL) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: OBSPaths.cctvProfileINI.path)
        var ini: INIFile
        if exists {
            ini = try INIFile(contentsOf: OBSPaths.cctvProfileINI)
        } else {
            ini = templateFromUserProfile()
            ini = applyInitialDefaults(ini)
        }
        ini = applyManagedKeys(ini, recordingFolder: recordingFolder)
        try fm.createDirectory(at: OBSPaths.cctvProfileDir, withIntermediateDirectories: true)
        try ini.write(to: OBSPaths.cctvProfileINI)
    }

    static func templateFromUserProfile() -> INIFile {
        if let basic = OBSUserBasic.read(), let dir = basic.profileDir, dir != OBSPaths.cctvName,
           let ini = try? INIFile(contentsOf: OBSPaths.profiles.appendingPathComponent(dir).appendingPathComponent("basic.ini")) {
            var copy = ini
            // 스트리밍 계정/토큰 같은 남의 프로필 비밀은 가져오지 않는다
            for s in copy.sections where s == "YouTube" || s == "Auth" || s == "Twitch" || s.hasPrefix("YouTube - ") || s == "Panels" {
                copy.removeSection(s)
            }
            return copy
        }
        return INIFile(text: "[General]\nName=\(OBSPaths.cctvName)\n\n[Output]\nMode=Simple\n\n[Video]\nBaseCX=1920\nBaseCY=1080\nOutputCX=1920\nOutputCY=1080\nFPSType=0\nFPSCommon=60\n")
    }

    /// 처음 만들 때만 적용하는 녹화 기본값: 하드웨어 H.264, 고화질, 분할 MOV
    static func applyInitialDefaults(_ input: INIFile) -> INIFile {
        var ini = input
        if (ini.get("Output", "Mode") ?? "Simple") == "Simple" {
            ini.set("SimpleOutput", "RecQuality", "HQ")
            ini.set("SimpleOutput", "RecEncoder", "apple_h264")
            ini.set("SimpleOutput", "RecFormat2", "fragmented_mov")
            ini.set("SimpleOutput", "RecRB", "false")
        }
        ini.set("AdvOut", "RecFormat2", "fragmented_mov")
        return ini
    }

    static func applyManagedKeys(_ input: INIFile, recordingFolder: URL) -> INIFile {
        var ini = input
        ini.set("General", "Name", OBSPaths.cctvName)
        ini.set("Output", "FilenameFormatting", "%CCYY-%MM-%DD %hh-%mm-%ss")
        ini.set("SimpleOutput", "FilePath", recordingFolder.path)
        ini.set("AdvOut", "RecFilePath", recordingFolder.path)
        ini.set("AdvOut", "FFFilePath", recordingFolder.path)
        return ini
    }

    static func canvasSize() -> (Int, Int) {
        guard let ini = try? INIFile(contentsOf: OBSPaths.cctvProfileINI),
              let w = ini.get("Video", "BaseCX").flatMap(Int.init),
              let h = ini.get("Video", "BaseCY").flatMap(Int.init) else { return (1920, 1080) }
        return (w, h)
    }
}

// MARK: - CCTV 전용 장면 모음

struct OBSSceneOptions: Equatable {
    enum Capture: String { case application, display }
    var capture: Capture
    var gameAudio: Bool
    var mic: Bool
    var showCursor: Bool
}

enum OBSSceneWriter {
    static let sceneName = "WoW"
    static let videoSourceName = "WoW 화면"
    static let audioSourceName = "WoW 소리"
    static let micSourceName = "마이크"
    static let wowBundleID = "com.blizzard.worldofwarcraft"

    static func ensure(options: OBSSceneOptions) throws {
        let fm = FileManager.default
        var json: [String: Any]
        if let data = try? Data(contentsOf: OBSPaths.cctvSceneCollection),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = j
        } else {
            json = fresh(options: options)
        }
        json = patch(json, options: options)
        try fm.createDirectory(at: OBSPaths.scenes, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: OBSPaths.cctvSceneCollection, options: .atomic)
    }

    static func fresh(options: OBSSceneOptions) -> [String: Any] {
        let (w, h) = OBSProfileWriter.canvasSize()
        let videoUUID = UUID().uuidString.lowercased()
        let audioUUID = UUID().uuidString.lowercased()
        let sceneUUID = UUID().uuidString.lowercased()

        let sceneItem: [String: Any] = [
            "name": videoSourceName, "source_uuid": videoUUID, "id": 1,
            "visible": true, "locked": false, "rot": 0.0,
            "pos": ["x": 0.0, "y": 0.0], "scale": ["x": 1.0, "y": 1.0],
            "align": 5, "bounds_type": 2, "bounds_align": 0,
            "bounds": ["x": Double(w), "y": Double(h)], "bounds_crop": false,
            "crop_left": 0, "crop_top": 0, "crop_right": 0, "crop_bottom": 0,
            "scale_filter": "disable", "blend_method": "default", "blend_type": "normal",
            "show_transition": ["duration": 0], "hide_transition": ["duration": 0],
            "private_settings": [:] as [String: Any],
        ]

        // 오디오 소스는 장면 아이템이어야 믹서에 들어간다 (아니면 OBS 가 저장 시 버린다)
        let audioItem = audioSceneItem(uuid: audioUUID, id: 2)
        let scene = source(name: sceneName, id: "scene", uuid: sceneUUID, settings: [
            "id_counter": 2, "custom_size": false, "items": [sceneItem, audioItem],
        ])
        var video = source(name: videoSourceName, id: "screen_capture", uuid: videoUUID, settings: videoSettings(options))
        video["muted"] = true // 게임 소리는 별도 오디오 소스로 받는다 (이중 녹음 방지)
        let audio = source(name: audioSourceName, id: "sck_audio_capture", uuid: audioUUID, settings: [
            "type": 1, "application": wowBundleID,
        ])

        var json: [String: Any] = [
            "name": OBSPaths.cctvName,
            "version": 2,
            "canvases": [] as [Any],
            "current_scene": sceneName,
            "current_program_scene": sceneName,
            "scene_order": [["name": sceneName]],
            "transition_duration": 300,
            "transitions": [] as [Any],
            "resolution": ["x": w, "y": h],
            "sources": [scene, video, audio],
            "modules": [:] as [String: Any],
        ]
        if options.mic { json["AuxAudioDevice1"] = micSource() }
        return json
    }

    /// 기존 파일에서 우리가 관리하는 설정만 갱신 (사용자가 OBS 에서 손본 나머지는 유지)
    static func patch(_ input: [String: Any], options: OBSSceneOptions) -> [String: Any] {
        var json = input
        var sources = json["sources"] as? [[String: Any]] ?? []
        for i in sources.indices {
            switch sources[i]["name"] as? String {
            case videoSourceName:
                var settings = sources[i]["settings"] as? [String: Any] ?? [:]
                for (k, v) in videoSettings(options) { settings[k] = v }
                if options.capture == .application { settings.removeValue(forKey: "display_uuid") }
                sources[i]["settings"] = settings
            case audioSourceName:
                sources[i]["enabled"] = options.gameAudio
            default:
                break
            }
        }
        if !sources.contains(where: { $0["name"] as? String == audioSourceName }) {
            let audioUUID = UUID().uuidString.lowercased()
            var audio = source(name: audioSourceName, id: "sck_audio_capture", uuid: audioUUID, settings: [
                "type": 1, "application": wowBundleID,
            ])
            audio["enabled"] = options.gameAudio
            sources.append(audio)
            if let si = sources.firstIndex(where: { $0["id"] as? String == "scene" && $0["name"] as? String == sceneName }) {
                var settings = sources[si]["settings"] as? [String: Any] ?? [:]
                var items = settings["items"] as? [[String: Any]] ?? []
                let nextID = (settings["id_counter"] as? Int ?? items.count) + 1
                items.append(audioSceneItem(uuid: audioUUID, id: nextID))
                settings["items"] = items
                settings["id_counter"] = nextID
                sources[si]["settings"] = settings
            }
        }
        json["sources"] = sources
        if options.mic {
            if json["AuxAudioDevice1"] == nil {
                json["AuxAudioDevice1"] = micSource()
            } else if var aux = json["AuxAudioDevice1"] as? [String: Any] {
                // 마이크 장치는 앱 설정을 따른다 (기본: macOS 시스템 기본 입력 → AirPods 등으로 바꿔도 자동 추종)
                var st = aux["settings"] as? [String: Any] ?? [:]
                st["device_id"] = Prefs.micDevice
                aux["settings"] = st
                json["AuxAudioDevice1"] = aux
            }
        } else {
            json.removeValue(forKey: "AuxAudioDevice1")
        }
        return json
    }

    /// WoW 는 Metal 로 렌더링해서 macOS ScreenCaptureKit 의 창/앱 필터가 화면을 못 가져오는 경우가 많다
    /// (창 캡처는 "Invalid target window ID", 앱 캡처는 검은 화면). 그래서 항상 디스플레이 캡처를 쓰고,
    /// "WoW 창" 모드에선 앱이 WoW 창 영역만큼 프레임을 잘라내 1:1 로 만든다.
    static func videoSettings(_ o: OBSSceneOptions, windowID: Int? = nil) -> [String: Any] {
        ["show_cursor": o.showCursor, "hide_obs": true, "type": 0]
    }

    /// 사용자가 원래 OBS 에서 쓰던 마이크 장치 (기본 장면 모음의 마이크/Aux). 없으면 nil.
    static func audioSceneItem(uuid: String, id: Int) -> [String: Any] {
        [
            "name": audioSourceName, "source_uuid": uuid, "id": id,
            "visible": true, "locked": false, "rot": 0.0,
            "pos": ["x": 0.0, "y": 0.0], "scale": ["x": 1.0, "y": 1.0],
            "align": 5, "bounds_type": 0, "bounds_align": 0,
            "bounds": ["x": 0.0, "y": 0.0], "bounds_crop": false,
            "crop_left": 0, "crop_top": 0, "crop_right": 0, "crop_bottom": 0,
            "scale_filter": "disable", "blend_method": "default", "blend_type": "normal",
            "show_transition": ["duration": 0], "hide_transition": ["duration": 0],
            "private_settings": [:] as [String: Any],
        ]
    }

    static func micSource() -> [String: Any] {
        // 기본은 macOS 시스템 기본 입력("default"). 사용자가 설정/모니터에서 특정 장치를 고르면 그 UID.
        var m = source(name: micSourceName, id: "coreaudio_input_capture", uuid: UUID().uuidString.lowercased(), settings: ["device_id": Prefs.micDevice])
        m["filters"] = [[
            "name": "소음 억제", "id": "noise_suppress_filter_v2", "versioned_id": "noise_suppress_filter_v2",
            "enabled": true, "settings": ["method": "rnnoise"],
        ]]
        return m
    }

    static func source(name: String, id: String, uuid: String, settings: [String: Any]) -> [String: Any] {
        [
            "name": name, "id": id, "versioned_id": id, "uuid": uuid,
            "settings": settings, "mixers": 255, "volume": 1.0, "balance": 0.5,
            "enabled": true, "muted": false, "monitoring_type": 0, "sync": 0, "flags": 0,
            "deinterlace_mode": 0, "deinterlace_field_order": 0,
            "push-to-mute": false, "push-to-mute-delay": 0, "push-to-talk": false, "push-to-talk-delay": 0,
            "hotkeys": [:] as [String: Any], "private_settings": [:] as [String: Any], "filters": [] as [Any],
        ]
    }
}
