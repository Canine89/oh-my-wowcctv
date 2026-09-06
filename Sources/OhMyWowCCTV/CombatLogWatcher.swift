import Foundation

/// WoW Logs 폴더에서 가장 최근 `WoWCombatLog*.txt` 를 골라 tail 한다.
/// 시작 시점에 이미 있던 파일은 끝까지 건너뛰고, 그 이후 추가되는 줄만 전달한다.
final class CombatLogWatcher {
    var onLine: ((String) -> Void)?
    var onFileChange: ((URL?) -> Void)?

    private let logsDirectory: URL
    private let queue = DispatchQueue(label: "cctv.combatlog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var currentFile: URL?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var seenFirstScan = false

    init(logsDirectory: URL) {
        self.logsDirectory = logsDirectory
    }

    var currentFileURL: URL? { queue.sync { currentFile } }

    func start() {
        stop()
        seenFirstScan = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            currentFile = nil
            offset = 0
            remainder.removeAll()
        }
    }

    private func newestLogFile() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return items
            .filter { $0.lastPathComponent.hasPrefix("WoWCombatLog") && $0.pathExtension == "txt" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if da != db { return da < db }
                return a.lastPathComponent < b.lastPathComponent
            }
    }

    private func tick() {
        let newest = newestLogFile()
        let firstScan = !seenFirstScan
        seenFirstScan = true

        if newest != currentFile {
            currentFile = newest
            remainder.removeAll()
            if let file = newest {
                // 앱(감시) 시작 전에 있던 파일은 과거 기록이므로 끝으로 건너뛴다.
                offset = firstScan ? fileSize(file) : 0
            } else {
                offset = 0
            }
            let url = newest
            DispatchQueue.main.async { [weak self] in self?.onFileChange?(url) }
        }

        guard let file = currentFile else { return }
        let size = fileSize(file)
        if size < offset {
            // 파일이 잘렸으면 처음부터
            offset = 0
            remainder.removeAll()
        }
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            consume(data)
        } catch {
            return
        }
    }

    private func consume(_ data: Data) {
        remainder.append(data)
        while let nl = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder[remainder.startIndex..<nl]
            remainder = Data(remainder[(nl + 1)...])
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }
}
