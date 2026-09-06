import Foundation

/// 앱 번들에 동봉된 WoW 애드온을 Interface/AddOns 에 복사한다.
enum AddonInstaller {
    static let addonName = "OhMyWowCCTV"

    enum InstallError: LocalizedError {
        case bundledAddonMissing
        case addonsFolderMissing(String)

        var errorDescription: String? {
            switch self {
            case .bundledAddonMissing: return "앱 안에 애드온 파일이 없습니다 (빌드 문제)"
            case .addonsFolderMissing(let p): return "WoW AddOns 폴더를 찾을 수 없습니다: \(p)"
            }
        }
    }

    /// 앱 번들(Contents/Resources/Addon/OhMyWowCCTV) 또는 개발 중 소스 트리에서 애드온 폴더를 찾는다.
    static func bundledAddonURL() -> URL? {
        if let res = Bundle.main.resourceURL {
            let inBundle = res.appendingPathComponent("Addon/\(addonName)")
            if FileManager.default.fileExists(atPath: inBundle.path) { return inBundle }
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Addon/\(addonName)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var installedURL: URL { Prefs.wowAddOnsURL.appendingPathComponent(addonName) }

    static func version(at url: URL) -> String? {
        let toc = url.appendingPathComponent("\(addonName).toc")
        guard let text = try? String(contentsOf: toc, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("## Version:") {
            return line.replacingOccurrences(of: "## Version:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static var bundledVersion: String? { bundledAddonURL().flatMap(version(at:)) }
    static var installedVersion: String? { version(at: installedURL) }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }
    static var needsUpdate: Bool { isInstalled && installedVersion != bundledVersion }

    static func install() throws {
        guard let source = bundledAddonURL() else { throw InstallError.bundledAddonMissing }
        let addons = Prefs.wowAddOnsURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: addons.path, isDirectory: &isDir), isDir.boolValue else {
            throw InstallError.addonsFolderMissing(addons.path)
        }
        let dest = installedURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
    }
}
