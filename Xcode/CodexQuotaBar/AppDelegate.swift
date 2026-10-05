import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct CodexQuotaBarApp: App {
    @StateObject private var quota: QuotaModel
    @StateObject private var scheduler: FullResetScheduler

    init() {
        let scheduler = FullResetScheduler()
        _scheduler = StateObject(wrappedValue: scheduler)
        _quota = StateObject(wrappedValue: QuotaModel(scheduler: scheduler))
    }

    var body: some Scene {
        MenuBarExtra {
            Text(quota.weeklyMenuText)
            Text(quota.resetCountText)
            Text(quota.resetExpiryText)
            Text(quota.updateText)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("到期前自动使用 Full reset", isOn: $scheduler.enabled)
            Text(scheduler.status).foregroundStyle(.secondary)
            if let lastSuccess = scheduler.lastSuccess {
                Text(lastSuccess).foregroundStyle(.secondary)
            }

            Divider()

            Button("立即刷新") {
                Task { await quota.refresh() }
            }
            .disabled(quota.isRefreshing)

            Button("打开 Codex") {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
            }

            Divider()

            Button("退出 CodexQuotaBar") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text(quota.menuBarText)
                .monospacedDigit()
        }
    }
}

@MainActor
final class QuotaModel: ObservableObject {
    @Published private var snapshot: QuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?
    private let scheduler: FullResetScheduler

    init(scheduler: FullResetScheduler) {
        self.scheduler = scheduler
        scheduler.onRefresh = { [weak self] in
            Task { await self?.refresh() }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self.refresh()
            }
        }
    }

    var menuBarText: String {
        if let snapshot { return "⌁ 周 \(snapshot.weeklyRemaining)%" }
        return isRefreshing ? "⌁ …" : "⌁ !"
    }

    var weeklyMenuText: String {
        guard let snapshot else { return "一周额度：暂不可用" }
        return "一周额度：剩余 \(snapshot.weeklyRemaining)% · \(snapshot.weeklyReset) 重置"
    }

    var resetCountText: String {
        guard let snapshot else { return "使用限额重置次数：暂不可用" }
        return "使用限额重置次数：\(snapshot.resetCount)次"
    }

    var resetExpiryText: String {
        guard let snapshot else { return "最早 Full reset 到期：暂不可用" }
        guard let expiration = snapshot.nearestFullResetExpiration else {
            return "最早 Full reset 到期：暂无"
        }
        return "最早 Full reset 到期：\(expiration.formatted(date: .abbreviated, time: .shortened))"
    }

    var updateText: String {
        if let updatedAt { return "更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))" }
        return lastError ?? "正在读取额度…"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for attempt in 0..<3 {
            do {
                let newSnapshot = try await CodexUsageClient.fetch()
                snapshot = newSnapshot
                updatedAt = .now
                lastError = nil
                scheduler.update(accountID: newSnapshot.accountID,
                                 credit: newSnapshot.nearestFullResetCredit,
                                 detailsAvailable: newSnapshot.resetDetailsAvailable)
                return
            } catch {
                guard attempt < 2 else {
                    lastError = snapshot == nil ? "无法读取额度；请确认 Codex 已登录" : "暂时无法更新，正在显示上次成功数据"
                    return
                }
                try? await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
    }
}

private struct QuotaSnapshot {
    let accountID: String
    let weeklyRemaining: Int
    let weeklyReset: String
    let resetCount: Int
    let nearestFullResetCredit: FullResetCredit?
    let resetDetailsAvailable: Bool
    var nearestFullResetExpiration: Date? { nearestFullResetCredit?.expiresAt }
}

private enum CodexUsageClient {
    static func fetch() async throws -> QuotaSnapshot {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        let auth = try JSONDecoder().decode(AuthFile.self, from: Data(contentsOf: authURL))
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("CodexQuotaBar/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
        let rateLimit = usageResponse.rateLimit
        guard let weekly = rateLimit.primaryWindow else { throw URLError(.cannotParseResponse) }
        var nearestFullResetCredit: FullResetCredit?
        var resetDetailsAvailable = false
        do {
            nearestFullResetCredit = try await fetchNearestFullResetCredit(auth: auth)
            resetDetailsAvailable = true
        } catch { /* Retain a saved schedule during temporary details-service failures. */ }
        return QuotaSnapshot(
            accountID: auth.tokens.accountID,
            weeklyRemaining: max(0, 100 - Int(weekly.usedPercent.rounded())),
            weeklyReset: Date(timeIntervalSince1970: weekly.resetAt).formatted(date: .abbreviated, time: .shortened),
            resetCount: usageResponse.rateLimitResetCredits?.availableCount ?? 0,
            nearestFullResetCredit: nearestFullResetCredit,
            resetDetailsAvailable: resetDetailsAvailable
        )
    }

    private static func fetchNearestFullResetCredit(auth: AuthFile) async throws -> FullResetCredit? {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("CodexQuotaBar/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(ResetCreditDetailsResponse.self, from: data)
        return payload.credits
            .filter { $0.status == "available" && $0.resetType == "codex_rate_limits" }
            .compactMap { credit -> FullResetCredit? in
                guard let expiry = credit.expiresAt.flatMap(parseISO8601Date), expiry > .now else { return nil }
                return FullResetCredit(id: credit.id, expiresAt: expiry)
            }
            .min { $0.expiresAt < $1.expiresAt }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct AuthFile: Decodable {
    let tokens: Tokens
    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case accountID = "account_id" }
    }
}

private struct UsageResponse: Decodable {
    let rateLimit: RateLimit
    let rateLimitResetCredits: RateLimitResetCredits?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
    struct RateLimit: Decodable {
        let primaryWindow: UsageWindow?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window" }
    }
    struct UsageWindow: Decodable {
        let usedPercent: Double
        let resetAt: Double
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" }
    }
    struct RateLimitResetCredits: Decodable {
        let availableCount: Int
        enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
    }
}

private struct ResetCreditDetailsResponse: Decodable {
    let credits: [Credit]

    struct Credit: Decodable {
        let id: String
        let resetType: String
        let status: String
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case resetType = "reset_type"
            case status
            case expiresAt = "expires_at"
        }
    }
}
