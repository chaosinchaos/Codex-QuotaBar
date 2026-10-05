import AppKit
import Foundation

struct FullResetCredit: Codable, Equatable {
    let id: String
    let expiresAt: Date
}

struct FullResetPlan: Codable, Equatable {
    let accountID: String
    let credit: FullResetCredit
    let fireAt: Date

    static let leadTime: TimeInterval = 2 * 60 * 60

    static func make(accountID: String, credit: FullResetCredit, now: Date) -> Self? {
        guard credit.expiresAt > now else { return nil }
        return Self(accountID: accountID, credit: credit,
                    fireAt: max(now, credit.expiresAt.addingTimeInterval(-leadTime)))
    }

    func retry(now: Date) -> Self? {
        // One-shot retries leave a margin before expiry; never send an expired credit.
        let lastChance = credit.expiresAt.addingTimeInterval(-60)
        guard lastChance > now else { return nil }
        return Self(accountID: accountID, credit: credit,
                    fireAt: min(now.addingTimeInterval(300), lastChance))
    }
}

struct FullResetAttempt: Codable {
    let accountID: String
    let creditID: String
    let idempotencyKey: String
}

enum FullResetOutcome: String, Decodable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
    case expired, creditUnavailable
}

enum FullResetError: LocalizedError {
    case unavailable, unsupported, accountChanged, timedOut, invalidResponse, verificationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到 Codex 客户端，请安装或更新 Codex"
        case .unsupported: return "Codex 客户端版本过旧，需更新后才能指定到期的 Full reset"
        case .accountChanged: return "Codex 登录账号已变化，已停止本次自动重置"
        case .timedOut: return "连接 Codex 超时，将在到期前重试"
        case .invalidResponse: return "Codex 暂时无法处理自动重置"
        case .verificationFailed: return "重置结果尚未确认，将使用相同请求编号核对"
        }
    }
}

// All blocking process I/O runs on a background task. The menu's main thread stays free.
enum CodexResetClient {
    struct Limits: Decodable {
        let accountId: String?
        let rateLimitResetCredits: Credits?
    }
    struct Credits: Decodable { let availableCount: Int; let credits: [Credit]? }
    struct Credit: Decodable {
        let id: String
        let resetType: String
        let status: String
        let expiresAt: Double?
    }
    struct ConsumeResponse: Decodable { let outcome: FullResetOutcome }

    static func consume(plan: FullResetPlan, attempt: FullResetAttempt) async throws -> FullResetOutcome {
        try await Task.detached(priority: .utility) {
            let rpc = try CodexRPC()
            defer { rpc.close() }
            guard attempt.accountID == plan.accountID, attempt.creditID == plan.credit.id else {
                throw FullResetError.accountChanged
            }
            let before: Limits = try rpc.call("account/rateLimits/read")
            guard let accountID = before.accountId else { throw FullResetError.invalidResponse }
            guard accountID == plan.accountID else { throw FullResetError.accountChanged }
            guard let rows = before.rateLimitResetCredits?.credits else {
                throw FullResetError.invalidResponse
            }
            guard let selected = rows.first(where: { $0.id == plan.credit.id && $0.status == "available" && $0.resetType == "codexRateLimits" }) else {
                // Retry the same logical request after an ambiguous prior result. The server
                // returns alreadyRedeemed if that request succeeded before the connection failed.
                let response: ConsumeResponse = try rpc.call("account/rateLimitResetCredit/consume", params: [
                    "creditId": plan.credit.id, "idempotencyKey": attempt.idempotencyKey,
                ])
                guard response.outcome == .alreadyRedeemed else { return .creditUnavailable }
                let _: Limits = try rpc.call("account/rateLimits/read")
                return .alreadyRedeemed
            }
            guard let expiration = selected.expiresAt, expiration > Date.now.timeIntervalSince1970 else {
                return .expired
            }
            // Revalidate the deadline on the server's fresh record before performing a write.
            guard expiration - Date.now.timeIntervalSince1970 <= FullResetPlan.leadTime else {
                throw FullResetError.invalidResponse
            }
            let response: ConsumeResponse = try rpc.call("account/rateLimitResetCredit/consume", params: [
                "creditId": plan.credit.id, "idempotencyKey": attempt.idempotencyKey,
            ])
            let after: Limits = try rpc.call("account/rateLimits/read")
            if response.outcome == .reset || response.outcome == .alreadyRedeemed {
                guard let remaining = after.rateLimitResetCredits?.credits,
                      !remaining.contains(where: { $0.id == selected.id && $0.status == "available" }) else {
                    throw FullResetError.verificationFailed
                }
            }
            return response.outcome
        }.value
    }

    static func readOnlyCheck() async throws -> Int {
        try await Task.detached(priority: .utility) {
            let rpc = try CodexRPC()
            defer { rpc.close() }
            let limits: Limits = try rpc.call("account/rateLimits/read")
            return limits.rateLimitResetCredits?.availableCount ?? 0
        }.value
    }
}

private final class CodexRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var sequence = 0
    private var buffer = Data()

    init() throws {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FullResetError.unavailable
        }
        // The selected credit must be supported; older Codex clients can silently
        // ignore creditId and redeem a different credit, so check the local schema first.
        try Self.validateSchema(binary: binary)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let _: Empty = try call("initialize", params: ["clientInfo": ["name": "quotabar_full_reset", "version": "1.0.7"]])
            try send(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    private struct Empty: Decodable {}

    private static func validateSchema(binary: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemaProcess = Process()
        schemaProcess.executableURL = URL(fileURLWithPath: binary)
        schemaProcess.arguments = ["app-server", "generate-json-schema", "--out", directory.path]
        schemaProcess.standardOutput = FileHandle.nullDevice
        schemaProcess.standardError = FileHandle.nullDevice
        try schemaProcess.run()
        let timeout = DispatchWorkItem { if schemaProcess.isRunning { schemaProcess.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        schemaProcess.waitUntilExit()
        timeout.cancel()
        let file = directory.appendingPathComponent("v2/ConsumeAccountRateLimitResetCreditParams.json")
        guard schemaProcess.terminationStatus == 0,
              let data = try? Data(contentsOf: file),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = schema["properties"] as? [String: Any], properties["creditId"] != nil else {
            throw FullResetError.unsupported
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func call<T: Decodable>(_ method: String, params: [String: Any]? = nil) throws -> T {
        sequence += 1
        let id = sequence
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        let timeout = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
        defer { timeout.cancel() }
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      response["id"] as? Int == id else { continue }
                guard response["error"] == nil, let result = response["result"] else {
                    throw FullResetError.invalidResponse
                }
                return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw FullResetError.timedOut }
            buffer.append(data)
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
    }
}

@MainActor
final class FullResetScheduler: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "autoFullResetEnabled")
            if enabled {
                stoppedCreditID = nil
                defaults.removeObject(forKey: "autoFullResetStoppedCredit")
                onRefresh?()
                if let plan { arm(plan) }
            } else {
                timer?.invalidate()
                nextExecution = nil
                status = "自动重置：已关闭"
            }
        }
    }
    @Published private(set) var nextExecution: Date?
    @Published private(set) var status = "自动重置：等待额度数据"
    @Published private(set) var lastSuccess: String?
    var onRefresh: (() -> Void)?
    private let defaults: UserDefaults
    private let consume: (FullResetPlan, FullResetAttempt) async throws -> FullResetOutcome
    private var stoppedCreditID: String?
    private var plan: FullResetPlan?
    private var attempt: FullResetAttempt?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var isExecuting = false

    init(defaults: UserDefaults = .standard,
         consume: @escaping (FullResetPlan, FullResetAttempt) async throws -> FullResetOutcome = CodexResetClient.consume) {
        self.defaults = defaults
        self.consume = consume
        stoppedCreditID = defaults.string(forKey: "autoFullResetStoppedCredit")
        enabled = defaults.bool(forKey: "autoFullResetEnabled")
        lastSuccess = defaults.string(forKey: "autoFullResetLastResult")
        if let data = defaults.data(forKey: "autoFullResetPlan") { plan = try? JSONDecoder().decode(FullResetPlan.self, from: data) }
        if let data = defaults.data(forKey: "autoFullResetAttempt") { attempt = try? JSONDecoder().decode(FullResetAttempt.self, from: data) }
        if enabled, let plan { arm(plan) }
        if !enabled { status = "自动重置：已关闭" }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileAfterWake() }
        }
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileAfterWake() }
        }
    }

    func update(accountID: String, credit: FullResetCredit?, detailsAvailable: Bool) {
        if isExecuting { return }
        if let plan, plan.accountID != accountID { clear() }
        guard detailsAvailable else { return }
        guard let credit, let fresh = FullResetPlan.make(accountID: accountID, credit: credit, now: .now) else {
            clear()
            status = enabled ? "自动重置：暂无可安排的 Full reset" : "自动重置：已关闭"
            return
        }
        // A final failure must not be rearmed by routine quota refreshes.
        if stoppedCreditID == credit.id { return }
        if plan?.credit == credit, plan?.accountID == accountID, timer?.isValid == true { return }
        plan = fresh
        persistPlan()
        if enabled { arm(fresh) }
    }

    private func reconcileAfterWake() {
        guard enabled else { return }
        onRefresh?()
        if let plan { arm(plan) }
    }

    private func arm(_ plan: FullResetPlan) {
        timer?.invalidate()
        guard enabled, !isExecuting else { return }
        nextExecution = max(plan.fireAt, .now)
        status = "自动重置：\(nextExecution!.formatted(date: .abbreviated, time: .shortened)) 执行"
        let oneShot = Timer(fire: nextExecution!, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.execute(plan) }
        }
        timer = oneShot
        RunLoop.main.add(oneShot, forMode: .common)
    }

    func execute(_ firedPlan: FullResetPlan) async {
        guard enabled, !isExecuting, plan == firedPlan else { return }
        guard firedPlan.credit.expiresAt > .now else {
            clear()
            status = "自动重置：该 Full reset 已过期，等待刷新"
            onRefresh?()
            return
        }
        isExecuting = true
        nextExecution = nil
        status = "自动重置：正在执行…"
        if attempt?.accountID != firedPlan.accountID || attempt?.creditID != firedPlan.credit.id {
            attempt = FullResetAttempt(accountID: firedPlan.accountID, creditID: firedPlan.credit.id, idempotencyKey: UUID().uuidString)
            defaults.set(try? JSONEncoder().encode(attempt), forKey: "autoFullResetAttempt")
        }
        do {
            let outcome = try await consume(firedPlan, attempt!)
            attempt = nil
            defaults.removeObject(forKey: "autoFullResetAttempt")
            isExecuting = false
            switch outcome {
            case .reset, .alreadyRedeemed:
                clear()
                let result = "\(Date.now.formatted(date: .abbreviated, time: .shortened)) 自动重置成功"
                defaults.set(result, forKey: "autoFullResetLastResult")
                lastSuccess = result
                status = result
            case .nothingToReset:
                retry(firedPlan, message: "暂无可重置的额度窗口")
            case .noCredit, .expired, .creditUnavailable:
                clear()
                status = "自动重置：该 Full reset 已不可用"
            }
        } catch FullResetError.accountChanged {
            isExecuting = false
            clear()
            status = FullResetError.accountChanged.errorDescription!
        } catch {
            isExecuting = false
            retry(firedPlan, message: (error as? LocalizedError)?.errorDescription ?? "连接失败")
        }
        onRefresh?()
    }

    private func retry(_ previous: FullResetPlan, message: String) {
        guard enabled, let retry = previous.retry(now: .now) else {
            stoppedCreditID = previous.credit.id
            defaults.set(previous.credit.id, forKey: "autoFullResetStoppedCredit")
            clear()
            status = "自动重置：\(message)，未完成"
            return
        }
        plan = retry
        persistPlan()
        arm(retry)
        status = "自动重置：\(message)，\(retry.fireAt.formatted(date: .omitted, time: .shortened)) 重试"
    }

    private func persistPlan() { defaults.set(try? JSONEncoder().encode(plan), forKey: "autoFullResetPlan") }

    private func clear() {
        timer?.invalidate()
        timer = nil
        plan = nil
        nextExecution = nil
        attempt = nil
        defaults.removeObject(forKey: "autoFullResetPlan")
        defaults.removeObject(forKey: "autoFullResetAttempt")
    }
}
