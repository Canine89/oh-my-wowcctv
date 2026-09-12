import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var c: RecordingCoordinator

    @AppStorage(Prefs.Key.wowRetailPath) private var wowRetailPath = "/Applications/World of Warcraft/_retail_"
    @AppStorage(Prefs.Key.obsAppPath) private var obsAppPath = "/Applications/OBS.app"
    @AppStorage(Prefs.Key.recordingFolder) private var recordingFolder = ""
    @AppStorage(Prefs.Key.captureMode) private var captureMode = "application"
    @AppStorage(Prefs.Key.gameAudio) private var gameAudio = true
    @AppStorage(Prefs.Key.micEnabled) private var micEnabled = true
    @AppStorage(Prefs.Key.showCursor) private var showCursor = true
    @AppStorage(Prefs.Key.hideOBS) private var hideOBS = true
    @AppStorage(Prefs.Key.quitOBSWithWoW) private var quitOBSWithWoW = true
    @AppStorage(Prefs.Key.stopDelaySeconds) private var stopDelaySeconds = 5
    @AppStorage(Prefs.Key.renameRecordings) private var renameRecordings = true
    @AppStorage(Prefs.Key.stopOnZoneLeave) private var stopOnZoneLeave = true
    @AppStorage(Prefs.Key.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(Prefs.Key.soundEnabled) private var soundEnabled = true
    @AppStorage(Prefs.Key.testRecordingSeconds) private var testRecordingSeconds = 15
    @AppStorage(Prefs.Key.fitCanvasToWindow) private var fitCanvasToWindow = true
    @AppStorage(Prefs.Key.cropTitleBar) private var cropTitleBar = true
    @AppStorage(Prefs.Key.previewFPS) private var previewFPS = 30
    @AppStorage(Prefs.Key.leaveGraceSeconds) private var leaveGraceSeconds = 30
    @AppStorage(Prefs.Key.micDevice) private var micDevice = "default"
    @AppStorage(Prefs.Key.micGainDb) private var micGainDb = 0
    @AppStorage(Prefs.Key.voiceChatEnabled) private var voiceChatEnabled = true
    @AppStorage(Prefs.Key.voiceChatApp) private var voiceChatApp = VoiceChatApps.defaultBundleID()
    @State private var voiceApps: [VoiceChatApps.App] = []
    @State private var inputDevices: [AudioInputDevices.Device] = []

    @State private var addonMessage = ""

    var body: some View {
        Form {
            Section("WoW") {
                TextField("리테일 폴더 (_retail_)", text: $wowRetailPath)
                LabeledContent("전투 로그 폴더") {
                    Text(Prefs.wowLogsURL.path).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("애드온") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addonStatus)
                        HStack {
                            Button(AddonInstaller.isInstalled ? "애드온 다시 설치" : "애드온 설치") {
                                do {
                                    try AddonInstaller.install()
                                    addonMessage = "설치 완료. WoW 를 재시작하거나 /reload 하세요."
                                    c.log("애드온 설치됨: \(AddonInstaller.installedURL.path)")
                                } catch {
                                    addonMessage = "실패: \(error.localizedDescription)"
                                }
                            }
                            if AddonInstaller.isInstalled {
                                Button("폴더 열기") {
                                    NSWorkspace.shared.activateFileViewerSelecting([AddonInstaller.installedURL])
                                }
                            }
                        }
                        if !addonMessage.isEmpty { Text(addonMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                HStack {
                    TextField("녹화 저장 폴더", text: $recordingFolder)
                    Button("선택…") { chooseFolder() }
                }
                Picker("캡처 대상", selection: $captureMode) {
                    Text("WoW 창만").tag("application")
                    Text("주 디스플레이 전체").tag("display")
                }
                Toggle("게임 소리 녹음", isOn: $gameAudio)
                Toggle("마이크 녹음", isOn: $micEnabled)
                if micEnabled {
                    Picker("마이크 장치", selection: $micDevice) {
                        Text(AudioInputDevices.displayName(for: "default")).tag("default")
                        ForEach(inputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
                        if micDevice != "default", !inputDevices.contains(where: { $0.uid == micDevice }) {
                            Text("(연결 안 됨) \(micDevice)").tag(micDevice)
                        }
                    }
                    .onAppear { inputDevices = AudioInputDevices.list() }
                    .onChange(of: micDevice) { _, _ in c.applyOBSSettings(); c.applyMicDevice() }
                    Text("'시스템 기본' 은 macOS 사운드 설정의 입력 장치를 따라갑니다 (AirPods 를 끼면 AirPods, 빼면 다음 장치).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("마이크 증폭 +\(micGainDb) dB")
                        Slider(value: Binding(get: { Double(micGainDb) }, set: { micGainDb = Int($0.rounded()) }), in: 0...30, step: 1)
                            .onChange(of: micGainDb) { _, _ in c.applyOBSSettings(); c.applyMicGain() }
                    }
                    Text("원래 OBS 에서 마이크에 걸어 둔 필터(게이트·억제·컴프레서·리미터)를 그대로 가져오고, 이 앱은 그 앞에 증폭만 더합니다. 증폭이 앞에 있어야 게이트가 열립니다. CCTV 모니터의 '자동 맞춤'으로 말하면서 값을 정할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("친구 음성 녹음 (디스코드 등 통화 앱 소리)", isOn: $voiceChatEnabled)
                    .onChange(of: voiceChatEnabled) { _, _ in c.applyOBSSettings(); c.applyVoiceChat() }
                if voiceChatEnabled {
                    Picker("음성 앱", selection: $voiceChatApp) {
                        ForEach(voiceApps, id: \.bundleID) { a in Text(a.name).tag(a.bundleID) }
                        if !voiceApps.contains(where: { $0.bundleID == voiceChatApp }) {
                            Text(VoiceChatApps.displayName(for: voiceChatApp)).tag(voiceChatApp)
                        }
                    }
                    .onAppear { voiceApps = VoiceChatApps.installed() }
                    .onChange(of: voiceChatApp) { _, _ in c.applyOBSSettings(); c.applyVoiceChat() }
                    Text("그 앱에서 나오는 소리만 따로 잡습니다. 내 목소리는 마이크로, 게임 소리는 WoW 소리로 들어가서 셋이 자연스럽게 합쳐집니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("마우스 커서 표시", isOn: $showCursor)
                Toggle("녹화 해상도를 WoW 창 크기에 자동으로 맞춤 (검은 띠 없음)", isOn: $fitCanvasToWindow)
                Toggle("창 모드일 때 macOS 제목 표시줄 잘라내기", isOn: $cropTitleBar)
                HStack {
                    Button("설정을 OBS 프로필에 적용") { c.applyOBSSettings() }
                    Button("OBS 프로필/장면 초기화") { c.resetOBSFiles() }
                    Spacer()
                    if c.obsRunning { Button("OBS 창 열기") { c.showOBS() } }
                }
                Text("인코더·화질·마이크 장치 같은 세부 설정은 'OBS 창 열기'로 OBS 에서 직접 바꾸면 CCTV 프로필에 그대로 저장됩니다. 캡처 대상/오디오 변경은 다음 OBS 실행부터 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("녹화 (CCTV 전용 OBS 프로필)")
            }

            Section("OBS 동작") {
                TextField("OBS 앱 경로", text: $obsAppPath)
                Toggle("OBS 창 숨긴 채로 실행", isOn: $hideOBS)
                Toggle("WoW 종료 시 OBS 도 종료", isOn: $quitOBSWithWoW)
                LabeledContent("상태") { Text(obsStatus).foregroundStyle(.secondary) }
            }

            Section("녹화 타이밍") {
                Stepper("쐐기 종료 후 \(stopDelaySeconds)초 더 녹화", value: $stopDelaySeconds, in: 0...120, step: 5)
                Toggle("녹화 파일 이름에 던전·단수·결과 붙이기", isOn: $renameRecordings)
                Toggle("녹화 중 던전을 벗어나면 녹화 정지", isOn: $stopOnZoneLeave)
                if stopOnZoneLeave {
                    Stepper("던전을 나간 뒤 \(leaveGraceSeconds)초 안에 돌아오지 않으면 정지", value: $leaveGraceSeconds, in: 5...300, step: 5)
                }
            }

            Section("테스트 · 알림") {
                Toggle("전역 단축키 ⌃⌥⌘R 로 녹화 시작/정지 (게임 중에도 동작)", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, _ in c.updateHotKey() }
                Toggle("녹화 시작/정지 효과음", isOn: $soundEnabled)
                Stepper("녹화 테스트 길이 \(testRecordingSeconds)초", value: $testRecordingSeconds, in: 3...120, step: 1)
                Button("지금 녹화 테스트") { c.runTestRecording() }
                    .disabled(c.obsRecording)
                Picker("CCTV 모니터 미리보기 fps", selection: $previewFPS) {
                    Text("15").tag(15); Text("30").tag(30); Text("60").tag(60)
                }
                .pickerStyle(.segmented)
                Text("게임을 켠 뒤 ⌃⌥⌘R 을 누르면 바로 녹화가 시작되고(효과음 '팝'), 다시 누르면 멈춥니다(효과음 '병'). 쐐기 없이도 화면·소리가 제대로 잡히는지 확인할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("일반") {
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { c.launchAtLogin },
                    set: { c.setLaunchAtLogin($0) }
                ))
                LabeledContent("버전") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 780)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.recordingFolderURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            recordingFolder = url.path
            c.applyOBSSettings()
        }
    }

    private var addonStatus: String {
        let bundled = AddonInstaller.bundledVersion ?? "?"
        if AddonInstaller.isInstalled {
            let installed = AddonInstaller.installedVersion ?? "?"
            return AddonInstaller.needsUpdate ? "설치됨 v\(installed) → 업데이트 가능 v\(bundled)" : "설치됨 v\(installed)"
        }
        return "미설치 (동봉 버전 v\(bundled))"
    }

    private var obsStatus: String {
        if !c.obsRunning { return "OBS 꺼짐" }
        let who = c.obsMode == .launchedByUs ? "CCTV 가 실행함" : "사용자가 실행함"
        switch c.obsState {
        case .connected: return "연결됨 · \(who)"
        case .connecting: return "연결 중 · \(who)"
        case .disconnected: return "미연결 · \(who)"
        }
    }
}
