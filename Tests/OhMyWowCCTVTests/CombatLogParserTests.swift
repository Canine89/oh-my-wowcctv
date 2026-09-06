import XCTest
import CryptoKit
@testable import OhMyWowCCTV

final class CombatLogParserTests: XCTestCase {
    func testChallengeStartWithCommaInName() {
        let line = "9/6/2026 21:03:11.482  CHALLENGE_MODE_START,\"Ara-Kara, City of Echoes\",2660,503,12,[9,10,152]"
        XCTAssertEqual(
            CombatLogParser.parseEvent(line),
            .challengeStart(dungeon: "Ara-Kara, City of Echoes", mapID: 2660, challengeID: 503, level: 12, affixes: [9, 10, 152])
        )
    }

    func testChallengeStartWithTimezoneSuffix() {
        let line = "9/6/2026 21:03:11.482+9  CHALLENGE_MODE_START,\"메아리의 도시 아라카라\",2660,503,10,[9,10]"
        guard case .challengeStart(let dungeon, _, _, let level, let affixes)? = CombatLogParser.parseEvent(line) else {
            return XCTFail("parse failed")
        }
        XCTAssertEqual(dungeon, "메아리의 도시 아라카라")
        XCTAssertEqual(level, 10)
        XCTAssertEqual(affixes, [9, 10])
    }

    func testChallengeEnd() {
        let line = "9/6/2026 21:31:47.019  CHALLENGE_MODE_END,2660,1,12,1712340,0,0"
        XCTAssertEqual(CombatLogParser.parseEvent(line), .challengeEnd(mapID: 2660, success: true, level: 12, durationMS: 1_712_340))
    }

    func testChallengeEndFailed() {
        let line = "9/6/2026 21:31:47.019  CHALLENGE_MODE_END,2660,0,12,2012340"
        XCTAssertEqual(CombatLogParser.parseEvent(line), .challengeEnd(mapID: 2660, success: false, level: 12, durationMS: 2_012_340))
    }

    func testEncounterEnd() {
        let line = "9/6/2026 21:31:40.000  ENCOUNTER_END,2926,\"Ki'katal the Harvester\",8,5,1,180000"
        XCTAssertEqual(CombatLogParser.parseEvent(line), .encounterEnd(id: 2926, name: "Ki'katal the Harvester", success: true, fightMS: 180_000))
    }

    func testZoneChange() {
        let line = "9/6/2026 21:00:00.000  ZONE_CHANGE,2660,\"Ara-Kara, City of Echoes\",23"
        XCTAssertEqual(CombatLogParser.parseEvent(line), .zoneChange(mapID: 2660, name: "Ara-Kara, City of Echoes", difficultyID: 23))
    }

    func testCombatEventIsIgnored() {
        let line = "9/6/2026 21:05:00.000  SPELL_DAMAGE,Player-1234,\"Foo-Azshara\",0x511,0x0,Creature-0-1,\"Bar\",0xa48,0x0,1234,\"Spell, Name\",0x1,..."
        XCTAssertNil(CombatLogParser.parseEvent(line))
        XCTAssertEqual(CombatLogParser.parseLine(line)?.event, "SPELL_DAMAGE")
    }

    func testSplitFieldsRespectsParentheses() {
        let f = CombatLogParser.splitFields("A,(1,2),\"x,y\",[3,4]")
        XCTAssertEqual(f, ["A", "(1,2)", "x,y", "[3,4]"])
    }

    func testAuthString() {
        // obs-websocket 5.x: base64(sha256(base64(sha256(password + salt)) + challenge))
        let password = "supersecretpassword", salt = "PZVbYpvAnZut2SS6JNJytDm9", challenge = "ztTBnnuqrqaKDzRM3xcVdbYm"
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        let expected = Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
        XCTAssertEqual(OBSClient.authString(password: password, salt: salt, challenge: challenge), expected)
        XCTAssertNotEqual(OBSClient.authString(password: "wrong", salt: salt, challenge: challenge), expected)
    }
}
