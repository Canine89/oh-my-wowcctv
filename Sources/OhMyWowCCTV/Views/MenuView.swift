import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var c: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(c.statusLine)
        Text("OBS: " + obsLine)
        if let file = c.combatLogFile {
            Text("전투 로그: \(file.lastPathComponent)")
        } else if c.wowRunning {
            Text("전투 로그: 아직 없음 (던전 입장 시 애드온이 켬)")
        }
        if let run = c.currentRun, run.bossesKilled > 0 {
            Text("처치한 우두머리: \(run.bossesKilled)")
        }

        Divider()

        Button("CCTV 모니터 열기 (지금 찍는 화면 보기)…") {
            openWindow(id: "monitor")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("m")

        Divider()

        Button(c.obsRecording ? "녹화 정지" : "녹화 시작 (수동)") {
            c.manualToggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.control, .option, .command])
        Button("녹화 테스트 (\(Prefs.testRecordingSeconds)초 녹화 후 파일 열기)") {
            openWindow(id: "monitor")
            NSApp.activate(ignoringOtherApps: true)
            c.runTestRecording()
        }
        .disabled(c.obsRecording)

        if let last = c.lastRecordingPath {
            Button("마지막 녹화 파일 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: last)])
            }
        }
        Button("녹화 폴더 열기") {
            NSWorkspace.shared.open(Prefs.recordingFolderURL)
        }

        Divider()

        if c.obsRunning {
            Button("OBS 창 보기 (장면 조정)") { c.showOBS() }
            Button("OBS 창 숨기기") { c.hideOBS() }
        }

        Button("이벤트 로그…") {
            openWindow(id: "eventLog")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("설정…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var obsLine: String {
        if !c.obsRunning { return "꺼짐 (WoW 실행 시 자동으로 켬)" }
        let who = c.obsMode == .launchedByUs ? "CCTV 가 실행" : "사용자가 실행"
        switch c.obsState {
        case .connected: return (c.obsRecording ? "녹화 중" : "준비됨") + " · \(who)"
        case .connecting: return "연결 중… · \(who)"
        case .disconnected: return "미연결 · \(who)"
        }
    }
}
