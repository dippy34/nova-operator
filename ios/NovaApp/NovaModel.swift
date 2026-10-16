import Foundation
import SwiftUI
import Security
import LocalAuthentication

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
    let active: Bool
    let app: String?
    let expires: Double?
    let apps: [String]
    let busy: Bool
}
struct EndComputerResult: Decodable { let ended: Bool }
struct RejectedComputerResult: Decodable { let status: String }
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
/// Signed device requests remain a later milestone. Reviewed computer sessions are
/// restricted to the locally designated owner, expire, and bind each approval to one action.
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
    private var screenRevision = ""

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
                chat = try await request("/v1/jobs/\(latest.id)")
                let revision = latest.id + latest.updated_at
                if latest.type == "computer.task", status.computer?.active == true, screenRevision != revision {
                    var req = URLRequest(url: URL(string:"/v1/computer/screen/\(latest.id)",relativeTo:try baseURL())!)
                    req.setValue("Bearer \(KeychainToken.read() ?? "")",forHTTPHeaderField:"Authorization")
                    let (data,response) = try await session.data(for:req)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {computerScreen = data; screenRevision = revision}
                } else if latest.type != "computer.task" || status.computer?.active != true {computerScreen = nil}
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

    func startComputer(_ app: String) async {
        guard !busy else {return}
        busy = true; defer {busy = false}
        do { let _: NovaComputerStatus = try await request("/v1/computer/session",method:"POST",body:["app":app]); await refresh() }
        catch {errorMessage = error.localizedDescription}
    }

    func endComputer() async {
        busy = true; defer {busy = false}
        do {let _:EndComputerResult = try await request("/v1/computer/end",method:"POST",body:[:]);computerScreen = nil;await refresh()}
        catch {errorMessage = error.localizedDescription}
    }

    func reviewComputer(_ id: String, approvalID: String?, approve: Bool) async {
        guard !busy else {return}
        guard let approvalID else {errorMessage = "Refresh the proposed action before approving it.";return}
        busy = true; defer {busy = false}
        do {
            if approve {
                let confirmed = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"Approve this exact Nova computer action")
                guard confirmed else {return}
                let _:CreatedJob = try await request("/v1/computer/approve/\(id)",method:"POST",body:["approvalID":approvalID])
            } else {
                let _:RejectedComputerResult = try await request("/v1/computer/reject/\(id)",method:"POST",body:["approvalID":approvalID])
            }
            await refresh()
        } catch {errorMessage = error.localizedDescription}
    }

    func unpair() {
        KeychainToken.clear(); jobs = []; chat = nil; ai = nil; computer = nil; computerScreen = nil; connection = "Not connected"; errorMessage = nil
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
