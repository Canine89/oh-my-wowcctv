import AppKit
import CoreGraphics

/// WoW 의 실제 게임 창이 어디에 떠 있는지 찾는다 (창 ID, 크기, 디스플레이).
struct WoWWindowInfo: Equatable {
    let windowID: Int
    let bounds: CGRect
    let displayUUID: String?
    let isOnScreen: Bool

    var signature: String { "\(windowID)|\(Int(bounds.width))x\(Int(bounds.height))|\(displayUUID ?? "-")|\(isFullscreenSized)" }
    /// 위치까지 포함한 서명 (창을 옮기면 크롭을 다시 계산해야 한다)
    var placement: String { "\(signature)|\(Int(bounds.minX)),\(Int(bounds.minY))" }

    /// 창이 디스플레이를 통째로 덮는 크기인지 (독점 전체 화면 또는 창 모드 전체 화면)
    var isFullscreenSized: Bool { !isWindowed }

    /// 창이 속한 디스플레이 안에서의 위치/크기 (픽셀 단위). 캡처 프레임을 잘라낼 때 쓴다.
    var pixelRectInDisplay: (x: Int, y: Int, w: Int, h: Int, displayW: Int, displayH: Int)? {
        guard let display = WoWWindowLocator.display(containing: bounds) else { return nil }
        let db = CGDisplayBounds(display)
        let scale = backingScale
        let dw = Int(CGDisplayPixelsWide(display)), dh = Int(CGDisplayPixelsHigh(display))
        var x = Int(((bounds.minX - db.minX) * scale).rounded())
        var y = Int(((bounds.minY - db.minY) * scale).rounded())
        var w = Int((bounds.width * scale).rounded())
        var h = Int((bounds.height * scale).rounded())
        // 디스플레이 밖으로 나간 부분은 잘라낸다
        if x < 0 { w += x; x = 0 }
        if y < 0 { h += y; y = 0 }
        w = min(w, dw - x); h = min(h, dh - y)
        guard w > 0, h > 0 else { return nil }
        return (x, y, w, h, dw, dh)
    }

    /// 디스플레이 배율 (픽셀/포인트)
    var backingScale: Double {
        guard let display = WoWWindowLocator.display(containing: bounds) else { return 1 }
        return Double(CGDisplayPixelsHigh(display)) / max(1, Double(CGDisplayBounds(display).height))
    }

    /// 창이 디스플레이를 꽉 채우지 않는 일반 창 모드인지 (= macOS 제목 표시줄이 있음)
    var isWindowed: Bool {
        guard let display = WoWWindowLocator.display(containing: bounds) else { return true }
        let db = CGDisplayBounds(display)
        return bounds.height < db.height - 1 || bounds.width < db.width - 1
    }

    /// 제목 표시줄 높이(픽셀). 표준 28pt × 디스플레이 배율
    var titleBarPixels: Int {
        guard isWindowed, let display = WoWWindowLocator.display(containing: bounds) else { return 0 }
        let scale = Double(CGDisplayPixelsHigh(display)) / max(1, Double(CGDisplayBounds(display).height))
        return Int((28 * scale).rounded())
    }
}

enum WoWWindowLocator {
    static func find(bundleID: String) -> WoWWindowInfo? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { Int($0.processIdentifier) })
        // 화면 밖(다른 스페이스, 최소화, 독점 전체 화면)의 창도 포함해 찾되, 보이는 창을 우선한다
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }

        var best: WoWWindowInfo?
        var bestScore: CGFloat = 0
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            // 메뉴바 높이짜리 보조 창(30px) 등은 제외
            guard rect.width >= 400, rect.height >= 300 else { continue }
            let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let score = rect.width * rect.height * (onScreen ? 10 : 1)
            if score > bestScore {
                bestScore = score
                best = WoWWindowInfo(windowID: id, bounds: rect, displayUUID: displayUUID(containing: rect), isOnScreen: onScreen)
            }
        }
        return best
    }

    static func display(containing rect: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return ids.first { CGDisplayBounds($0).contains(center) } ?? CGMainDisplayID()
    }

    /// 창 중심이 속한 디스플레이의 UUID (OBS 의 display_uuid 와 같은 형식)
    static func displayUUID(containing rect: CGRect) -> String? {
        guard let hit = display(containing: rect),
              let uuid = CGDisplayCreateUUIDFromDisplayID(hit)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
