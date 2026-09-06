import AppKit
import Combine
import ServiceManagement

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

struct RunInfo {
    let dungeon: String
    let mapID: Int
    let level: Int
    let affixes: [Int]
    let startedAt: Date
    var bossesKilled = 0
    var lastBoss: String?
    var success: Bool?
    var durationMS: Int?
}

enum Phase: Equatable {
    case waitingForWoW
    case watching            // WoW 실행 중, 쐐기 대기
    case recording
    case finishing           // 쐐기 종료, 여유 시간 후 녹화 정지 예정
}

/// 앱의 두뇌. WoW 프로세스, 전투 로그, OBS 를 연결해 녹화를 제어한다.
@MainActor
final class RecordingCoordinator: ObservableObject {
    static let shared = RecordingCoordinator()

    static let wowBundleID = "com.blizzard.worldofwarcraft"
    static let obsBundleID = "com.obsproject.obs-studio"

    @Published private(set) var phase: Phase = .waitingForWoW
    @Published private(set) var wowRunning = false
    @Published private(set) var obsRunning = false
    @Published private(set) var obsState: OBSClient.State = .disconnected
    @Published private(set) var obsRecording = false
    @Published private(set) var currentRun: RunInfo?
    @Published private(set) var combatLogFile: URL?
    @Published private(set) var events: [LogEntry] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecordingPath: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let wowMonitor = ProcessMonitor(bundleID: wowBundleID)
    private let obsMonitor = ProcessMonitor(bundleID: obsBundleID)
    private var watcher: CombatLogWatcher?
    let obsManager = OBSManager()
    private var obs: OBSClient { obsManager.client }
    lazy var monitor = OBSMonitorModel(client: obsManager.client)
    private var stopTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var pendingRename: RunInfo?
    private var started = false
    private var hotKey: HotKey?
    private var obsRelaunches = 0
    /// 던전 이탈로 인한 정지 대기 중인지 (재입장하면 취소)
    private var leavePending = false
    private var testTask: Task<Void, Never>?
    @Published private(set) var testCountdown: Int = 0
    @Published private(set) var captureHint: String?

    private init() {
        Prefs.register()
    }

    var obsMode: OBSManager.Mode { obsManager.mode }

    // MARK: - 시작

    func start() {
        guard !started else { return }
        started = true
        log("Oh My WoW CCTV 시작")

        wireOBSClient()
        autoUpdateAddon()

        wowMonitor.onChange = { [weak self] running in self?.wowChanged(running) }
        obsMonitor.onChange = { [weak self] running in self?.obsChanged(running) }
        wowMonitor.start()
        obsMonitor.start()

        obsRunning = obsMonitor.isRunning
        if !obsRunning {
            // OBS 가 꺼져 있는 지금이 설정 파일을 준비하기 가장 안전한 때
            do { try obsManager.prepareFiles() } catch { log("OBS 설정 파일 준비 실패: \(error.localizedDescription)") }
        }
        wowChanged(wowMonitor.isRunning)
        updateHotKey()
        runSimulationIfRequested()
    }

    /// 동봉 애드온이 설치본보다 새 버전이면 자동으로 덮어쓴다 (WoW 는 다음 실행/리로드 때 반영)
    private func autoUpdateAddon() {
        guard AddonInstaller.isInstalled, AddonInstaller.needsUpdate else { return }
        do {
            try AddonInstaller.install()
            log("애드온 업데이트: v\(AddonInstaller.installedVersion ?? "?") (WoW 에서 /reload 하면 적용)")
        } catch {
            log("애드온 업데이트 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 단축키 / 효과음

    func updateHotKey() {
        hotKey = nil
        guard Prefs.hotkeyEnabled else { return }
        hotKey = HotKey(keyCode: HotKey.keyR, modifiers: HotKey.controlOptionCommand) { [weak self] in
            self?.log("단축키 ⌃⌥⌘R")
            self?.manualToggleRecording()
        }
        if hotKey == nil { log("전역 단축키 등록 실패 (다른 앱이 ⌃⌥⌘R 을 쓰고 있을 수 있음)") }
    }

    private func playSound(_ name: String) {
        guard Prefs.soundEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// 쐐기 없이 녹화 파이프라인을 확인한다: 녹화 시작 → N초 → 정지 → Finder 에서 파일 표시
    func runTestRecording() {
        guard testTask == nil, !obsRecording else { return }
        let seconds = Prefs.testRecordingSeconds
        log("녹화 테스트 시작 (\(seconds)초)")
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { self.testTask = nil; self.testCountdown = 0 }
            await self.startManualRecording()
            guard self.obsRecording else { self.log("녹화 테스트 실패: 녹화가 시작되지 않음"); return }
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self.testCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || !self.obsRecording { return }
            }
            await self.stopRecording(reason: "녹화 테스트 종료")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let path = self.lastRecordingPath, FileManager.default.fileExists(atPath: path) {
                self.log("녹화 테스트 완료 → \((path as NSString).lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                self.log("녹화 테스트: 파일을 찾지 못했습니다")
            }
        }
    }

    /// OBS 가 안 떠 있으면 띄우고 연결될 때까지 기다린 뒤 수동 녹화를 시작한다
    private func startManualRecording() async {
        if obsMode == .idle { await obsManager.activate() }
        let deadline = Date().addingTimeInterval(25)
        while obsState != .connected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        await startRecording(manual: true)
    }

    /// 개발용: WoW 없이 전체 흐름을 시험한다.
    /// CCTV_SIMULATE_WOW=1 이면 시작 직후 WoW 가 켜진 것으로, CCTV_SIMULATE_WOW_QUIT_AFTER=초 가 지나면 꺼진 것으로 취급한다.
    private func runSimulationIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["CCTV_SIMULATE_WOW"] == "1" else { return }
        log("[시뮬레이션] WoW 실행으로 간주")
        wowChanged(true)
        if let secs = env["CCTV_SIMULATE_WOW_QUIT_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                log("[시뮬레이션] WoW 종료로 간주")
                wowChanged(false)
            }
        }
    }

    private func wireOBSClient() {
        obsManager.onLog = { [weak self] m in self?.log(m) }
        obsManager.onCaptureHint = { [weak self] h in self?.captureHint = h }
        obs.onStateChange = { [weak self] s in
            guard let self else { return }
            self.obsState = s
            if s == .connected {
                self.syncRecordStatus()
                self.obsManager.startCaptureWatch(wowBundleID: Self.wowBundleID)
            } else {
                self.obsManager.stopCaptureWatch()
            }
        }
        obs.onLog = { [weak self] m in self?.log(m) }
        obs.onRecordStateChanged = { [weak self] rs in self?.recordStateChanged(rs) }
        obs.onEvent = { [weak self] type, data in self?.monitor.handleEvent(type, data) }
        monitor.onLog = { [weak self] m in self?.log(m) }
    }

    /// 미리보기/테스트용으로 OBS 를 지금 띄운다 (WoW 종료 시 또는 앱 종료 시 정리됨)
    func ensureOBS() {
        Task { await obsManager.activate() }
    }

    /// 앱 종료 직전: 우리가 띄운 OBS 는 같이 끈다 (메인 스레드를 잠깐 막고 동기적으로 처리)
    func shutdownForAppTermination() {
        guard obsMode == .launchedByUs else { return }
        log("앱 종료 → OBS 정리")
        if obsRecording {
            let client = obs
            let sem = DispatchSemaphore(value: 0)
            Task.detached { _ = try? await client.stopRecord(); sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        }
        obsManager.terminateSynchronously()
    }

    /// 설정이 바뀌었을 때 OBS 프로필/장면 파일을 다시 쓴다 (다음 OBS 실행부터 적용)
    func applyOBSSettings() {
        do {
            try obsManager.prepareFiles()
            log("OBS 프로필/장면 설정 갱신")
        } catch {
            log("OBS 설정 갱신 실패: \(error.localizedDescription)")
        }
    }

    func resetOBSFiles() {
        do { try obsManager.resetFiles() } catch { log("OBS 설정 초기화 실패: \(error.localizedDescription)") }
    }

    // MARK: - 프로세스 이벤트

    private func wowChanged(_ running: Bool) {
        guard running != wowRunning || !started else { return }
        wowRunning = running
        if running {
            log("WoW 실행 감지")
            obsRelaunches = 0
            startWatching()
            Task { await obsManager.activate() }
        } else {
            log("WoW 종료 감지")
            stopWatching()
            phase = .waitingForWoW
            Task {
                if obsRecording {
                    log("녹화 중 WoW 종료 → 녹화 정지")
                    stopTask?.cancel()
                    await stopRecording(reason: "WoW 종료")
                    // 파일 마무리 및 이름 변경 시간
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                await obsManager.deactivate()
            }
        }
    }

    private func obsChanged(_ running: Bool) {
        let was = obsRunning
        obsRunning = running
        if running {
            if !was { log("OBS 실행 감지 (\(obsMode == .launchedByUs ? "CCTV 가 띄움" : "외부 실행"))") }
            if started, !was { obsManager.processDidStart() }
        } else {
            if was { log("OBS 종료됨") }
            obsManager.processDidExit()
            obsRecording = false
            if phase == .recording || phase == .finishing {
                stopTask?.cancel()
                stopElapsedTimer()
                currentRun = nil
                phase = wowRunning ? .watching : .waitingForWoW
            }
            // WoW 가 아직 켜져 있는데 OBS 가 사라졌으면 다시 띄운다 (크래시/실수 종료 대비)
            if was, wowRunning, obsRelaunches < 3 {
                obsRelaunches += 1
                let n = obsRelaunches
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard self.wowRunning, !self.obsRunning else { return }
                    self.log("WoW 실행 중이라 OBS 를 다시 띄웁니다 (\(n)/3)")
                    await self.obsManager.activate()
                }
            }
        }
    }

    // MARK: - 전투 로그

    private func startWatching() {
        let logsURL = Prefs.wowLogsURL
        let w = CombatLogWatcher(logsDirectory: logsURL)
        w.onFileChange = { [weak self] url in
            self?.combatLogFile = url
            if let url { self?.log("전투 로그 파일: \(url.lastPathComponent)") }
        }
        w.onLine = { [weak self] line in self?.handleLogLine(line) }
        w.start()
        watcher = w
        phase = .watching
        log("전투 로그 감시 시작: \(logsURL.path)")
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        combatLogFile = nil
    }

    private func handleLogLine(_ line: String) {
        guard let event = CombatLogParser.parseEvent(line) else { return }
        switch event {
        case .challengeStart(let dungeon, let mapID, _, let level, let affixes):
            stopTask?.cancel()
            stopTask = nil
            leavePending = false
            if obsRecording, let run = currentRun, run.mapID == mapID, run.level == level {
                // 같은 쐐기가 진행 중 (재입장 등) → 같은 녹화를 계속
                phase = .recording
                log("쐐기 진행 중 재확인: \(dungeon) +\(level) → 녹화 계속")
                return
            }
            currentRun = RunInfo(dungeon: dungeon, mapID: mapID, level: level, affixes: affixes, startedAt: Date())
            log("쐐기 시작: \(dungeon) +\(level)")
            Task { await startRecording() }

        case .challengeEnd(let mapID, let success, let level, let durationMS):
            guard phase == .recording || (phase == .finishing && leavePending) else {
                log("쐐기 종료 감지(맵 \(mapID)) 했지만 녹화 중이 아님")
                return
            }
            leavePending = false
            currentRun?.success = success
            currentRun?.durationMS = durationMS
            let result = success ? "완료" : "실패"
            log("쐐기 종료: +\(level) \(result) (\(Self.format(ms: durationMS))) → \(Prefs.stopDelaySeconds)초 후 녹화 정지")
            scheduleStop(after: TimeInterval(Prefs.stopDelaySeconds), reason: "쐐기 \(result)")

        case .encounterStart(_, let name, _):
            if phase == .recording { log("우두머리 전투 시작: \(name)") }

        case .encounterEnd(_, let name, let success, _):
            guard phase == .recording else { return }
            if success {
                currentRun?.bossesKilled += 1
                currentRun?.lastBoss = name
                log("우두머리 처치: \(name) (\(currentRun?.bossesKilled ?? 0)번째)")
            } else {
                log("우두머리 전멸: \(name)")
            }

        case .zoneChange(let mapID, let name, let difficultyID):
            // 쐐기(8) 또는 시작 전 신화(23) 난이도의 같은 던전이면 '안', 그 외(야외 0 등)는 '밖'.
            // 바깥 지역이 던전과 같은 인스턴스 번호로 찍히는 경우가 있어 맵 번호만으로는 판정하지 않는다.
            guard let run = currentRun else { return }
            let insideRun = (difficultyID == 8 || difficultyID == 23) && mapID == run.mapID
            if insideRun {
                if phase == .finishing, leavePending {
                    stopTask?.cancel(); stopTask = nil
                    leavePending = false
                    phase = .recording
                    log("던전 재입장 (\(name)) → 녹화 계속")
                }
            } else if phase == .recording, Prefs.stopOnZoneLeave {
                leavePending = true
                let grace = Prefs.leaveGraceSeconds
                log("던전 이탈 (\(name), 난이도 \(difficultyID)) → \(grace)초 안에 돌아오지 않으면 녹화 정지")
                scheduleStop(after: TimeInterval(grace), reason: "던전 이탈")
            }
        }
    }

    private func scheduleStop(after seconds: TimeInterval, reason: String) {
        phase = .finishing
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopRecording(reason: reason)
        }
    }

    // MARK: - 녹화 제어

    func startRecording(manual: Bool = false) async {
        guard obsState == .connected else {
            log("녹화 시작 실패: OBS 미연결")
            return
        }
        do {
            try await obs.startRecord()
            phase = .recording
            obsRecording = true
            startElapsedTimer()
            playSound("Pop")
            if manual {
                currentRun = nil
                log("수동 녹화 시작")
            } else {
                log("🔴 녹화 시작")
            }
        } catch {
            log("녹화 시작 실패: \(error.localizedDescription)")
            playSound("Basso")
        }
    }

    func stopRecording(reason: String) async {
        stopTask?.cancel()
        stopTask = nil
        leavePending = false
        pendingRename = currentRun
        do {
            let path = try await obs.stopRecord()
            log("⏹ 녹화 정지 (\(reason))" + (path.map { " → \(($0 as NSString).lastPathComponent)" } ?? ""))
            lastRecordingPath = path
            playSound("Bottle")
        } catch {
            log("녹화 정지 실패: \(error.localizedDescription)")
        }
        stopElapsedTimer()
        obsRecording = false
        currentRun = nil
        phase = wowRunning ? .watching : .waitingForWoW
    }

    func manualToggleRecording() {
        Task {
            if obsRecording {
                testTask?.cancel()
                await stopRecording(reason: "수동")
            } else {
                await startManualRecording()
            }
        }
    }

    func refreshCapture() { obsManager.refreshCaptureNow(wowBundleID: Self.wowBundleID) }
    func applyMicDevice() { Task { await obsManager.ensureMicDevice(); await obsManager.applyMicGain() } }
    func applyMicGain() { Task { await obsManager.applyMicGain() } }
    @Published private(set) var micAutoFitting = false
    func autoFitMicGain() {
        guard !micAutoFitting else { return }
        micAutoFitting = true
        Task {
            _ = await obsManager.autoFitMicGain { [weak self] in self?.monitor.meters.peaks[OBSSceneWriter.micSourceName] }
            micAutoFitting = false
        }
    }
    func showOBS() { obsManager.showWindow() }
    func hideOBS() { obsManager.hideWindow() }

    private func syncRecordStatus() {
        Task {
            if let active = try? await obs.isRecording() {
                obsRecording = active
                if active, phase == .watching {
                    log("OBS 가 이미 녹화 중입니다 (외부에서 시작됨)")
                }
            }
        }
    }

    private func recordStateChanged(_ rs: OBSClient.RecordState) {
        switch rs.state {
        case "OBS_WEBSOCKET_OUTPUT_STARTED":
            obsRecording = true
            if phase == .watching { phase = .recording; startElapsedTimer(); log("OBS 녹화가 외부에서 시작됨") }
        case "OBS_WEBSOCKET_OUTPUT_STOPPED":
            obsRecording = false
            if phase == .recording || phase == .finishing {
                log("OBS 녹화가 외부에서 정지됨")
                stopTask?.cancel()
                stopElapsedTimer()
                currentRun = nil
                phase = wowRunning ? .watching : .waitingForWoW
            }
            if let path = rs.outputPath {
                lastRecordingPath = path
                if Prefs.renameRecordings, let run = pendingRename {
                    renameRecording(at: path, run: run)
                }
            }
            pendingRename = nil
        default:
            break
        }
    }

    private func renameRecording(at path: String, run: RunInfo) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var parts = [stem, Self.sanitize(run.dungeon), "+\(run.level)"]
        if let success = run.success { parts.append(success ? "완료" : "실패") }
        if let ms = run.durationMS { parts.append(Self.format(ms: ms)) }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(parts.joined(separator: " ")).appendingPathExtension(ext)
        guard newURL != url, !FileManager.default.fileExists(atPath: newURL.path) else { return }
        // OBS 가 파일 마무리를 끝낼 시간을 준다
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self?.lastRecordingPath = newURL.path
                self?.log("파일 이름 변경: \(newURL.lastPathComponent)")
            } catch {
                self?.log("파일 이름 변경 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 유틸

    private func startElapsedTimer() {
        elapsed = 0
        elapsedTimer?.invalidate()
        let start = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(start) }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OhMyWowCCTV.log")
    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    func log(_ message: String) {
        let now = Date()
        events.append(LogEntry(date: now, message: message))
        if events.count > 500 { events.removeFirst(events.count - 500) }
        NSLog("[CCTV] %@", message)
        Self.appendToLogFile("\(Self.logDateFormatter.string(from: now))  \(message)\n")
    }

    private static func appendToLogFile(_ line: String) {
        let url = logFileURL
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64), size > 2_000_000 {
            try? fm.removeItem(at: url) // 2MB 넘으면 새로 시작
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            log("로그인 시 자동 실행: \(launchAtLogin ? "켜짐" : "꺼짐")")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            log("로그인 항목 설정 실패: \(error.localizedDescription) (앱을 /Applications 에 넣고 다시 시도하세요)")
        }
    }

    static func format(ms: Int) -> String {
        let total = ms / 1000
        let m = total / 60, s = total % 60
        return String(format: "%d분%02d초", m, s)
    }

    static func format(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    var statusLine: String {
        switch phase {
        case .waitingForWoW: return "WoW 대기 중"
        case .watching: return "WoW 실행 중 · 쐐기 대기"
        case .recording:
            if let run = currentRun { return "녹화 중: \(run.dungeon) +\(run.level) (\(Self.format(seconds: elapsed)))" }
            if testCountdown > 0 { return "녹화 테스트 중 (\(testCountdown)초 남음)" }
            return "수동 녹화 중 (\(Self.format(seconds: elapsed)))"
        case .finishing: return leavePending ? "던전 이탈 · 돌아오지 않으면 녹화 정지" : "쐐기 종료 · 곧 녹화 정지"
        }
    }

    var menuBarImage: NSImage {
        let name: String
        var color: NSColor?
        switch phase {
        case .waitingForWoW: name = "video.slash"
        case .watching: name = "video"
        case .recording: name = "record.circle.fill"; color = .systemRed
        case .finishing: name = "record.circle"; color = .systemOrange
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "CCTV")!
        if let color {
            let tinted = img.withSymbolConfiguration(.init(paletteColors: [color])) ?? img
            tinted.isTemplate = false
            return tinted
        }
        img.isTemplate = true
        return img
    }
}
