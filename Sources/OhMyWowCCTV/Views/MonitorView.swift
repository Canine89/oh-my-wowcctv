import SwiftUI

/// CCTV 모니터: 미리보기가 창을 채우고, 소스·오디오·녹화 조작은 하단 얇은 띠에 모아 둔다.
struct MonitorView: View {
    @EnvironmentObject private var c: RecordingCoordinator
    @ObservedObject private var m: OBSMonitorModel
    @AppStorage(Prefs.Key.captureMode) private var captureMode = "application"

    init(model: OBSMonitorModel) { m = model }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomStrip
                .frame(height: 118)
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { m.viewerAppeared() }
        .onDisappear { m.viewerDisappeared() }
    }

    // MARK: 상단 컨트롤

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                c.manualToggleRecording()
            } label: {
                Label(c.obsRecording ? "녹화 정지" : "녹화 시작", systemImage: c.obsRecording ? "stop.fill" : "record.circle")
            }
            .keyboardShortcut("r", modifiers: [.control, .option, .command])
            .tint(c.obsRecording ? .red : .accentColor)
            .buttonStyle(.borderedProminent)

            Button("테스트 \(Prefs.testRecordingSeconds)초") { c.runTestRecording() }
                .disabled(c.obsRecording)

            Divider().frame(height: 18)

            Picker("캡처", selection: $captureMode) {
                Text("WoW 창 (자동)").tag("application")
                Text("디스플레이 고정").tag("display")
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .onChange(of: captureMode) { _, _ in c.refreshCapture() }

            Button("다시 잡기") { c.refreshCapture() }
                .help("화면이 검게 나오면 눌러 보세요. WoW 창을 다시 찾아 캡처를 재설정합니다.")
                .disabled(c.obsState != .connected)

            Spacer()

            recBadge

            Button("OBS 창") { c.showOBS() }
                .help("인코더·화질 등 세부 설정은 OBS 에서 직접 바꿉니다")
                .disabled(!c.obsRunning)
            Button("폴더") { NSWorkspace.shared.open(Prefs.recordingFolderURL) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var recBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(c.obsRecording ? Color.red : Color.gray).frame(width: 9, height: 9)
            Text(c.obsRecording ? "REC \(RecordingCoordinator.format(seconds: c.elapsed))" : "대기")
                .font(.caption.bold().monospacedDigit())
            if let run = c.currentRun { Text("· \(run.dungeon) +\(run.level)").font(.caption) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(c.obsRecording ? Color.red.opacity(0.15) : Color.gray.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: 미리보기 (남은 공간 전부)

    private var preview: some View {
        ZStack {
            Color.black
            GeometryReader { geo in
                Color.clear
                    .onAppear { m.previewWidth = Int(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in m.previewWidth = Int(w) }
            }
            if m.hasPreview {
                PreviewFrameView(frame: m.frame, canvasText: m.canvasText)
            }
            if let hint = c.captureHint {
                VStack {
                    Spacer()
                    Text(hint)
                        .font(.caption).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.65)).foregroundStyle(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 14)
                }
            }
            if !m.hasPreview {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(placeholderText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !c.obsRunning { Button("지금 OBS 켜기 (미리보기용)") { c.ensureOBS() } }
                }
            }
        }
    }

    private var placeholderText: String {
        if !c.obsRunning { return "OBS 가 꺼져 있습니다.\nWoW 를 켜면 자동으로 켜집니다." }
        if c.obsState != .connected { return "OBS 에 연결하는 중…" }
        return m.previewError ?? "미리보기를 불러오는 중…"
    }

    // MARK: 하단 띠: 소스 + 믹서

    private var bottomStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("소스").font(.caption.bold()).foregroundStyle(.secondary)
                if m.sceneItems.isEmpty { Text("—").foregroundStyle(.secondary).font(.caption) }
                ForEach(m.sceneItems) { item in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: item.kind)).frame(width: 14).font(.caption)
                        Text(item.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(get: { item.enabled }, set: { m.setSceneItem(item, enabled: $0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 170)
            .padding(10)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    Text("믹서").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 2)
                    if m.audioInputs.isEmpty { Text("오디오 입력 없음").foregroundStyle(.secondary).font(.caption) }
                    ForEach(m.audioInputs) { input in mixerCard(input) }
                }
                .padding(10)
            }
        }
    }

    private func mixerCard(_ input: OBSMonitorModel.AudioInput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(input.name).font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 2)
                MeterText(meters: m.meters, name: input.name, muted: input.muted)
                Button { m.setMuted(input, !input.muted) } label: {
                    Image(systemName: input.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(input.muted ? .red : .primary).font(.caption)
                }
                .buttonStyle(.borderless)
            }
            MeterBar(meters: m.meters, name: input.name, muted: input.muted).frame(height: 7)
            HStack(spacing: 6) {
                Slider(value: Binding(get: { input.volumeDb }, set: { m.setVolumeDb(input, $0) }), in: -60...0)
                    .controlSize(.mini)
                Text(String(format: "%+.0f", input.volumeDb)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            }
            if input.name == OBSSceneWriter.micSourceName {
                Picker("", selection: Binding(get: { m.micDeviceID }, set: { m.setMicDevice($0) })) {
                    ForEach(m.micDevices, id: \.id) { d in Text(d.name).tag(d.id) }
                    if !m.micDevices.contains(where: { $0.id == m.micDeviceID }) { Text(m.micDeviceID).tag(m.micDeviceID) }
                }
                .labelsHidden().controlSize(.mini)
                .onAppear { Task { await m.refreshMicDevices() } }
            }
        }
        .padding(8)
        .frame(width: 230)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "screen_capture", "display_capture", "window_capture": return "display"
        case "sck_audio_capture", "coreaudio_input_capture", "coreaudio_output_capture": return "waveform"
        default: return "square.on.square"
        }
    }

    // MARK: 푸터

    private var footer: some View {
        HStack {
            Text(c.statusLine)
            Spacer()
            Text("OBS: " + obsText).foregroundStyle(.secondary)
            if let last = c.lastRecordingPath {
                Button("마지막 파일") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: last)]) }
                    .controlSize(.mini)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var obsText: String {
        if !c.obsRunning { return "꺼짐" }
        switch c.obsState {
        case .connected: return "연결됨"
        case .connecting: return "연결 중"
        case .disconnected: return "미연결"
        }
    }
}

/// 미리보기 프레임만 관찰하는 뷰. 초당 30번 갱신돼도 이 뷰만 다시 그려진다.
struct PreviewFrameView: View {
    @ObservedObject var frame: PreviewFrameModel
    let canvasText: String?

    var body: some View {
        ZStack {
            PreviewLayerView(frame: frame)
                .padding(6)
            VStack {
                HStack {
                    Spacer()
                    Text(String(format: "%.0f fps 미리보기 · 녹화 %@", frame.fps, canvasText ?? "\(Int(frame.size.width))x\(Int(frame.size.height))"))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.55)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
            }
            .padding(10)
        }
    }
}

/// CALayer 에 프레임을 직접 넣는 미리보기. SwiftUI 레이아웃/그래프 갱신 없이 초당 30장을 그린다.
struct PreviewLayerView: NSViewRepresentable {
    @ObservedObject var frame: PreviewFrameModel

    final class LayerHostView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.magnificationFilter = .linear
            layer?.minificationFilter = .linear
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isOpaque: Bool { true }
    }

    func makeNSView(context: Context) -> LayerHostView { LayerHostView(frame: .zero) }

    func updateNSView(_ view: LayerHostView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = frame.image
        CATransaction.commit()
    }
}

/// 미터 모델만 관찰하는 작은 뷰들 — 피크가 바뀌어도 믹서 카드 전체는 다시 그리지 않는다
struct MeterText: View {
    @ObservedObject var meters: MeterModel
    let name: String
    let muted: Bool
    var body: some View {
        Text(String(format: "%.0f dB", max(muted ? -100 : (meters.peaks[name] ?? -100), -99.0)))
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
    }
}

struct MeterBar: View {
    @ObservedObject var meters: MeterModel
    let name: String
    let muted: Bool
    var body: some View {
        LevelMeter(peakDb: muted ? -100 : (meters.peaks[name] ?? -100))
    }
}

/// OBS 스타일 피크 미터 (-60 ~ 0 dB, 노랑 -20, 빨강 -9)
struct LevelMeter: View {
    let peakDb: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (peakDb + 60) / 60))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.25))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.green).frame(width: geo.size.width * min(fraction, 40 / 60))
                    if fraction > 40 / 60 {
                        Rectangle().fill(Color.yellow).frame(width: geo.size.width * (min(fraction, 51 / 60) - 40 / 60))
                    }
                    if fraction > 51 / 60 {
                        Rectangle().fill(Color.red).frame(width: geo.size.width * (fraction - 51 / 60))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }
}
