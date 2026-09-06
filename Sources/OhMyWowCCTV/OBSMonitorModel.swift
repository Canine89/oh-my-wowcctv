import AppKit
import Combine

/// 미리보기 프레임만 담는 모델. 초당 30번 바뀌므로 다른 UI 와 분리해 미리보기 뷰만 다시 그리게 한다.
@MainActor
final class PreviewFrameModel: ObservableObject {
    @Published var image: CGImage?
    @Published var fps: Double = 0
    var size: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
}

/// 오디오 피크 값만 담는 모델 (초당 ~15회 갱신). 믹서 카드의 미터 뷰만 이걸 관찰한다.
@MainActor
final class MeterModel: ObservableObject {
    @Published var peaks: [String: Double] = [:]
}

/// CCTV 모니터 창의 데이터: OBS 가 실제로 렌더링하는 화면(스크린샷 폴링), 소스 목록, 오디오 미터/볼륨.
@MainActor
final class OBSMonitorModel: ObservableObject {
    let frame = PreviewFrameModel()
    let meters = MeterModel()
    private var lastMeterPublish = Date.distantPast
    private var pendingPeaks: [String: Double] = [:]
    private var lastSeen: [String: Date] = [:]
    struct SceneItem: Identifiable, Equatable {
        let id: Int
        let name: String
        let kind: String
        var enabled: Bool
    }

    struct AudioInput: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var muted = false
        var volumeDb: Double = 0
    }

    /// 미리보기가 살아 있는지 (프레임 자체는 frame.image)
    @Published private(set) var hasPreview = false
    @Published private(set) var previewError: String?
    @Published private(set) var sceneItems: [SceneItem] = []
    @Published private(set) var audioInputs: [AudioInput] = []
    @Published private(set) var canvasText: String?
    @Published private(set) var micDevices: [(id: String, name: String)] = []
    @Published private(set) var micDeviceID: String = "default"

    let client: OBSClient
    var onLog: ((String) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var viewers = 0
    private var frameTimes: [Date] = []
    /// 미리보기 뷰가 알려주는 표시 폭 (160 단위, 최대 1280 — 그 이상은 CPU 만 더 쓴다)
    var previewWidth = 1280 {
        didSet { previewWidth = min(1280, max(320, (previewWidth + 159) / 160 * 160)) }
    }

    init(client: OBSClient) {
        self.client = client
    }

    // MARK: - 보기 시작/중지 (창이 열려 있을 때만 폴링)

    func viewerAppeared() {
        viewers += 1
        if pollTask == nil { startPolling() }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            pollTask?.cancel()
            pollTask = nil
            meters.peaks = [:]
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            var tick = 0
            var lastSlow = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if self.client.state == .connected {
                    let frameStart = Date()
                    await self.fetchPreview()
                    // 느린 조회(소스/오디오/캔버스)는 2초에 한 번만
                    if Date().timeIntervalSince(lastSlow) > 2 {
                        lastSlow = Date()
                        await self.refreshSceneItems(); await self.refreshAudioInputs(); await self.refreshCanvas()
                        if tick % 5 == 0 { await self.refreshMicDevices() }
                        tick += 1
                    }
                    // 목표 fps 에 맞춰 남은 시간만 쉰다
                    let interval = 1.0 / Double(Prefs.previewFPS)
                    let remaining = interval - Date().timeIntervalSince(frameStart)
                    if remaining > 0.002 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                } else {
                    if self.hasPreview { self.hasPreview = false; self.frame.image = nil }
                    self.previewError = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    func handleEvent(_ type: String, _ data: [String: Any]) {
        switch type {
        case "InputVolumeMeters":
            guard viewers > 0, let inputs = data["inputs"] as? [[String: Any]] else { return }
            var newPeaks = pendingPeaks
            var newInput = false
            for input in inputs {
                guard let name = input["inputName"] as? String else { continue }
                let levels = input["inputLevelsMul"] as? [[Double]] ?? []
                let peak = levels.compactMap { $0.count > 1 ? $0[1] : $0.first }.max() ?? 0
                let dbRaw = peak > 0 ? 20 * log10(peak) : -100
                newPeaks[name] = max(newPeaks[name] ?? -100, dbRaw.isFinite ? dbRaw : -100)
                lastSeen[name] = Date()
                if !audioInputs.contains(where: { $0.name == name }) {
                    audioInputs.append(AudioInput(name: name))
                    newInput = true
                    Task { await loadInputState(name) }
                }
            }
            // 미터는 초당 15회까지만 발행 (그 사이 최대값 유지)
            let now = Date()
            if now.timeIntervalSince(lastMeterPublish) >= 1.0 / 15 || newInput {
                lastMeterPublish = now
                meters.peaks = newPeaks
                pendingPeaks = [:]
            } else {
                pendingPeaks = newPeaks
            }
        case "InputMuteStateChanged":
            if let name = data["inputName"] as? String, let muted = data["inputMuted"] as? Bool,
               let i = audioInputs.firstIndex(where: { $0.name == name }) { audioInputs[i].muted = muted }
        case "InputVolumeChanged":
            if let name = data["inputName"] as? String, let db = data["inputVolumeDb"] as? Double,
               let i = audioInputs.firstIndex(where: { $0.name == name }) { audioInputs[i].volumeDb = db }
        case "SceneItemEnableStateChanged":
            if let id = data["sceneItemId"] as? Int, let enabled = data["sceneItemEnabled"] as? Bool,
               let i = sceneItems.firstIndex(where: { $0.id == id }) { sceneItems[i].enabled = enabled }
        case "CurrentSceneCollectionChanged", "SceneItemCreated", "SceneItemRemoved", "InputCreated", "InputRemoved":
            Task { await refreshSceneItems(); await refreshAudioInputs() }
        default:
            break
        }
    }

    // MARK: - 조회

    private func fetchPreview() async {
        do {
            let r = try await client.request("GetSourceScreenshot", data: [
                "sourceName": OBSSceneWriter.sceneName,
                "imageFormat": "jpg",
                "imageWidth": previewWidth,
                "imageCompressionQuality": 65,
            ], timeout: 3)
            guard let dataURL = r["imageData"] as? String else { return }
            // base64 해제와 JPEG 디코딩은 메인 스레드 밖에서
            let decoded: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let comma = dataURL.firstIndex(of: ","),
                      let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                      let src = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { return nil }
                return cg
            }.value
            guard let cg = decoded else { return }
            if !hasPreview {
                hasPreview = true
                onLog?("미리보기 시작 (\(cg.width)x\(cg.height), 목표 \(Prefs.previewFPS)fps)")
            }
            frame.image = cg
            if previewError != nil { previewError = nil }
            let now = Date()
            frameTimes.append(now)
            frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
            // fps 표시는 0.5초에 한 번만 갱신
            if frameTimes.count % 15 == 0 { frame.fps = Double(frameTimes.count) / 2 }
        } catch OBSError.requestFailed(let code, let comment) {
            if hasPreview { hasPreview = false; frame.image = nil }
            previewError = code == 600 ? "OBS 에 'WoW' 장면이 없습니다 (CCTV 장면 모음이 아닌 상태)" : comment
        } catch {
            // 연결 끊김 등은 조용히
        }
    }

    func refreshCanvas() async {
        if let vs = try? await client.request("GetVideoSettings", timeout: 3),
           let w = vs["outputWidth"] as? Int, let h = vs["outputHeight"] as? Int {
            let fps = (vs["fpsNumerator"] as? Double ?? 0) / max(1, vs["fpsDenominator"] as? Double ?? 1)
            canvasText = "\(w)x\(h) \(Int(fps.rounded()))fps"
        }
    }

    func refreshMicDevices() async {
        let mic = OBSSceneWriter.micSourceName
        if let r = try? await client.request("GetInputPropertiesListPropertyItems", data: ["inputName": mic, "propertyName": "device_id"], timeout: 3),
           let items = r["propertyItems"] as? [[String: Any]] {
            let list = items.compactMap { i -> (id: String, name: String)? in
                guard let id = i["itemValue"] as? String, let name = i["itemName"] as? String else { return nil }
                return (id, name)
            }
            if list.map(\.id) != micDevices.map(\.id) { micDevices = list }
        }
        if let r = try? await client.request("GetInputSettings", data: ["inputName": mic], timeout: 3),
           let st = r["inputSettings"] as? [String: Any] {
            micDeviceID = st["device_id"] as? String ?? "default"
        }
    }

    func setMicDevice(_ id: String) {
        micDeviceID = id
        Task {
            _ = try? await client.request("SetInputSettings", data: ["inputName": OBSSceneWriter.micSourceName, "inputSettings": ["device_id": id], "overlay": true])
            let name = micDevices.first { $0.id == id }?.name ?? id
            onLog?("마이크 장치 변경: \(name)")
        }
    }

    func refreshSceneItems() async {
        do {
            let r = try await client.request("GetSceneItemList", data: ["sceneName": OBSSceneWriter.sceneName], timeout: 3)
            let items = (r["sceneItems"] as? [[String: Any]] ?? []).compactMap { d -> SceneItem? in
                guard let id = d["sceneItemId"] as? Int, let name = d["sourceName"] as? String else { return nil }
                return SceneItem(id: id, name: name, kind: d["inputKind"] as? String ?? "", enabled: d["sceneItemEnabled"] as? Bool ?? true)
            }
            if items != sceneItems { sceneItems = items }
        } catch {
            if !sceneItems.isEmpty { sceneItems = [] }
        }
    }

    func refreshAudioInputs() async {
        // 미터 이벤트로 알게 된 입력들의 음소거/볼륨 상태를 갱신하고, 사라진 입력은 제거
        for input in audioInputs {
            await loadInputState(input.name)
        }
        let stale = Date().addingTimeInterval(-5)
        let gone = audioInputs.filter { (lastSeen[$0.name] ?? .distantPast) < stale }.map(\.name)
        if !gone.isEmpty { audioInputs.removeAll { gone.contains($0.name) } }
    }

    private func loadInputState(_ name: String) async {
        guard let mute = try? await client.request("GetInputMute", data: ["inputName": name], timeout: 3),
              let vol = try? await client.request("GetInputVolume", data: ["inputName": name], timeout: 3),
              let i = audioInputs.firstIndex(where: { $0.name == name }) else { return }
        audioInputs[i].muted = mute["inputMuted"] as? Bool ?? false
        audioInputs[i].volumeDb = vol["inputVolumeDb"] as? Double ?? 0
    }

    // MARK: - 조작

    func setSceneItem(_ item: SceneItem, enabled: Bool) {
        Task {
            _ = try? await client.request("SetSceneItemEnabled", data: [
                "sceneName": OBSSceneWriter.sceneName, "sceneItemId": item.id, "sceneItemEnabled": enabled,
            ])
            await refreshSceneItems()
        }
    }

    func setMuted(_ input: AudioInput, _ muted: Bool) {
        if let i = audioInputs.firstIndex(where: { $0.name == input.name }) { audioInputs[i].muted = muted }
        Task { _ = try? await client.request("SetInputMute", data: ["inputName": input.name, "inputMuted": muted]) }
    }

    func setVolumeDb(_ input: AudioInput, _ db: Double) {
        if let i = audioInputs.firstIndex(where: { $0.name == input.name }) { audioInputs[i].volumeDb = db }
        Task { _ = try? await client.request("SetInputVolume", data: ["inputName": input.name, "inputVolumeDb": db]) }
    }
}
