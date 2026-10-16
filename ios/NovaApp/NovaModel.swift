import Foundation
import SwiftUI
import UIKit
import Security
import AVFoundation
import Speech

struct NovaStatus: Decodable {
    let connected: Bool
    let stopped: Bool
    let device: String
    let capabilities: [String]
    let ai: NovaAIStatus?
    let computer: NovaComputerStatus?
}
struct NovaComputerStatus: Decodable {
    let owner: Bool
    let busy: Bool
    let task: String?
}
struct EndComputerResult: Decodable { let ended: Bool }
struct NovaAIStatus: Decodable {
    let configured: Bool
    let model: String
    let usedUSD: Double
    let allowanceUSD: Double
    let busy: Bool
}
struct NovaJob: Decodable, Identifiable {
    let id: String
    let type: String
    let status: String
    let created_at: String
    let updated_at: String
}
struct NovaEvent: Decodable, Identifiable {
    let kind: String
    let description: String
    let created_at: String
    var id: String { "\(created_at)-\(kind)-\(description)" }
}
struct NovaDetail: Decodable {
    let id: String
    let type: String
    let status: String
    let error: String?
    let result: [String: JSONValue]?
    let payload: [String: JSONValue]
    let events: [NovaEvent]
}
enum JSONValue: Decodable, CustomStringConvertible {
    case string(String), number(Double), boolean(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let string = try? single.decode(String.self) { self = .string(string) }
        else if let number = try? single.decode(Double.self) { self = .number(number) }
        else if let boolean = try? single.decode(Bool.self) { self = .boolean(boolean) }
        else if let object = try? single.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try single.decode([JSONValue].self)) }
    }
    var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .boolean(let b): return String(b)
        case .object(let o): return o.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        case .array(let a): return a.map(\.description).joined(separator: ", ")
        case .null: return "null"
        }
    }
}
struct PairResult: Decodable { let id: String; let token: String }
struct JobsResponse: Decodable { let jobs: [NovaJob] }
struct CreatedJob: Decodable { let id: String; let status: String }
struct StopResult: Decodable { let stopped: Bool }
struct APIError: Decodable { let error: String }

enum NovaError: LocalizedError {
    case invalidURL, notPaired, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter the HTTPS address shown by Tailscale Serve on your Mac."
        case .notPaired: return "Pair this device first."
        case .server(let message): return message
        }
    }
}

// Never forward a pairing code or bearer credential through a redirect.
final class NovaSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// This v0.1 transport uses a Keychain-stored bearer credential over TLS + Tailscale.
/// Signed device requests remain a later milestone. Computer control is limited to the
/// locally designated owner iPhone and runs without per-action approval.
@MainActor
final class NovaModel: ObservableObject {
    private let session = URLSession(configuration: .ephemeral, delegate: NovaSessionDelegate(), delegateQueue: nil)
    @Published var address = UserDefaults.standard.string(forKey: "nova.baseURL") ?? ""
    @Published var pairingCode = ""
    @Published var connection = "Not connected"
    @Published var stopped = false
    @Published var jobs: [NovaJob] = []
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var ai: NovaAIStatus?
    @Published var chat: NovaDetail?
    @Published var computer: NovaComputerStatus?
    @Published var computerScreen: Data?
    @Published var voiceReplies = UserDefaults.standard.object(forKey: "nova.voiceReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceReplies, forKey: "nova.voiceReplies"); if !voiceReplies { speaker.stop() } }
    }
    let speaker = Speaker()
    let listener = Listener()
    private var screenRevision = ""
    private var spoken: Set<String>?

    var working: Bool { chat.map { ["queued","running"].contains($0.status) } ?? false }

    var paired: Bool { KeychainToken.read() != nil }

    init() {
        #if DEBUG
        // Local device setup can prefill a short-lived invitation without logging it.
        // Pairing still requires the user to tap Pair in the native app.
        let setup = ProcessInfo.processInfo.environment
        if !paired, let url = setup["NOVA_SETUP_URL"], let code = setup["NOVA_SETUP_CODE"] {
            address = url
            pairingCode = code
        }
        #endif
    }

    private func baseURL() throws -> URL {
        let savedAddress = UserDefaults.standard.string(forKey: "nova.baseURL")
        let selectedAddress = paired ? (savedAddress ?? "") : address
        guard let url = URL(string: selectedAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
        else { throw NovaError.invalidURL }
        return url
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil, authenticated: Bool = true) async throws -> T {
        let base = try baseURL()
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw NovaError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let token = KeychainToken.read() else { throw NovaError.notPaired }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                throw NovaError.server("Could not reach your Mac. Check that Tailscale is connected with the same account on both devices, and that Nova Core is running on the Mac.")
            }
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw NovaError.server("Invalid response") }
        guard (200...299).contains(response.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIError.self, from: data)
            throw NovaError.server(apiError?.error ?? "HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func pair() async {
        guard !paired, !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let result: PairResult = try await request("/v1/pair", method: "POST", body: ["code": pairingCode, "deviceName": "Nova iPhone"], authenticated: false)
            guard KeychainToken.save(result.token) else { throw NovaError.server("Could not save pairing credential in Keychain") }
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "nova.baseURL")
            pairingCode = ""
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard paired, !address.isEmpty else { return }
        do {
            let status: NovaStatus = try await request("/v1/status")
            let list: JobsResponse = try await request("/v1/jobs")
            jobs = list.jobs; stopped = status.stopped; connection = stopped ? "Emergency stopped" : "Mac connected"
            ai = status.ai
            computer = status.computer
            if let latest = jobs.first(where: { ["ai.chat","computer.task"].contains($0.type) }) {
                let detail: NovaDetail = try await request("/v1/jobs/\(latest.id)")
                chat = detail
                speakNew(detail)
                let revision = latest.id + latest.updated_at + String(detail.events.count)
                if latest.type == "computer.task", screenRevision != revision {
                    var req = URLRequest(url: URL(string:"/v1/computer/screen/\(latest.id)",relativeTo:try baseURL())!)
                    req.setValue("Bearer \(KeychainToken.read() ?? "")",forHTTPHeaderField:"Authorization")
                    let (data,response) = try await session.data(for:req)
                    if (response as? HTTPURLResponse)?.statusCode == 200 { computerScreen = data; screenRevision = revision }
                } else if latest.type != "computer.task" { computerScreen = nil }
            }
            errorMessage = nil
        } catch {
            connection = "Mac offline or unreachable"
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func submit(_ type: String, message: String = "") async -> Bool {
        guard !busy else { return false }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let _: CreatedJob = try await request("/v1/jobs", method: "POST", body: ["type":type, "message":message])
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func detail(_ id: String) async -> NovaDetail? {
        do { return try await request("/v1/jobs/\(id)") }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func emergencyStop() async {
        busy = true
        defer { busy = false }
        do {
            let _: StopResult = try await request("/v1/stop", method:"POST", body:[:])
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Owner iPhones talk to the computer agent, which also handles plain conversation.
    @discardableResult
    func send(_ message: String) async -> Bool {
        speaker.stop()
        return await submit(computer?.owner == true ? "computer.task" : "ai.chat", message: message)
    }

    func stopTask() async {
        speaker.stop()
        do { let _: EndComputerResult = try await request("/v1/computer/end", method: "POST", body: [:]); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Tap once to listen, tap again to send. Tapping while Nova talks interrupts it and listens.
    func tapFace() async {
        if listener.listening {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            await toggleListening()
        } else if working {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await toggleListening()
        }
    }

    func toggleListening() async {
        if listener.listening {
            let text = await listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { await send(text) }
        } else {
            speaker.stop()
            do { try await listener.start() } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Reads Nova's narration and final reply aloud once each. Anything already on
    /// screen when the app launches is treated as heard.
    private func speakNew(_ detail: NovaDetail) {
        var lines: [(String,String)] = detail.events.filter { $0.kind == "narration" }.map { ($0.id, $0.description) }
        if detail.status == "succeeded", let reply = detail.result?["message"] { lines.append(("\(detail.id)-reply", reply.description)) }
        if detail.status == "failed", let error = detail.error { lines.append(("\(detail.id)-error", error)) }
        guard var heard = spoken else { spoken = Set(lines.map(\.0)); return }
        for (key,text) in lines where !heard.contains(key) {
            heard.insert(key)
            if voiceReplies && !listener.listening { speaker.say(text) }
        }
        spoken = heard
    }

    func unpair() {
        speaker.stop(); KeychainToken.clear(); jobs = []; chat = nil; ai = nil; computer = nil; computerScreen = nil; connection = "Not connected"; errorMessage = nil
    }
}

enum KeychainToken {
    private static let service = "dev.nova.operator.pairing"
    private static let account = "primary-device"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:account, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func save(_ token: String) -> Bool {
        clear()
        guard let data = token.data(using:.utf8) else { return false }
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:account, kSecValueData as String:data, kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query as CFDictionary,nil) == errSecSuccess
    }
    static func clear() {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:account]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return english.first { $0.quality == .premium } ?? english.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()
    override init() { super.init(); synthesizer.delegate = self }
    func say(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
        speaking = true
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate); speaking = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = synthesizer.isSpeaking }
    }
}

/// Tap-to-talk dictation. Uses on-device recognition when the iPhone supports it.
@MainActor
final class Listener: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var level: CGFloat = 0
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async throws {
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard speech == .authorized else { throw NovaError.server("Allow Speech Recognition for Nova in Settings → Privacy & Security.") }
        guard await AVAudioApplication.requestRecordPermission() else { throw NovaError.server("Allow the microphone for Nova in Settings → Privacy & Security.") }
        guard let recognizer, recognizer.isAvailable else { throw NovaError.server("Speech recognition is not available right now.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Listener.loudness(buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()
        transcript = ""
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.transcript = text }
        }
        listening = true
    }

    /// Microphone loudness mapped from about -50…-10 dBFS to 0…1.
    nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let decibels = 20 * log10(max(1e-7, (sum / Float(buffer.frameLength)).squareRoot()))
        return CGFloat(min(1, max(0, (decibels + 50) / 40)))
    }

    func stop() async -> String {
        guard listening else { return transcript }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        try? await Task.sleep(for: .milliseconds(600))
        task?.cancel(); task = nil; request = nil
        listening = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript
    }
}
