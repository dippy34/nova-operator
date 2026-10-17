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
    let range: String?
    let provider: NovaProviderRef?
}
struct NovaProviderRef: Decodable {
    let selected: String
    let label: String
    let configured: Bool
}
struct NovaComputerStatus: Decodable {
    let owner: Bool
    let busy: Bool
    let task: String?
    let controlled: Bool?
    let paused: Bool?
}
struct EndComputerResult: Decodable { let ended: Bool }
struct NovaAIStatus: Decodable {
    let configured: Bool
    let model: String
    let usedUSD: Double
    let allowanceUSD: Double?
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
/// A visual Nova draws in place of its face. Mirrors Core's `show` tool schema.
struct NovaVisual: Decodable, Equatable {
    struct Function: Decodable, Equatable { let expression: String; let label: String? }
    struct Point: Decodable, Equatable { let x: Double; let y: Double; let label: String? }
    struct Series: Decodable, Equatable { let name: String?; let values: [Double] }
    struct Mark: Decodable, Equatable { let shape: String; let points: [[Double]]; let size: Double?; let text: String?; let color: String? }
    struct Step: Decodable, Equatable { let write: String; let say: String?; let highlight: Bool?; let sketch: [Mark]? }
    struct Item: Decodable, Equatable { let title: String; let detail: String?; let symbol: String? }
    let type: String
    let title: String?
    let functions: [Function]?
    let points: [Point]?
    let x_range: [Double]?
    let y_range: [Double]?
    let kind: String?
    let labels: [String]?
    let series: [Series]?
    let steps: [Step]?
    let items: [Item]?
    let columns: [String]?
    let rows: [[String]]?
}
struct NovaResult: Equatable {
    let id: String
    let text: String
    let ok: Bool
    let cost: Double?
}
/// Background agents, schedules and their reports, from `/v1/work`.
struct NovaWork: Decodable, Equatable {
    struct Run: Decodable, Equatable, Identifiable { let id: String; let title: String; let kind: String; let started: String; let usesComputer: Bool; let latest: String? }
    struct Schedule: Decodable, Equatable, Identifiable { let id: String; let title: String; let `repeat`: String; let next: String; let usesComputer: Bool; let monitor: Bool; let runs: Int; let lastRun: String?; let lastResult: String? }
    struct Report: Decodable, Equatable, Identifiable { let id: Int; let title: String; let message: String; let ok: Bool; let source: String; let created_at: String; let visuals: [NovaVisual] }
    let running: [Run]
    let schedules: [Schedule]
    let reports: [Report]
    let awake: Bool
}
struct WorkMessage: Decodable { let message: String }
struct InputResult: Decodable { let text: String? }
struct ReleaseResult: Decodable { let released: Bool }
struct PairResult: Decodable { let id: String; let token: String; let owner: Bool?; let computer: String? }
struct PairingInvite: Equatable {
    let url: String
    let code: String
    let computer: String
}
/// Parses `nova://pair?v=1&u=…&c=…&n=…`. The link never carries a provider key.
func parsePairingLink(_ raw: String) -> PairingInvite? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text), url.scheme == "nova", url.host == "pair",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard value("v") == "1", let address = value("u"), let code = value("c"), let name = value("n"),
          let parsed = URL(string: address), parsed.scheme == "https", parsed.host != nil,
          parsed.user == nil, parsed.password == nil else { return nil }
    return PairingInvite(url: address, code: code, computer: name)
}
struct NovaAppChoice: Codable, Identifiable, Hashable {
    let bundleId: String
    let name: String
    var id: String { bundleId }
}
struct NovaFolderChoice: Decodable, Identifiable {
    let path: String
    let name: String
    var id: String { path }
}
struct NovaPairedDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let created_at: String
    let owner: Bool
    let current: Bool
}
struct NovaSetup: Decodable {
    struct Computer: Decodable { let name: String; let platform: String }
    struct Device: Decodable { let id: String; let name: String; let owner: Bool }
    struct Access: Decodable {
        let level: String
        let apps: [NovaAppChoice]
        let folders: [String]
        let chosen: Bool
        let levels: [String: String]?
    }
    struct Provider: Decodable {
        let configured: Bool
        let storage: String?
        let label: String
        let model: String
    }
    struct AI: Decodable {
        let selected: String
        let anthropic: Provider
        let openai: Provider
    }
    struct Permissions: Decodable {
        let installed: Bool
        let running: Bool
        let accessibility: Bool
        let screenRecording: Bool
    }
    struct Steps: Decodable {
        let paired: Bool
        let range: Bool
        let permissions: Bool
        let ai: Bool
    }
    let computer: Computer
    let device: Device
    let stopped: Bool
    let access: Access
    let ai: AI
    let permissions: Permissions?
    let steps: Steps?
}
struct KeySaveResult: Decodable {
    struct Test: Decodable { let ok: Bool?; let code: String?; let message: String? }
    let saved: Bool?
    let test: Test?
    let error: String?
}
struct CreatedWork: Decodable { let id: String?; let `repeat`: String?; let first: Double? }
struct JobsResponse: Decodable { let jobs: [NovaJob] }
struct CreatedJob: Decodable { let id: String; let status: String }
struct StopResult: Decodable { let stopped: Bool }
struct UnpairResult: Decodable { let unpaired: Bool }
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
    @Published private(set) var voiceTransitioning = false
    private var screenRevision = ""
    private var spoken: Set<String>?

    var working: Bool { chat.map { ["queued","running"].contains($0.status) } ?? false }
    @Published var result: NovaResult?
    @Published var liveScreen: Data?
    @Published var workStarted: Date?
    @Published var visuals: [NovaVisual] = []
    @Published var page = 0
    @Published var revealed: [Int:Int] = [:]
    /// A new conversation starts each time the app launches; Core remembers within it.
    let conversation = UUID().uuidString
    private var pacing: Task<Void,Never>?
    @Published var work: NovaWork?
    /// The newest report, shown as a banner on the face for a little while.
    @Published var banner: NovaWork.Report?
    @Published var controlling = false
    /// A view Nova asked to open: "screen" or "work".
    @Published var requestedView: String?
    @Published var setup: NovaSetup?
    @Published var pendingPair: PairingInvite?
    @Published var range: String?
    @Published var provider: NovaProviderRef?
    @Published var readySeen = UserDefaults.standard.bool(forKey: "nova.readySeen") {
        didSet { UserDefaults.standard.set(readySeen, forKey: "nova.readySeen") }
    }
    @Published var tutorialSeen = UserDefaults.standard.bool(forKey: "nova.tutorialSeen") {
        didSet { UserDefaults.standard.set(tutorialSeen, forKey: "nova.tutorialSeen") }
    }
    /// Setup that still needs a person: pairing, range, a key, or the first Ready screen.
    var needsSetup: Bool {
        if !tutorialSeen { return true }
        if !paired { return true }
        if !readySeen { return true }
        if let steps = setup?.steps { return !steps.range || !steps.ai }
        return false
    }
    func replayTutorial() {
        tutorialSeen = false
        readySeen = false
    }
    private var bannerTimer: Task<Void,Never>?
    private var seenReport: Int? = UserDefaults.standard.object(forKey: "nova.seenReport") as? Int {
        didSet { UserDefaults.standard.set(seenReport, forKey: "nova.seenReport") }
    }
    private var resultTimer: Task<Void,Never>?

    /// Nova's latest action point, as a fraction of the screen, from "… at x, y" descriptions.
    var target: CGPoint? {
        guard let chat, let event = chat.events.last(where: { $0.kind == "action" }),
              let match = event.description.firstMatch(of: /(\d+), (\d+)$/),
              let x = Double(match.1), let y = Double(match.2),
              let data = liveScreen ?? computerScreen, let image = UIImage(data: data), image.size.width > 0 else { return nil }
        let scale = image.scale
        return CGPoint(x: x / (image.size.width * scale), y: y / (image.size.height * scale))
    }

    var paired: Bool { KeychainToken.read() != nil }

    init() {
        // Deleting the app wipes UserDefaults but iOS often keeps the pairing token
        // in Keychain, so a reinstall used to skip the QR and look already set up.
        if !UserDefaults.standard.bool(forKey: "nova.pairedHere") {
            KeychainToken.clear()
        }
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

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true, timeout: TimeInterval = 15) async throws -> T {
        let base = try baseURL()
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw NovaError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
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

    /// Holds a scanned or typed invite so the person can confirm the Mac before pairing.
    func offerPair(_ invite: PairingInvite) {
        address = invite.url
        pairingCode = invite.code
        pendingPair = invite
        errorMessage = nil
    }
    func applyPairingLink(_ raw: String) -> Bool {
        guard let invite = parsePairingLink(raw) else { return false }
        offerPair(invite)
        return true
    }
    func pair() async {
        guard !paired, !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let deviceName = UIDevice.current.name
            let result: PairResult = try await request("/v1/pair", method: "POST", body: ["code": pairingCode, "deviceName": deviceName], authenticated: false)
            guard KeychainToken.save(result.token) else { throw NovaError.server("Could not save pairing credential in Keychain") }
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "nova.baseURL")
            UserDefaults.standard.set(true, forKey: "nova.pairedHere")
            pairingCode = ""
            pendingPair = nil
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
            range = status.range
            provider = status.provider
            if let latest: NovaSetup = try? await request("/v1/setup") { setup = latest }
            if computer?.owner == true {
                let latest: NovaWork = try await request("/v1/work")
                if latest != work { work = latest }
                announceReports(latest.reports)
            }
            if let latest = jobs.first(where: { ["ai.chat","computer.task"].contains($0.type) }) {
                let detail: NovaDetail = try await request("/v1/jobs/\(latest.id)")
                chat = detail
                if working { if workStarted == nil { workStarted = Date() } } else { workStarted = nil }
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
        if ["ai.chat", "computer.task"].contains(type) { listener.cancel() }
        do {
            let _: CreatedJob = try await request("/v1/jobs", method: "POST", body: ["type":type, "message":message, "conversation":conversation])
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func detail(_ id: String) async -> NovaDetail? {
        do { return try await request("/v1/jobs/\(id)") }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func emergencyStop() async {
        listener.cancel()
        speaker.stop()
        busy = true
        defer { busy = false }
        do {
            let _: StopResult = try await request("/v1/stop", method:"POST", body:[:])
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    /// The Mac's global range and this phone's pairing role are separate permissions.
    var effectiveAccessLabel: String {
        guard let owner = computer?.owner ?? setup?.device.owner else { return "Checking access" }
        guard owner else { return "Conversation only on this iPhone" }
        switch setup?.access.level ?? range {
        case "chat": return "Chat only"
        case "apps": return "Chosen apps and folders"
        case "full": return "Whole Mac"
        default: return "Access not chosen"
        }
    }

    /// Owner iPhones talk to the computer agent, which also handles plain conversation.
    @discardableResult
    func send(_ message: String) async -> Bool {
        listener.cancel()
        speaker.stop()
        controlling = false
        clearVisuals()
        // Refresh the role immediately before routing. Never silently downgrade an
        // owner to conversation-only because the first status poll has not completed.
        do {
            let status: NovaStatus = try await request("/v1/status")
            guard let current = status.computer else {
                throw NovaError.server("Couldn't verify this iPhone’s access. Reconnect to your Mac and try again.")
            }
            computer = current
            range = status.range
            provider = status.provider
            stopped = status.stopped
            connection = stopped ? "Emergency stopped" : "Mac connected"
            return await submit(current.owner ? "computer.task" : "ai.chat", message: message)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stopTask() async {
        stopSpeaking()
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

    func dismissResult() { resultTimer?.cancel(); result = nil }
    func clearVisuals() { pacing?.cancel(); visuals = []; revealed = [:]; page = 0 }
    func stopSpeaking() {
        speaker.stop()
        for (index, visual) in visuals.enumerated() { revealed[index] = visual.steps?.count ?? 0 }
    }

    /// Polls a free screenshot of the Mac while the live view is open, faster while Matthew drives.
    func watchScreen() async {
        while !Task.isCancelled {
            if let data = try? await fetchData("/v1/computer/live") { liveScreen = data }
            try? await Task.sleep(for: .milliseconds(controlling ? 150 : 700))
        }
    }

    /// Matthew's own mouse and keyboard input. The first input ends whatever Nova was doing.
    func input(_ body: [String: Any]) async {
        do {
            let _: InputResult = try await request("/v1/computer/input", method: "POST", body: body)
            if let data = try? await fetchData("/v1/computer/live") { liveScreen = data }
        } catch { errorMessage = error.localizedDescription }
    }
    func takeOver() {
        listener.cancel()
        stopSpeaking()
        controlling = true
        Task {
            do { let _: InputResult = try await request("/v1/computer/takeover", method: "POST", body: [:]) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func handBack() async {
        controlling = false
        do { let _: ReleaseResult = try await request("/v1/computer/release", method: "POST", body: [:]) }
        catch { errorMessage = error.localizedDescription }
    }

    func cancelWork(_ id: String) async {
        do {
            let _: WorkMessage = try await request("/v1/work/cancel", method: "POST", body: ["id": id])
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Reads each new report aloud once and shows it on the face. Reports that arrived
    /// before this iPhone first saw the list are treated as already read.
    private func announceReports(_ reports: [NovaWork.Report]) {
        guard let newest = reports.first?.id else { return }
        guard let seen = seenReport else { seenReport = newest; return }
        let fresh = reports.filter { $0.id > seen }.reversed()
        guard !fresh.isEmpty else { return }
        seenReport = newest
        for report in fresh {
            if voiceReplies && !listener.active && !controlling { speaker.say("\(report.title). \(Self.spoken(report.message))") }
            if !report.visuals.isEmpty && !working && !listener.active && !controlling { clearVisuals(); report.visuals.forEach(present) }
        }
        banner = fresh.last
        bannerTimer?.cancel()
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { withAnimation { self?.banner = nil } }
        }
    }
    func showReport(_ report: NovaWork.Report) {
        clearVisuals(); report.visuals.forEach(present)
    }
    /// The first few sentences, so a long report isn't read out in full.
    private static func spoken(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        guard line.count > 320 else { return line }
        let cut = line.prefix(320)
        return cut.lastIndex(of: ".").map { String(cut[...$0]) } ?? String(cut)
    }

    private func fetchData(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: try baseURL()) else { throw NovaError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(KeychainToken.read() ?? "")", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NovaError.server("Screen unavailable") }
        return data
    }

    func toggleListening() async {
        guard !voiceTransitioning, !busy, !stopped else { return }
        voiceTransitioning = true
        defer { voiceTransitioning = false }
        if listener.listening {
            let text = await listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { await send(text) }
        } else {
            guard !working else { return }
            stopSpeaking()
            dismissResult()
            do { try await listener.start() } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Reads Nova's narration and final reply aloud once each. Anything already on
    /// screen when the app launches is treated as heard.
    private func speakNew(_ detail: NovaDetail) {
        var lines: [(key: String, kind: String, text: String)] = detail.events.filter { ["narration","visual","open"].contains($0.kind) }.map { ($0.id, $0.kind, $0.description) }
        if detail.status == "succeeded", let reply = detail.result?["message"] { lines.append(("\(detail.id)-reply", "reply", reply.description)) }
        if detail.status == "failed", let error = detail.error { lines.append(("\(detail.id)-error", "error", error)) }
        guard var heard = spoken else { spoken = Set(lines.map(\.key)); return }
        for line in lines where !heard.contains(line.key) {
            heard.insert(line.key)
            if line.kind == "open" {
                if line.text == "control" { takeOver() } else { requestedView = line.text }
                continue
            }
            if line.kind == "visual" {
                if let data = line.text.data(using: .utf8), let visual = try? JSONDecoder().decode(NovaVisual.self, from: data) { present(visual) }
                continue
            }
            if voiceReplies && !listener.active { speaker.say(line.text) }
            if line.kind == "reply" || line.kind == "error" {
                var cost: Double?
                if case .number(let usd)? = detail.result?["estimatedUSD"] { cost = usd }
                result = NovaResult(id: detail.id, text: line.text, ok: line.kind == "reply", cost: cost)
                resultTimer?.cancel()
                resultTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    if !Task.isCancelled { self?.result = nil }
                }
            }
        }
        spoken = heard
    }

    /// Queues a visual. A board is written one step at a time as Nova says each step;
    /// the next visual appears once the board is finished.
    private func present(_ visual: NovaVisual) {
        let index = visuals.count
        visuals.append(visual)
        guard let steps = visual.steps, visual.type == "board", !steps.isEmpty else {
            if index > 0 && visuals[index-1].type == "board" && (revealed[index-1] ?? 0) < (visuals[index-1].steps?.count ?? 0) { return }
            withAnimation(.spring(duration: 0.6)) { page = index }
            return
        }
        revealed[index] = 0
        if index == 0 || visuals[index-1].type != "board" { page = index }
        let advance = { [weak self] in
            guard let self, self.visuals.indices.contains(index + 1) else { return }
            withAnimation(.spring(duration: 0.6)) { self.page = index + 1 }
        }
        if voiceReplies && !listener.active {
            for (step, line) in steps.enumerated() {
                speaker.say(line.say ?? line.write, onStart: { [weak self] in
                    guard let self, self.visuals.indices.contains(index) else { return }
                    withAnimation { self.page = index; self.revealed[index] = step + 1 }
                }, onFinish: step == steps.count - 1 ? advance : nil)
            }
        } else {
            pacing = Task { [weak self] in
                for step in steps.indices {
                    try? await Task.sleep(for: .seconds(step == 0 ? 0.3 : 2))
                    if Task.isCancelled { return }
                    withAnimation { self?.revealed[index] = step + 1 }
                }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { advance() }
            }
        }
    }

    func loadSetup() async {
        do { setup = try await request("/v1/setup") }
        catch { errorMessage = error.localizedDescription }
    }
    func listedApps() async -> [NovaAppChoice] {
        struct Wrap: Decodable { let apps: [NovaAppChoice] }
        return (try? await request("/v1/setup/apps") as Wrap)?.apps ?? []
    }
    func listedFolders(in parent: String = "~") async -> [NovaFolderChoice] {
        struct Wrap: Decodable { let folders: [NovaFolderChoice] }
        let path = parent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? parent
        return (try? await request("/v1/setup/folders?in=\(path)") as Wrap)?.folders ?? []
    }
    func setAccess(level: String, apps: [NovaAppChoice] = [], folders: [String] = []) async -> Bool {
        do {
            let body: [String: Any] = ["level": level, "apps": apps.map { ["bundleId": $0.bundleId, "name": $0.name] }, "folders": folders]
            let _: JSONValue = try await request("/v1/setup/access", method: "POST", body: body)
            await loadSetup(); await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func saveKey(provider: String, key: String) async -> String {
        do {
            let result: KeySaveResult = try await request("/v1/setup/key", method: "POST", body: ["provider": provider, "key": key], timeout: 30)
            await loadSetup(); await refresh()
            return result.test?.message ?? "Saved in the Mac's Keychain."
        } catch { errorMessage = error.localizedDescription; return error.localizedDescription }
    }
    func selectProvider(_ provider: String) async {
        do { let _: JSONValue = try await request("/v1/setup/provider", method: "POST", body: ["provider": provider]); await loadSetup() }
        catch { errorMessage = error.localizedDescription }
    }
    func removeKey(_ provider: String) async {
        do { let _: JSONValue = try await request("/v1/setup/key/remove", method: "POST", body: ["provider": provider]); await loadSetup(); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    func askMacPermissions() async {
        do { let _: JSONValue = try await request("/v1/setup/permissions", method: "POST", body: [:], timeout: 20); await loadSetup() }
        catch { errorMessage = error.localizedDescription }
    }
    func pairedDevices() async -> [NovaPairedDevice] {
        struct Wrap: Decodable { let devices: [NovaPairedDevice] }
        return (try? await request("/v1/devices") as Wrap)?.devices ?? []
    }
    func revokeDevice(_ id: String) async {
        do { let _: JSONValue = try await request("/v1/devices/revoke", method: "POST", body: ["id": id]); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    func startAgent(title: String, task: String) async -> Bool {
        do { let _: CreatedWork = try await request("/v1/work/agent", method: "POST", body: ["title": title, "task": task]); await refresh(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func addSchedule(_ body: [String: Any]) async -> Bool {
        do { let _: CreatedWork = try await request("/v1/work/schedule", method: "POST", body: body); await refresh(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func unpair() {
        Task {
            do { let _: UnpairResult = try await request("/v1/unpair", method: "POST", body: [:] as [String: Any]) } catch {}
            await MainActor.run { self.clearLocal() }
        }
    }
    private func clearLocal() {
        work = nil; banner = nil; setup = nil; pendingPair = nil; range = nil; provider = nil; readySeen = false
        UserDefaults.standard.removeObject(forKey: "nova.pairedHere")
        UserDefaults.standard.removeObject(forKey: "nova.baseURL")
        tutorialSeen = false
        listener.cancel(); speaker.stop(); KeychainToken.clear(); jobs = []; chat = nil; ai = nil; computer = nil; computerScreen = nil; connection = "Not connected"; errorMessage = nil
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
    private var utterances: Set<ObjectIdentifier> = []
    private var starts: [ObjectIdentifier: () -> Void] = [:]
    private var finishes: [ObjectIdentifier: () -> Void] = [:]
    override init() { super.init(); synthesizer.delegate = self }
    func say(_ text: String, onStart: (() -> Void)? = nil, onFinish: (() -> Void)? = nil) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        starts[ObjectIdentifier(utterance)] = onStart
        finishes[ObjectIdentifier(utterance)] = onFinish
        utterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
        speaking = true
    }
    func stop() { utterances.removeAll(); starts = [:]; finishes = [:]; synthesizer.stopSpeaking(at: .immediate); speaking = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utterances.contains(id) else { return }
            self.speaking = true; self.starts.removeValue(forKey: id)?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utterances.remove(id) != nil else { return }
            self.speaking = !self.utterances.isEmpty
            self.starts.removeValue(forKey: id)
            self.finishes.removeValue(forKey: id)?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utterances.remove(id) != nil else { return }
            self.speaking = !self.utterances.isEmpty
            self.starts.removeValue(forKey: id); self.finishes.removeValue(forKey: id)
        }
    }
}

/// Tap-to-talk dictation. Uses on-device recognition when the iPhone supports it.
@MainActor
final class Listener: ObservableObject {
    @Published private(set) var capture = VoiceCaptureState()
    @Published var errorMessage: String?
    private(set) var transcript = ""
    var listening: Bool { capture.listening }
    var active: Bool { capture.phase != .idle }
    let meter = VoiceMeter()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var ownsAudioSession = false
    private var recognitionFinished = false
    private var interruption: NSObjectProtocol?

    init() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.cancel() }
        }
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }

    func start() async throws {
        guard let id = capture.beginStart() else { return }
        transcript = ""; errorMessage = nil; recognitionFinished = false
        do {
            let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
            guard capture.accepts(id) else { return }
            guard speech == .authorized else { throw NovaError.server("Allow Speech Recognition for Nova in Settings → Privacy & Security.") }
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard capture.accepts(id) else { return }
            guard allowed else { throw NovaError.server("Allow the microphone for Nova in Settings → Privacy & Security.") }
            guard let recognizer, recognizer.isAvailable else { throw NovaError.server("Speech recognition is not available right now.") }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true)
            ownsAudioSession = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NovaError.server("The microphone is unavailable. Try again when your audio device is ready.") }
            let meter = self.meter
            meter.begin(id)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
                meter.update(Listener.loudness(buffer), for: id)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let terminal = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.capture.accepts(id) else { return }
                    if let text { self.transcript = text }
                    if terminal {
                        self.recognitionFinished = true
                        if self.capture.phase != .finishing {
                            self.capture.finish(id)
                            self.cleanUp()
                            self.errorMessage = "Listening ended before you sent a message. Tap Talk to try again."
                        }
                    }
                }
            }
            _ = capture.didStart(id)
        } catch {
            if capture.finish(id) { cleanUp() }
            throw error
        }
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
        // Clear listening immediately. A second tap cannot send this capture twice.
        guard let id = capture.beginFinishing() else { return "" }
        stopInput()
        meter.reset()
        request?.endAudio()
        // Allow the last word to finalize, without leaving the mic/glow on.
        for _ in 0..<12 {
            guard capture.accepts(id) else { return "" }
            guard !Task.isCancelled else { cancel(); return "" }
            if recognitionFinished { break }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { if capture.accepts(id) { cancel() }; return "" }
        }
        guard capture.finish(id) else { return "" }
        let text = transcript
        cleanUp()
        return text
    }

    func cancel() {
        capture.cancel()
        cleanUp()
    }
    private func stopInput() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
    private func cleanUp() {
        stopInput()
        meter.reset()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
