import AppKit

/// OBS 를 "래핑"한다. CCTV 전용 프로필/장면으로 OBS 를 몰래 띄우고, 녹화를 제어하고, 끝나면 원래대로 돌려놓는다.
@MainActor
final class OBSManager {
    enum Mode: Equatable {
        case idle               // OBS 를 쓰지 않는 상태
        case launchedByUs       // 우리가 띄운 OBS
        case attachedExternal   // 사용자가 이미 켜 둔 OBS 에 붙음
    }

    static let bundleID = "com.obsproject.obs-studio"

    private(set) var mode: Mode = .idle
    let client: OBSClient
    var onLog: ((String) -> Void)?
    /// 모니터 창에 보여 줄 캡처 상태 안내 (nil 이면 정상)
    var onCaptureHint: ((String?) -> Void)?
    private var applying = false

    private static let savedBasicKey = "obsSavedUserBasic"
    private var savedUserBasic: OBSUserBasic? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.savedBasicKey) else { return nil }
            return try? JSONDecoder().decode(OBSUserBasic.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.savedBasicKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedBasicKey)
            }
        }
    }
    private var savedExternalProfile: String?
    private var savedExternalCollection: String?
    private var switchedExternal = false
    private var shuttingDown = false

    init() {
        client = OBSClient(config: OBSWebSocketConfig.load()?.clientConfig ?? OBSClient.Config(host: "127.0.0.1", port: 4455, password: ""))
    }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }
    var isRunning: Bool { runningApp != nil }

    private func log(_ s: String) { onLog?(s) }

    // MARK: - 설정 파일

    /// 프로필/장면 모음/웹소켓 설정을 준비한다. OBS 가 꺼져 있을 때 호출하는 게 가장 좋다.
    func prepareFiles() throws {
        let folder = Prefs.recordingFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try OBSProfileWriter.ensure(recordingFolder: folder)
        try OBSSceneWriter.ensure(options: Prefs.sceneOptions)
        if !isRunning {
            let ws = try OBSWebSocketConfig.ensureEnabled()
            if !ws.serverEnabled { log("경고: 웹소켓 설정을 켜지 못했습니다") }
        }
    }

    func resetFiles() throws {
        try? FileManager.default.removeItem(at: OBSPaths.cctvProfileDir)
        try? FileManager.default.removeItem(at: OBSPaths.cctvSceneCollection)
        try prepareFiles()
        log("OBS 프로필/장면을 새로 만들었습니다")
    }

    // MARK: - 시작 / 종료

    /// WoW 가 켜졌을 때. OBS 를 띄우거나(없으면), 이미 켜져 있으면 붙는다.
    func activate() async {
        guard mode == .idle else { return }
        if runningApp != nil {
            if OBSUserBasic.read()?.isCCTV == true {
                // 이전 CCTV 인스턴스가 띄워 둔 OBS → 우리 것으로 이어받는다
                rememberUserBasicIfNeeded()
                mode = .launchedByUs
                shuttingDown = false
                log("이전 CCTV 인스턴스가 띄운 OBS 를 이어받습니다")
                startClient()
                if !(await waitForConnection()), let app = runningApp {
                    log("이어받은 OBS 가 응답이 없어 강제 종료하고 다시 실행합니다")
                    client.stop()
                    let pid = app.processIdentifier
                    kill(pid, SIGKILL)
                    for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
                    mode = .idle
                    await activate()
                }
                return
            }
            mode = .attachedExternal
            log("OBS 가 이미 실행 중 → 기존 OBS 에 연결해 CCTV 프로필로 전환합니다")
            startClient()
            await switchExternalToCCTV()
            return
        }

        do {
            try prepareFiles()
        } catch {
            log("OBS 설정 파일 준비 실패: \(error.localizedDescription)")
        }

        rememberUserBasicIfNeeded()
        mode = .launchedByUs
        shuttingDown = false

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = Prefs.hideOBS
        config.arguments = [
            "--profile", OBSPaths.cctvName,
            "--collection", OBSPaths.cctvName,
            "--minimize-to-tray",
            "--disable-shutdown-check",
            "--disable-updater",
            "--disable-missing-files-check",
        ]
        log("OBS 실행 (프로필/장면: \(OBSPaths.cctvName))")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Prefs.obsAppURL, configuration: config)
            startClient()
        } catch {
            mode = .idle
            log("OBS 실행 실패: \(error.localizedDescription)")
        }
    }

    /// WoW 가 꺼졌을 때. 우리가 띄운 OBS 는 종료하고 사용자의 원래 프로필로 돌려놓는다.
    func deactivate(force: Bool = false) async {
        stopCaptureWatch()
        switch mode {
        case .idle:
            return
        case .attachedExternal:
            await switchExternalBack()
            client.stop()
            mode = .idle
        case .launchedByUs:
            guard force || Prefs.quitOBSWithWoW else {
                log("OBS 는 계속 켜 둡니다 (설정)")
                return
            }
            shuttingDown = true
            log("OBS 종료")
            client.stop()
            if let app = runningApp {
                let pid = app.processIdentifier
                app.terminate()
                // 정상 종료를 기다린다 (최대 10초), 안 끝나면 강제 종료
                for _ in 0..<20 where kill(pid, 0) == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if kill(pid, 0) == 0 {
                    log("OBS 가 10초 안에 종료되지 않아 강제 종료합니다")
                    kill(pid, SIGKILL)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            restoreUserBasic()
            mode = .idle
        }
    }

    /// 앱 종료 시: 우리가 띄운 OBS 를 종료하고 설정을 원복한다. 메인 스레드를 최대 8초 막는다.
    func terminateSynchronously() {
        guard mode == .launchedByUs else { return }
        shuttingDown = true
        client.stop()
        if let app = runningApp {
            let pid = app.processIdentifier
            app.terminate()
            let deadline = Date().addingTimeInterval(8)
            while kill(pid, 0) == 0, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if kill(pid, 0) == 0 {
                log("OBS 가 8초 안에 종료되지 않아 강제 종료합니다")
                kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.5)
            }
            Thread.sleep(forTimeInterval: 0.8) // OBS 가 user.ini 를 쓸 시간
        }
        restoreUserBasic()
        mode = .idle
    }

    /// OBS 프로세스가 사라졌을 때 (사용자가 직접 껐거나 크래시)
    func processDidExit() {
        client.stop()
        stopCaptureWatch()
        guard mode != .idle else { return }
        if mode == .launchedByUs, !shuttingDown {
            log("OBS 가 예기치 않게 종료됨")
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                restoreUserBasic()
            }
        }
        mode = .idle
    }

    /// OBS 프로세스가 나타났을 때 (우리가 띄운 것이든 아니든 웹소켓 연결)
    func processDidStart() {
        startClient()
    }

    private func startClient() {
        let cfg = OBSWebSocketConfig.load()?.clientConfig ?? OBSClient.Config(host: "127.0.0.1", port: 4455, password: "")
        client.start(config: cfg)
    }

    /// 사용자의 원래 프로필/장면을 기억한다. CCTV 를 가리키는 값은 원본으로 저장하지 않는다.
    private func rememberUserBasicIfNeeded() {
        if let saved = savedUserBasic, !saved.isCCTV { return }
        if let current = OBSUserBasic.read(), !current.isCCTV {
            savedUserBasic = current
        } else if let fallback = OBSUserBasic.fallbackNonCCTV() {
            savedUserBasic = fallback
            log("원래 OBS 프로필을 알 수 없어 '\(fallback.profile ?? "?")' 을 복원 대상으로 잡습니다")
        }
    }

    private func restoreUserBasic() {
        if let saved = savedUserBasic, saved.isCCTV { savedUserBasic = nil }
        if savedUserBasic == nil, OBSUserBasic.read()?.isCCTV == true { savedUserBasic = OBSUserBasic.fallbackNonCCTV() }
        guard let saved = savedUserBasic else { return }
        let current = OBSUserBasic.read()
        if current?.isCCTV == true || current == nil {
            do {
                try saved.write()
                log("OBS 기본 프로필/장면을 원래대로 복원: \(saved.profile ?? "?") / \(saved.sceneCollection ?? "?")")
            } catch {
                log("OBS 설정 복원 실패: \(error.localizedDescription)")
            }
        }
        savedUserBasic = nil
    }

    // MARK: - 외부 OBS 전환

    private func waitForConnection(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if client.state == .connected { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return client.state == .connected
    }

    private func switchExternalToCCTV() async {
        guard await waitForConnection() else {
            log("OBS 웹소켓에 연결하지 못했습니다")
            if OBSUserBasic.read()?.isCCTV == true, let app = runningApp {
                // 우리가 띄웠던 OBS 가 응답이 없다 (종료 중 멈춤 등) → 강제 종료하고 새로 띄운다
                log("응답 없는 CCTV OBS 를 강제 종료하고 다시 실행합니다")
                client.stop()
                let pid = app.processIdentifier
                kill(pid, SIGKILL)
                for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
                mode = .idle
                await activate()
            }
            return
        }
        do {
            let stream = try await client.request("GetStreamStatus")
            if stream["outputActive"] as? Bool == true {
                log("OBS 가 방송 중이라 프로필을 바꾸지 않고 현재 장면을 그대로 녹화합니다")
                return
            }
            try prepareFiles()
            let profiles = try await client.request("GetProfileList")
            let collections = try await client.request("GetSceneCollectionList")
            savedExternalProfile = profiles["currentProfileName"] as? String
            savedExternalCollection = collections["currentSceneCollectionName"] as? String
            if savedExternalProfile != OBSPaths.cctvName {
                _ = try await client.request("SetCurrentProfile", data: ["profileName": OBSPaths.cctvName])
            }
            if savedExternalCollection != OBSPaths.cctvName {
                _ = try await client.request("SetCurrentSceneCollection", data: ["sceneCollectionName": OBSPaths.cctvName])
            }
            switchedExternal = true
            log("OBS 를 CCTV 프로필/장면으로 전환")
        } catch {
            log("OBS 프로필 전환 실패: \(error.localizedDescription)")
        }
    }

    private func switchExternalBack() async {
        guard switchedExternal, client.state == .connected else { return }
        do {
            if let p = savedExternalProfile, p != OBSPaths.cctvName {
                _ = try await client.request("SetCurrentProfile", data: ["profileName": p])
            }
            if let c = savedExternalCollection, c != OBSPaths.cctvName {
                _ = try await client.request("SetCurrentSceneCollection", data: ["sceneCollectionName": c])
            }
            log("OBS 를 원래 프로필/장면으로 되돌림")
        } catch {
            log("OBS 프로필 복원 실패: \(error.localizedDescription)")
        }
        switchedExternal = false
    }

    // MARK: - 캡처 대상 갱신

    private enum CaptureKind { case window, display }
    private var captureWatchTask: Task<Void, Never>?
    private var appliedSignature: String?
    private var appliedKind: CaptureKind = .display
    /// 창 캡처가 프레임을 못 주는(독점 전체 화면 등) 창 서명은 디스플레이 캡처로 대체한다
    private var fallbackSignatures = Set<String>()
    private var zeroFrameTicks = 0
    private var lastCanvas: (Int, Int)?

    /// WoW 창을 찾아 캡처를 맞추고, 창이 바뀌거나 다른 디스플레이로 옮겨가면 다시 적용한다.
    /// 창 캡처가 프레임을 못 받으면(로그인 화면 잠깐, 독점 전체 화면) 디스플레이 캡처로 자동 대체한다.
    func startCaptureWatch(wowBundleID: String) {
        stopCaptureWatch()
        captureWatchTask = Task { [weak self] in
            var waitedForWindow = false
            var micChecked = false
            while !Task.isCancelled {
                guard let self else { return }
                if self.client.state == .connected {
                    if !micChecked { micChecked = true; await self.ensureMicDevice() }
                    if let info = WoWWindowLocator.find(bundleID: wowBundleID) {
                        waitedForWindow = false
                        if info.signature != self.appliedSignature {
                            await self.refreshCapture(info, reason: self.appliedSignature == nil ? "WoW 창 확인" : "WoW 창 변경")
                            try? await Task.sleep(nanoseconds: 1_200_000_000) // 소스가 프레임/크기를 보고할 시간
                        }
                        if Prefs.fitCanvasToWindow { await self.fitCanvasToSource(window: info) }
                        await self.selfHealIfNoFrames(info)
                    } else if !waitedForWindow {
                        waitedForWindow = true
                        self.log("WoW 창이 뜨기를 기다리는 중…")
                        self.onCaptureHint?("WoW 게임 창을 아직 찾지 못했습니다. 캐릭터 선택/게임 화면이 뜨면 자동으로 잡습니다.")
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopCaptureWatch() {
        captureWatchTask?.cancel()
        captureWatchTask = nil
        appliedSignature = nil
        fallbackSignatures.removeAll()
        zeroFrameTicks = 0
    }

    /// 지금 당장 캡처 대상을 다시 잡는다 (모니터 창의 캡처 전환/다시 잡기 버튼)
    func refreshCaptureNow(wowBundleID: String) {
        Task { [weak self] in
            guard let self else { return }
            if let info = WoWWindowLocator.find(bundleID: wowBundleID) {
                self.fallbackSignatures.remove(info.signature) // 수동 요청은 창 캡처부터 다시 시도
                await self.refreshCapture(info, reason: "수동 갱신")
            } else {
                await self.applyCaptureSettings(window: nil, reason: "수동 갱신 (WoW 창 없음)")
            }
        }
    }

    private func sourceSize() async -> (Int, Int)? {
        guard let items = try? await client.request("GetSceneItemList", data: ["sceneName": OBSSceneWriter.sceneName], timeout: 3),
              let list = items["sceneItems"] as? [[String: Any]],
              let vid = list.first(where: { $0["sourceName"] as? String == OBSSceneWriter.videoSourceName }),
              let itemID = vid["sceneItemId"] as? Int,
              let t = try? await client.request("GetSceneItemTransform", data: ["sceneName": OBSSceneWriter.sceneName, "sceneItemId": itemID], timeout: 3),
              let tr = t["sceneItemTransform"] as? [String: Any],
              let sw = tr["sourceWidth"] as? Double, let sh = tr["sourceHeight"] as? Double else { return nil }
        return (Int(sw), Int(sh))
    }

    /// 창 캡처인데 소스가 프레임을 안 주면(0 크기) 디스플레이 캡처로 대체한다
    private func selfHealIfNoFrames(_ info: WoWWindowInfo) async {
        guard appliedKind == .window else { zeroFrameTicks = 0; return }
        let sz = await sourceSize()
        if let sz, sz.0 >= 100, sz.1 >= 100 { zeroFrameTicks = 0; return }
        zeroFrameTicks += 1
        if zeroFrameTicks >= 2 {
            zeroFrameTicks = 0
            fallbackSignatures.insert(info.signature)
            log("창 캡처가 프레임을 못 받아 디스플레이 캡처로 대체합니다 (전체 화면 모드일 수 있음)")
            await refreshCapture(info, reason: "대체")
        }
    }

    // MARK: 마이크

    /// 마이크가 '기본 장치'로 잡혀 있고 사용자가 OBS 에서 쓰던 마이크가 따로 있으면 그 장치로 바꾼다
    func ensureMicDevice() async {
        guard Prefs.sceneOptions.mic, let user = OBSSceneWriter.userMicDeviceID() else { return }
        let mic = OBSSceneWriter.micSourceName
        guard let r = try? await client.request("GetInputSettings", data: ["inputName": mic], timeout: 3),
              let st = r["inputSettings"] as? [String: Any],
              (st["device_id"] as? String ?? "default") == "default" else { return }
        do {
            _ = try await client.request("SetInputSettings", data: ["inputName": mic, "inputSettings": ["device_id": user], "overlay": true])
            log("마이크를 OBS 에서 쓰던 장치로 설정: \(user.split(separator: ":").dropFirst(2).first.map(String.init) ?? user)")
        } catch {
            log("마이크 장치 설정 실패: \(error.localizedDescription)")
        }
    }

    // MARK: 캔버스 맞춤

    /// 캔버스/출력 해상도와 크롭을 캡처 소스에 맞춘다.
    /// - 창 캡처: 소스 = 창(제목 표시줄 포함) → 제목 표시줄만 잘라낸다.
    /// - 디스플레이 캡처(창 모드): 디스플레이에서 WoW 창 영역만 잘라낸다.
    /// - 디스플레이 캡처(전체 화면/디스플레이 고정): 소스 전체.
    func fitCanvasToSource(window info: WoWWindowInfo?) async {
        guard client.state == .connected else { return }
        let scene = OBSSceneWriter.sceneName
        do {
            let items = try await client.request("GetSceneItemList", data: ["sceneName": scene], timeout: 3)
            guard let list = items["sceneItems"] as? [[String: Any]],
                  let vid = list.first(where: { $0["sourceName"] as? String == OBSSceneWriter.videoSourceName }),
                  let itemID = vid["sceneItemId"] as? Int else { return }
            let t = try await client.request("GetSceneItemTransform", data: ["sceneName": scene, "sceneItemId": itemID], timeout: 3)
            guard let tr = t["sceneItemTransform"] as? [String: Any],
                  let swD = tr["sourceWidth"] as? Double, let shD = tr["sourceHeight"] as? Double,
                  swD >= 320, shD >= 240 else { return }
            let sw = Int(swD), sh = Int(shD)

            var cropL = 0, cropT = 0, cropR = 0, cropB = 0
            var w = sw, h = sh

            if appliedKind == .window {
                // 소스가 창 전체(제목 표시줄 포함). 제목 표시줄만 위에서 잘라낸다.
                let titleBar = Prefs.cropTitleBar ? min(info?.titleBarPixels ?? 0, sh / 4) : 0
                cropT = titleBar
                h = sh - titleBar
            } else if Prefs.sceneOptions.capture == .application, let info, !info.isFullscreenSized,
                      let r = info.pixelRectInDisplay, abs(sw - r.displayW) <= 2, abs(sh - r.displayH) <= 2 {
                // 디스플레이 캡처를 WoW 창 영역만큼 잘라낸다
                let titleBar = Prefs.cropTitleBar ? min(info.titleBarPixels, r.h / 4) : 0
                cropL = r.x; cropT = r.y + titleBar
                w = r.w; h = r.h - titleBar
            } else if Prefs.sceneOptions.capture == .application {
                // 디스플레이 캡처인데 아직 창 크기 정보가 안 맞으면 다음 틱에
                if info != nil, !(info!.isFullscreenSized) { return }
            }

            w &= ~1; h &= ~1
            cropR = sw - cropL - w
            cropB = sh - cropT - h
            guard w >= 320, h >= 240, cropR >= 0, cropB >= 0 else { return }

            let vs = try await client.request("GetVideoSettings", timeout: 3)
            let cur = (vs["baseWidth"] as? Int ?? 0, vs["baseHeight"] as? Int ?? 0, vs["outputWidth"] as? Int ?? 0, vs["outputHeight"] as? Int ?? 0)
            var changedCanvas = false
            if cur != (w, h, w, h) {
                let rs = try await client.request("GetRecordStatus", timeout: 3)
                if rs["outputActive"] as? Bool == true { return } // 녹화 중엔 해상도 변경 불가
                _ = try await client.request("SetVideoSettings", data: ["baseWidth": w, "baseHeight": h, "outputWidth": w, "outputHeight": h])
                changedCanvas = true
            }

            let bw = Int(tr["boundsWidth"] as? Double ?? 0), bh = Int(tr["boundsHeight"] as? Double ?? 0)
            let px = tr["positionX"] as? Double ?? -1, py = tr["positionY"] as? Double ?? -1
            let cl = tr["cropLeft"] as? Int ?? -1, ct = tr["cropTop"] as? Int ?? -1
            let cr = tr["cropRight"] as? Int ?? -1, cb = tr["cropBottom"] as? Int ?? -1
            if changedCanvas || bw != w || bh != h || px != 0 || py != 0 || cl != cropL || ct != cropT || cr != cropR || cb != cropB {
                _ = try await client.request("SetSceneItemTransform", data: [
                    "sceneName": scene, "sceneItemId": itemID,
                    "sceneItemTransform": [
                        "positionX": 0, "positionY": 0, "rotation": 0, "alignment": 5,
                        "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsAlignment": 0,
                        "boundsWidth": w, "boundsHeight": h,
                        "cropLeft": cropL, "cropTop": cropT, "cropRight": cropR, "cropBottom": cropB,
                    ],
                ])
            }
            if changedCanvas, lastCanvas.map({ $0 != (w, h) }) ?? true {
                lastCanvas = (w, h)
                log("녹화 해상도를 창 크기에 맞춤: \(w)x\(h)")
            }
        } catch {
            log("해상도 맞춤 실패: \(error.localizedDescription)")
        }
    }

    private func refreshCapture(_ info: WoWWindowInfo, reason: String) async {
        await applyCaptureSettings(window: info, reason: reason)
        appliedSignature = info.signature
    }

    private func applyCaptureSettings(window: WoWWindowInfo?, reason: String) async {
        guard client.state == .connected, !applying else { return }
        applying = true
        defer { applying = false }
        let opts = Prefs.sceneOptions
        let video = OBSSceneWriter.videoSourceName
        let audio = OBSSceneWriter.audioSourceName
        let bundle = OBSSceneWriter.wowBundleID
        let useWindow = opts.capture == .application && window != nil && !fallbackSignatures.contains(window!.signature)
        do {
            if useWindow, let w = window {
                // 진짜 창 캡처. 낡은 창 ID 로 멈춘 스트림을 확실히 새로 잡으려고 window 를 0 으로 뒀다 다시 넣는다.
                _ = try await client.request("SetInputSettings", data: ["inputName": video, "inputSettings": ["type": 1, "window": 0], "overlay": true])
                try? await Task.sleep(nanoseconds: 250_000_000)
                _ = try await client.request("SetInputSettings", data: [
                    "inputName": video,
                    "inputSettings": ["type": 1, "window": w.windowID, "show_empty_names": false, "show_hidden_windows": true, "show_cursor": opts.showCursor, "hide_obs": true],
                    "overlay": true,
                ])
                appliedKind = .window
                log("캡처 대상 갱신 (\(reason)): WoW 창 \(Int(w.bounds.width))x\(Int(w.bounds.height)) · 창 캡처 (id \(w.windowID))")
                onCaptureHint?(nil)
            } else {
                // 디스플레이 캡처 (디스플레이 고정 모드, 또는 창 캡처 대체)
                var final: [String: Any] = ["show_cursor": opts.showCursor, "hide_obs": true, "type": 0]
                if let uuid = window?.displayUUID { final["display_uuid"] = uuid }
                _ = try await client.request("SetInputSettings", data: ["inputName": video, "inputSettings": final, "overlay": true])
                appliedKind = .display
                let why = (opts.capture == .application) ? "디스플레이 캡처 + 창 영역 크롭 (창 캡처 대체)" : "디스플레이 캡처"
                if let w = window {
                    log("캡처 대상 갱신 (\(reason)): WoW 창 \(Int(w.bounds.width))x\(Int(w.bounds.height)) · \(why)")
                } else {
                    log("캡처 설정 적용 (\(reason))")
                }
                onCaptureHint?(opts.capture == .application ? "창 캡처가 안 돼 디스플레이를 잘라 녹화합니다. WoW 그래픽을 '창(모드)' 로 두면 창만 정확히 잡힙니다." : nil)
            }

            // 오디오는 처음 한 번만 다시 잡는다 (매번 하면 소리가 끊긴다)
            if appliedSignature == nil {
                _ = try await client.request("SetInputSettings", data: ["inputName": audio, "inputSettings": ["type": 0], "overlay": true])
                try? await Task.sleep(nanoseconds: 300_000_000)
                _ = try await client.request("SetInputSettings", data: ["inputName": audio, "inputSettings": ["type": 1, "application": bundle], "overlay": true])
            }
            await fitCanvasToSource(window: window)
        } catch {
            log("캡처 대상 갱신 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 창 보이기/숨기기

    func showWindow() {
        guard let app = runningApp else { return }
        app.unhide()
        app.activate()
    }

    func hideWindow() {
        runningApp?.hide()
    }
}
