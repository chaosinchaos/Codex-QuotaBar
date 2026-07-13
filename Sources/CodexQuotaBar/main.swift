import AppKit
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let statusController = StatusController()
statusController.start()
RunLoop.main.run()

@MainActor
private final class StatusController: NSObject {
    private let service = CodexUsageService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let weeklyItem = NSMenuItem(title: "一周额度：读取中…", action: nil, keyEquivalent: "")
    private let resetCountItem = NSMenuItem(title: "使用限额重置次数：0次", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var refreshTimer: Timer?
    private var isRefreshing = false

    func start() {
        statusItem.button?.title = "⌁ --"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        weeklyItem.isEnabled = false
        resetCountItem.isEnabled = false
        updatedItem.isEnabled = false
        updatedItem.attributedTitle = NSAttributedString(
            string: "",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )

        menu.addItem(weeklyItem)
        menu.addItem(resetCountItem)
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshUsage), keyEquivalent: "r")
        menu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CodexQuotaBar", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        refreshTimer = Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(refreshUsage), userInfo: nil, repeats: true)
        refreshUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func refreshUsage() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusItem.button?.title = "⌁ …"

        Task {
            defer { isRefreshing = false }
            do {
                let snapshot = try await service.fetchUsage()
                show(snapshot: snapshot)
            } catch let error as LocalizedError {
                show(error: error.errorDescription ?? "读取额度失败。")
            } catch {
                show(error: "读取额度失败。")
            }
        }
    }

    @objc private func openCodex() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func show(snapshot: UsageSnapshot) {
        statusItem.button?.title = "⌁ 周 \(snapshot.weekly.remainingPercent)%"
        weeklyItem.title = snapshot.weekly.menuTitle("一周额度")
        resetCountItem.title = "使用限额重置次数：\(snapshot.resetCount)次"
        updatedItem.attributedTitle = NSAttributedString(
            string: "更新于 \(Date.now.formatted(date: .omitted, time: .shortened))",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
    }

    private func show(error: String) {
        statusItem.button?.title = "⌁ !"
        weeklyItem.title = error
        updatedItem.attributedTitle = NSAttributedString(
            string: "未能更新用量",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
    }
}

private struct UsageSnapshot {
    let weekly: UsageWindow
    let resetCount: Int
}

private struct UsageWindow {
    let usedPercent: Int
    let resetDate: Date

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    func menuTitle(_ name: String) -> String {
        let reset = resetDate.formatted(date: .abbreviated, time: .shortened)
        return "\(name)：剩余 \(remainingPercent)% · \(resetDate.relativeDescription) 重置（\(reset)）"
    }
}

private enum QuotaError: LocalizedError {
    case noCodexLogin
    case invalidResponse
    case loginExpired
    case server(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noCodexLogin: "未找到 Codex 登录信息。请先在 Codex 中登录。"
        case .invalidResponse: "Codex 返回的数据格式无法识别。"
        case .loginExpired: "Codex 登录已失效。请打开 Codex 后重新登录。"
        case let .server(statusCode): "Codex 用量服务暂不可用（\(statusCode)）。"
        }
    }
}

private struct CodexUsageService {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try loadCredentials()
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw QuotaError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 { throw QuotaError.loginExpired }
            throw QuotaError.server(statusCode: httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        guard let weekly = payload.rateLimit.primaryWindow else {
            throw QuotaError.invalidResponse
        }
        return UsageSnapshot(
            weekly: weekly.usageWindow,
            resetCount: payload.rateLimitResetCredits?.availableCount ?? 0
        )
    }

    private func loadCredentials() throws -> Credentials {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              !auth.tokens.accessToken.isEmpty,
              !auth.tokens.accountID.isEmpty else {
            throw QuotaError.noCodexLogin
        }
        return Credentials(accessToken: auth.tokens.accessToken, accountID: auth.tokens.accountID)
    }
}

private struct Credentials { let accessToken: String; let accountID: String }

private struct CodexAuthFile: Decodable {
    let tokens: Tokens
    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case accountID = "account_id" }
    }
}

private struct UsagePayload: Decodable {
    let rateLimit: RateLimit
    let rateLimitResetCredits: RateLimitResetCredits?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window" }
    }
    struct Window: Decodable {
        let usedPercent: Double
        let resetAt: Double
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" }
        var usageWindow: UsageWindow {
            UsageWindow(usedPercent: Int(usedPercent.rounded()), resetDate: Date(timeIntervalSince1970: resetAt))
        }
    }
    struct RateLimitResetCredits: Decodable {
        let availableCount: Int
        enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
    }
}

private extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
