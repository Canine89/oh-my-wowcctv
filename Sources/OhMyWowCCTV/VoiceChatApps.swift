import AppKit

/// 친구 음성(보이스 챗) 앱 후보. 이 맥에 실제로 설치된 것만 고를 수 있게 한다.
enum VoiceChatApps {
    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    /// 게임하면서 흔히 쓰는 음성 앱들
    static let candidates: [App] = [
        App(bundleID: "com.hnc.Discord", name: "Discord"),
        App(bundleID: "us.zoom.xos", name: "Zoom"),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        App(bundleID: "com.kakao.KakaoTalk", name: "카카오톡"),
        App(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        App(bundleID: "com.valvesoftware.steam", name: "Steam"),
        App(bundleID: "org.mumble.Mumble", name: "Mumble"),
        App(bundleID: "com.teamspeak.TeamSpeak", name: "TeamSpeak"),
    ]

    /// 설치된 후보만 (없으면 빈 배열)
    static func installed() -> [App] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// 기본값: 설치된 것 중 Discord 우선, 없으면 첫 번째, 그것도 없으면 Discord 번들 ID
    static func defaultBundleID() -> String {
        let list = installed()
        if list.contains(where: { $0.bundleID == "com.hnc.Discord" }) { return "com.hnc.Discord" }
        return list.first?.bundleID ?? "com.hnc.Discord"
    }

    static func displayName(for bundleID: String) -> String {
        if let known = candidates.first(where: { $0.bundleID == bundleID }) { return known.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}
