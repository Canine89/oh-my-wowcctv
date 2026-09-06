import Foundation

/// 전투 로그 한 줄. `9/6/2026 21:03:11.482  CHALLENGE_MODE_START,"Ara-Kara, City of Echoes",2660,503,12,[9,10,152]`
struct CombatLogLine: Equatable {
    let timestamp: String
    let event: String
    let fields: [String]
}

enum CombatLogEvent: Equatable {
    case challengeStart(dungeon: String, mapID: Int, challengeID: Int, level: Int, affixes: [Int])
    case challengeEnd(mapID: Int, success: Bool, level: Int, durationMS: Int)
    case encounterStart(id: Int, name: String, difficultyID: Int)
    case encounterEnd(id: Int, name: String, success: Bool, fightMS: Int)
    case zoneChange(mapID: Int, name: String, difficultyID: Int)
}

enum CombatLogParser {
    /// 타임스탬프와 이벤트 본문은 공백 두 개로 구분된다.
    static func parseLine(_ raw: String) -> CombatLogLine? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let sep = line.range(of: "  ") else { return nil }
        let timestamp = String(line[line.startIndex..<sep.lowerBound])
        let body = line[sep.upperBound...].drop(while: { $0 == " " })
        let fields = splitFields(body)
        guard let event = fields.first, !event.isEmpty else { return nil }
        return CombatLogLine(timestamp: timestamp, event: event, fields: Array(fields.dropFirst()))
    }

    static func event(from line: CombatLogLine) -> CombatLogEvent? {
        let f = line.fields
        switch line.event {
        case "CHALLENGE_MODE_START":
            // 던전 이름, 인스턴스(맵) ID, 챌린지 모드 ID, 단수, [어픽스...]
            guard f.count >= 4 else { return nil }
            return .challengeStart(
                dungeon: f[0],
                mapID: int(f[1]),
                challengeID: int(f[2]),
                level: int(f[3]),
                affixes: f.count > 4 ? intList(f[4]) : []
            )
        case "CHALLENGE_MODE_END":
            // 맵 ID, 성공(1/0), 단수, 소요 시간(ms), ...
            guard f.count >= 4 else { return nil }
            return .challengeEnd(mapID: int(f[0]), success: int(f[1]) == 1, level: int(f[2]), durationMS: int(f[3]))
        case "ENCOUNTER_START":
            // 우두머리 ID, 이름, 난이도 ID, 인원, 인스턴스 ID
            guard f.count >= 3 else { return nil }
            return .encounterStart(id: int(f[0]), name: f[1], difficultyID: int(f[2]))
        case "ENCOUNTER_END":
            // 우두머리 ID, 이름, 난이도 ID, 인원, 성공, 전투 시간(ms)
            guard f.count >= 5 else { return nil }
            return .encounterEnd(id: int(f[0]), name: f[1], success: int(f[4]) == 1, fightMS: f.count > 5 ? int(f[5]) : 0)
        case "ZONE_CHANGE":
            guard f.count >= 3 else { return nil }
            return .zoneChange(mapID: int(f[0]), name: f[1], difficultyID: int(f[2]))
        default:
            return nil
        }
    }

    static func parseEvent(_ raw: String) -> CombatLogEvent? {
        guard let line = parseLine(raw) else { return nil }
        return event(from: line)
    }

    /// 따옴표와 괄호([], ()) 안의 쉼표는 구분자로 취급하지 않는 CSV 분리.
    static func splitFields(_ s: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" { inQuotes = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case "[", "(": depth += 1; current.append(ch)
            case "]", ")": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0:
                fields.append(current); current = ""
            default: current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    private static func int(_ s: String) -> Int {
        Int(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func intList(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
