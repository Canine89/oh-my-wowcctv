import Foundation
import CryptoKit

enum OBSError: LocalizedError {
    case notConnected
    case authenticationFailed
    case requestFailed(code: Int, comment: String)
    case timeout
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "OBS에 연결되어 있지 않습니다"
        case .authenticationFailed: return "OBS 웹소켓 비밀번호가 틀렸습니다"
        case .requestFailed(let code, let comment): return "OBS 요청 실패 (\(code)): \(comment)"
        case .timeout: return "OBS 응답 시간 초과"
        case .badResponse: return "OBS 응답을 해석할 수 없습니다"
        }
    }
}

/// obs-websocket 5.x 프로토콜 클라이언트 (OBS 28+ 기본 내장).
final class OBSClient: NSObject {
    struct Config: Equatable {
        var host: String
        var port: Int
        var password: String
    }

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    struct RecordState {
        let active: Bool
        let state: String
        let outputPath: String?
    }

    var onStateChange: ((State) -> Void)?
    var onRecordStateChanged: ((RecordState) -> Void)?
    var onEvent: ((String, [String: Any]) -> Void)?
    var onLog: ((String) -> Void)?

    /// 기본(비고용량) 이벤트 전체 + InputVolumeMeters(1<<16)
    static let eventSubscriptions = 2047 | (1 << 16)

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { emitState(state) } }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var config: Config
    private var shouldRun = false
    private var loopTask: Task<Void, Never>?
    private var lastCloseCode: URLSessionWebSocketTask.CloseCode?

    private let lock = NSLock()
    private struct Pending {
        let cont: CheckedContinuation<[String: Any], Error>
        var timeout: Task<Void, Never>?
    }
    private var pending: [String: Pending] = [:]

    init(config: Config) {
        self.config = config
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - 연결 관리

    func start(config: Config) {
        if shouldRun, config == self.config { return }
        stop()
        self.config = config
        shouldRun = true
        loopTask = Task { [weak self] in
            var delay: UInt64 = 2
            while let self, self.shouldRun {
                await self.connectOnce()
                guard self.shouldRun else { break }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay + 1, 5)
            }
        }
    }

    func stop() {
        shouldRun = false
        loopTask?.cancel()
        loopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failAllPending(OBSError.notConnected)
        state = .disconnected
    }

    /// Hello → Identify → Identified 핸드셰이크는 receiveLoop 안에서 처리된다.
    /// 소켓이 끊길 때까지 여기서 대기한다.
    private func connectOnce() async {
        guard let url = URL(string: "ws://\(config.host):\(config.port)") else { return }
        state = .connecting
        lastCloseCode = nil
        let ws = session.webSocketTask(with: url)
        task = ws
        ws.resume()

        await receiveLoop(ws)

        if lastCloseCode?.rawValue == 4009 {
            log("연결 실패: 웹소켓 비밀번호 불일치")
        }
        task = nil
        failAllPending(OBSError.notConnected)
        state = .disconnected
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                await handle(text: text, ws: ws)
            } catch {
                return
            }
        }
    }

    private func handle(text: String, ws: URLSessionWebSocketTask) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }
        let d = json["d"] as? [String: Any] ?? [:]

        switch op {
        case 0: // Hello
            var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": Self.eventSubscriptions]
            if let auth = d["authentication"] as? [String: Any],
               let challenge = auth["challenge"] as? String,
               let salt = auth["salt"] as? String {
                identify["authentication"] = Self.authString(password: config.password, salt: salt, challenge: challenge)
            }
            await send(op: 1, d: identify, ws: ws)
        case 2: // Identified
            state = .connected
            log("OBS 연결됨")
        case 5: // Event
            guard let type = d["eventType"] as? String,
                  let payload = d["eventData"] as? [String: Any] else { return }
            if type == "RecordStateChanged" {
                let rs = RecordState(
                    active: payload["outputActive"] as? Bool ?? false,
                    state: payload["outputState"] as? String ?? "",
                    outputPath: payload["outputPath"] as? String
                )
                DispatchQueue.main.async { self.onRecordStateChanged?(rs) }
            }
            DispatchQueue.main.async { self.onEvent?(type, payload) }
        case 7: // RequestResponse
            guard let id = d["requestId"] as? String else { return }
            let entry = lock.withLock { pending.removeValue(forKey: id) }
            guard let entry else { return }
            entry.timeout?.cancel()
            let cont = entry.cont
            let status = d["requestStatus"] as? [String: Any] ?? [:]
            if status["result"] as? Bool == true {
                cont.resume(returning: d["responseData"] as? [String: Any] ?? [:])
            } else {
                cont.resume(throwing: OBSError.requestFailed(
                    code: status["code"] as? Int ?? -1,
                    comment: status["comment"] as? String ?? ""
                ))
            }
        default:
            break
        }
    }

    private func send(op: Int, d: [String: Any], ws: URLSessionWebSocketTask) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await ws.send(.string(text))
    }

    private func failAllPending(_ error: Error) {
        let entries = lock.withLock { () -> [Pending] in
            let v = Array(pending.values)
            pending.removeAll()
            return v
        }
        entries.forEach { $0.timeout?.cancel(); $0.cont.resume(throwing: error) }
    }

    private func emitState(_ s: State) {
        DispatchQueue.main.async { self.onStateChange?(s) }
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.onLog?(s) }
    }

    static func authString(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    // MARK: - 요청

    func request(_ type: String, data: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard state == .connected, let ws = task else { throw OBSError.notConnected }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let late = lock.withLock { pending.removeValue(forKey: id) }
                late?.cont.resume(throwing: OBSError.timeout)
            }
            lock.withLock { pending[id] = Pending(cont: cont, timeout: timeoutTask) }
            Task { await send(op: 6, d: ["requestType": type, "requestId": id, "requestData": data], ws: ws) }
        }
    }

    func isRecording() async throws -> Bool {
        let r = try await request("GetRecordStatus")
        return r["outputActive"] as? Bool ?? false
    }

    func startRecord() async throws {
        do {
            _ = try await request("StartRecord")
        } catch OBSError.requestFailed(let code, _) where code == 500 {
            // 이미 녹화 중 (OutputRunning)
            return
        }
    }

    /// 반환값: OBS 가 알려준 출력 파일 경로
    @discardableResult
    func stopRecord() async throws -> String? {
        do {
            let r = try await request("StopRecord")
            return r["outputPath"] as? String
        } catch OBSError.requestFailed(let code, _) where code == 501 {
            // 녹화 중이 아님 (OutputNotRunning)
            return nil
        }
    }

    func version() async throws -> String {
        let r = try await request("GetVersion")
        return "OBS \(r["obsVersion"] as? String ?? "?") / websocket \(r["obsWebSocketVersion"] as? String ?? "?")"
    }
}

extension OBSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lastCloseCode = closeCode
    }
}
