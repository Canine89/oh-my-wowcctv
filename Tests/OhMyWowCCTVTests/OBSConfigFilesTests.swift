import XCTest
@testable import OhMyWowCCTV

final class OBSConfigFilesTests: XCTestCase {
    func testINISetReplacesAndAppendsWithoutTouchingOthers() {
        var ini = INIFile(text: "[General]\nName=old\n\n[SimpleOutput]\nFilePath=/a\nRecFormat2=mkv\n")
        ini.set("General", "Name", "new")
        ini.set("SimpleOutput", "RecQuality", "HQ")
        ini.set("Video", "BaseCX", "1920")
        XCTAssertEqual(ini.get("General", "Name"), "new")
        XCTAssertEqual(ini.get("SimpleOutput", "FilePath"), "/a")
        XCTAssertEqual(ini.get("SimpleOutput", "RecQuality"), "HQ")
        XCTAssertEqual(ini.get("Video", "BaseCX"), "1920")
        XCTAssertEqual(ini.sections, ["General", "SimpleOutput", "Video"])
        XCTAssertTrue(ini.text.contains("RecFormat2=mkv"))
    }

    func testINIRemoveSection() {
        var ini = INIFile(text: "[A]\nx=1\n\n[YouTube]\nToken=secret\n\n[B]\ny=2\n")
        ini.removeSection("YouTube")
        XCTAssertNil(ini.get("YouTube", "Token"))
        XCTAssertEqual(ini.get("B", "y"), "2")
        XCTAssertFalse(ini.text.contains("secret"))
    }

    func testProfileManagedKeys() {
        let base = INIFile(text: "[General]\nName=제목 없음\n\n[Output]\nMode=Simple\n\n[SimpleOutput]\nFilePath=/Volumes/x\nRecQuality=Stream\nRecEncoder=x264\n")
        var ini = OBSProfileWriter.applyInitialDefaults(base)
        ini = OBSProfileWriter.applyManagedKeys(ini, recordingFolder: URL(fileURLWithPath: "/Users/me/Movies/WoW CCTV"))
        XCTAssertEqual(ini.get("General", "Name"), "OhMyWowCCTV")
        XCTAssertEqual(ini.get("SimpleOutput", "FilePath"), "/Users/me/Movies/WoW CCTV")
        XCTAssertEqual(ini.get("SimpleOutput", "RecQuality"), "HQ")
        XCTAssertEqual(ini.get("SimpleOutput", "RecEncoder"), "apple_h264")
        XCTAssertEqual(ini.get("AdvOut", "RecFilePath"), "/Users/me/Movies/WoW CCTV")
        XCTAssertEqual(ini.get("Output", "FilenameFormatting"), "%CCYY-%MM-%DD %hh-%mm-%ss")
    }

    func testFreshSceneCollectionShape() throws {
        let json = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true))
        XCTAssertEqual(json["name"] as? String, "OhMyWowCCTV")
        XCTAssertEqual(json["current_scene"] as? String, "WoW")
        XCTAssertNotNil(json["AuxAudioDevice1"])
        let sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.map { $0["id"] as? String }, ["scene", "screen_capture", "sck_audio_capture"])
        let video = sources[1]
        let vs = try XCTUnwrap(video["settings"] as? [String: Any])
        // WoW(Metal)는 SCK 창/앱 캡처가 안 잡혀 항상 디스플레이 캡처(type 0)를 쓰고 앱이 창 영역을 크롭한다
        XCTAssertEqual(vs["type"] as? Int, 0)
        XCTAssertEqual(video["muted"] as? Bool, true)
        // 장면 아이템이 비디오 소스 uuid 를 가리킨다
        let items = try XCTUnwrap((sources[0]["settings"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["source_uuid"] as? String }, [video["uuid"] as? String, sources[2]["uuid"] as? String])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json))
    }

    func testFreshIncludesVoiceChatSourceAsSceneItem() throws {
        let json = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true, voiceChat: "com.hnc.Discord"))
        let sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
        let voice = try XCTUnwrap(sources.first { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
        XCTAssertEqual(voice["id"] as? String, "sck_audio_capture")
        let vs = try XCTUnwrap(voice["settings"] as? [String: Any])
        XCTAssertEqual(vs["type"] as? Int, 1)
        XCTAssertEqual(vs["application"] as? String, "com.hnc.Discord")
        // 믹서에 뜨려면 장면 아이템이어야 한다
        let items = try XCTUnwrap((sources[0]["settings"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertTrue(items.contains { $0["source_uuid"] as? String == voice["uuid"] as? String })
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: json))
    }

    func testPatchAddsAndRemovesVoiceChatSource() throws {
        // 없던 상태 → 켜면 추가
        let without = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true))
        XCTAssertNil((without["sources"] as? [[String: Any]])?.first { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
        let added = OBSSceneWriter.patch(without, options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true, voiceChat: "us.zoom.xos"))
        let addedSources = try XCTUnwrap(added["sources"] as? [[String: Any]])
        let voice = try XCTUnwrap(addedSources.first { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
        XCTAssertEqual((voice["settings"] as? [String: Any])?["application"] as? String, "us.zoom.xos")
        let addedItems = try XCTUnwrap((addedSources[0]["settings"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertTrue(addedItems.contains { $0["name"] as? String == OBSSceneWriter.voiceSourceName })

        // 끄면 소스와 장면 아이템 모두 제거
        let removed = OBSSceneWriter.patch(added, options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true, voiceChat: nil))
        let removedSources = try XCTUnwrap(removed["sources"] as? [[String: Any]])
        XCTAssertNil(removedSources.first { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
        let removedItems = try XCTUnwrap((removedSources[0]["settings"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertFalse(removedItems.contains { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
    }

    func testPatchUpdatesVoiceChatApp() throws {
        let fresh = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true, voiceChat: "com.hnc.Discord"))
        let patched = OBSSceneWriter.patch(fresh, options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true, voiceChat: "com.tinyspeck.slackmacgap"))
        let sources = try XCTUnwrap(patched["sources"] as? [[String: Any]])
        let voice = try XCTUnwrap(sources.first { $0["name"] as? String == OBSSceneWriter.voiceSourceName })
        XCTAssertEqual((voice["settings"] as? [String: Any])?["application"] as? String, "com.tinyspeck.slackmacgap")
        // 중복 추가되지 않아야 한다
        XCTAssertEqual(sources.filter { $0["name"] as? String == OBSSceneWriter.voiceSourceName }.count, 1)
    }

    func testPatchAddsMissingAudioSourceAsSceneItem() throws {
        var fresh = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: false, showCursor: true))
        // OBS 가 오디오 소스를 버린 옛 파일을 흉내낸다
        var sources = try XCTUnwrap(fresh["sources"] as? [[String: Any]])
        sources.removeAll { $0["name"] as? String == OBSSceneWriter.audioSourceName }
        var scene = sources[0]; var st = scene["settings"] as! [String: Any]
        st["items"] = (st["items"] as! [[String: Any]]).filter { $0["name"] as? String != OBSSceneWriter.audioSourceName }
        scene["settings"] = st; sources[0] = scene
        fresh["sources"] = sources

        let patched = OBSSceneWriter.patch(fresh, options: .init(capture: .application, gameAudio: true, mic: false, showCursor: true))
        let ps = try XCTUnwrap(patched["sources"] as? [[String: Any]])
        let audio = try XCTUnwrap(ps.first { $0["name"] as? String == OBSSceneWriter.audioSourceName })
        let items = try XCTUnwrap((ps[0]["settings"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertTrue(items.contains { $0["source_uuid"] as? String == audio["uuid"] as? String })
    }

    func testPatchRemovesMicAndDisablesGameAudio() throws {
        let fresh = OBSSceneWriter.fresh(options: .init(capture: .application, gameAudio: true, mic: true, showCursor: true))
        let patched = OBSSceneWriter.patch(fresh, options: .init(capture: .display, gameAudio: false, mic: false, showCursor: false))
        XCTAssertNil(patched["AuxAudioDevice1"])
        let sources = try XCTUnwrap(patched["sources"] as? [[String: Any]])
        let vs = try XCTUnwrap(sources[1]["settings"] as? [String: Any])
        XCTAssertEqual(vs["type"] as? Int, 0)
        XCTAssertEqual(vs["show_cursor"] as? Bool, false)
        XCTAssertEqual(sources[2]["enabled"] as? Bool, false)
    }
}
