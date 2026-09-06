import SwiftUI

@main
struct OhMyWowCCTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RecordingCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(coordinator)
        } label: {
            MenuBarLabel().environmentObject(coordinator)
        }
        .menuBarExtraStyle(.menu)

        Window("CCTV 모니터", id: "monitor") {
            MonitorView(model: coordinator.monitor).environmentObject(coordinator)
        }
        .defaultSize(width: 1280, height: 900)

        Window("이벤트 로그", id: "eventLog") {
            EventLogView().environmentObject(coordinator)
        }
        .defaultSize(width: 680, height: 440)

        Settings {
            SettingsView().environmentObject(coordinator)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단위 테스트 호스트로 떠 있을 때는 실제 감시/OBS 제어를 하지 않는다 (실행 중인 진짜 앱과 충돌 방지)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return
        }
        RecordingCoordinator.shared.start()
        // kill/로그아웃 등으로 SIGTERM 을 받아도 OBS 정리가 되도록 정상 종료 경로로 돌린다
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            RecordingCoordinator.shared.log("SIGTERM 수신 → 정리 후 종료")
            RecordingCoordinator.shared.shutdownForAppTermination()
            exit(0)
        }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecordingCoordinator.shared.shutdownForAppTermination()
    }
}

/// 메뉴바 아이콘. 환경(openWindow)에 접근할 수 있는 뷰라서 개발용 자동 열기도 여기서 처리한다.
struct MenuBarLabel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var didAutoOpen = false

    var body: some View {
        Image(nsImage: coordinator.menuBarImage)
            .onAppear {
                guard !didAutoOpen else { return }
                didAutoOpen = true
                let env = ProcessInfo.processInfo.environment
                if env["CCTV_OPEN_MONITOR"] == "1" { openWindow(id: "monitor"); NSApp.activate(ignoringOtherApps: true) }
                if env["CCTV_OPEN_SETTINGS"] == "1" { NSApp.activate(ignoringOtherApps: true); openSettings() }
                if let dir = env["CCTV_SNAPSHOT_DIR"], let secs = env["CCTV_SNAPSHOT_AFTER"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { Self.snapshotWindows(to: dir) }
                }
            }
    }

    /// 개발용: 열려 있는 창을 앱 스스로 PNG 로 렌더링한다 (화면 기록 권한 불필요)
    static func snapshotWindows(to dir: String) {
        let c = RecordingCoordinator.shared
        for (i, w) in NSApp.windows.enumerated() {
            c.log("창[\(i)] '\(w.title)' visible=\(w.isVisible) size=\(Int(w.frame.width))x\(Int(w.frame.height))")
            guard w.isVisible, let view = w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: "/", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            c.log("스냅샷 저장: \(url.path)")
        }
    }
}
