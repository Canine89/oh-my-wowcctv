import SwiftUI

struct EventLogView: View {
    @EnvironmentObject private var c: RecordingCoordinator

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(c.statusLine).font(.headline)
                Spacer()
                Button("로그 파일 보기") {
                    NSWorkspace.shared.activateFileViewerSelecting([RecordingCoordinator.logFileURL])
                }
                Button("복사") {
                    let text = c.events.map { "\(Self.time.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                List(c.events) { e in
                    HStack(alignment: .top) {
                        Text(Self.time.string(from: e.date))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(e.message).textSelection(.enabled)
                    }
                    .id(e.id)
                }
                .onChange(of: c.events.count) { _, _ in
                    if let last = c.events.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
