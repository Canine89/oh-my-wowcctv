import XCTest
@testable import OhMyWowCCTV

final class CombatLogWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cctv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func testSkipsExistingContentAndDeliversNewLines() throws {
        let old = dir.appendingPathComponent("WoWCombatLog-090526_200000.txt")
        try append("9/5/2026 20:00:00.000  CHALLENGE_MODE_START,\"Old\",1,1,1,[]\n", to: old)

        let watcher = CombatLogWatcher(logsDirectory: dir)
        var lines: [String] = []
        let exp = expectation(description: "two new lines")
        exp.expectedFulfillmentCount = 2
        watcher.onLine = { lines.append($0); exp.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // 감시 시작 후 기존 파일에 추가되는 줄만 와야 한다
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            try? self.append("9/6/2026 21:00:00.000  ENCOUNTER_START,1,\"A\",8,5,1\n9/6/2026 21:00:01.000  ENCOUNTER_END,1,\"A\",8,5,1,1000\n", to: old)
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("ENCOUNTER_START"))
        XCTAssertFalse(lines.contains { $0.contains("Old") })
    }

    func testSwitchesToNewerFileAndReadsFromStart() throws {
        let old = dir.appendingPathComponent("WoWCombatLog-090526_200000.txt")
        try append("old line\n", to: old)

        let watcher = CombatLogWatcher(logsDirectory: dir)
        var lines: [String] = []
        var files: [URL?] = []
        let exp = expectation(description: "new file line")
        watcher.onLine = { lines.append($0); exp.fulfill() }
        watcher.onFileChange = { files.append($0) }
        watcher.start()
        defer { watcher.stop() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let new = self.dir.appendingPathComponent("WoWCombatLog-090626_210000.txt")
            try? self.append("9/6/2026 21:03:11.482  CHALLENGE_MODE_START,\"New\",2660,503,12,[9,10]\n", to: new)
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(lines, ["9/6/2026 21:03:11.482  CHALLENGE_MODE_START,\"New\",2660,503,12,[9,10]"])
        XCTAssertEqual(files.last??.lastPathComponent, "WoWCombatLog-090626_210000.txt")
    }
}
