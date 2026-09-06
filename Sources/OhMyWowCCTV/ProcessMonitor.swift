import AppKit

/// 특정 번들 ID 앱의 실행/종료를 감시한다.
/// NSWorkspace 알림을 쓰되, 알림이 유실되는 경우를 대비해 2초마다 실제 상태도 확인한다.
final class ProcessMonitor {
    let bundleID: String
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var lastKnown: Bool?

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func start() {
        stop()
        lastKnown = isRunning
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.matches(note) else { return }
            self.report(true, via: "알림")
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.matches(note) else { return }
            // 같은 번들의 다른 프로세스가 남아 있을 수 있으므로 실제 상태를 다시 확인
            self.report(self.isRunning, via: "알림")
        })
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.report(self.isRunning, via: "폴링")
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func report(_ running: Bool, via: String) {
        guard running != lastKnown else { return }
        lastKnown = running
        NSLog("[CCTV-proc] %@ %@ (%@)", bundleID, running ? "실행" : "종료", via)
        onChange?(running)
    }

    private static func bundleID(of note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func matches(_ note: Notification) -> Bool {
        Self.bundleID(of: note) == bundleID
    }

    static func launch(appAt url: URL, completion: ((Error?) -> Void)? = nil) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async { completion?(error) }
        }
    }
}
