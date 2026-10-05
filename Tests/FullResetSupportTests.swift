import Foundation

@main
struct FullResetSupportTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--read-only") {
            let count = try await CodexResetClient.readOnlyCheck()
            print("Read-only Codex connection OK; available Full resets: \(count)")
            return
        }
        let now = Date.now
        let account = "test-account"
        let credit = FullResetCredit(id: "test-credit", expiresAt: now.addingTimeInterval(86400))
        let plan = FullResetPlan.make(accountID: account, credit: credit, now: now)!
        check(plan.fireAt == credit.expiresAt.addingTimeInterval(-7200), "two-hour lead")
        check(FullResetPlan.make(accountID: account, credit: .init(id: "expired", expiresAt: now), now: now) == nil, "expired credit rejected")
        let soon = FullResetCredit(id: "soon", expiresAt: now.addingTimeInterval(1800))
        check(FullResetPlan.make(accountID: account, credit: soon, now: now)?.fireAt == now, "catch up inside lead window")
        check(plan.retry(now: now)?.fireAt == now.addingTimeInterval(300), "one-shot five-minute retry")
        check(plan.retry(now: credit.expiresAt.addingTimeInterval(-61))?.fireAt == credit.expiresAt.addingTimeInterval(-60), "retry deadline margin")
        check(plan.retry(now: credit.expiresAt.addingTimeInterval(-60)) == nil, "no retry at deadline")

        let suite = "quotabar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        var keys: [String] = []
        var outcome = FullResetOutcome.reset
        var shouldFail = false
        let scheduler = FullResetScheduler(defaults: defaults) { _, attempt in
            calls += 1
            keys.append(attempt.idempotencyKey)
            if shouldFail { throw FullResetError.timedOut }
            return outcome
        }
        check(!scheduler.enabled, "public default off")
        scheduler.update(accountID: account, credit: credit, detailsAvailable: true)
        check(scheduler.nextExecution == nil, "disabled does not schedule")
        scheduler.enabled = true
        check(scheduler.nextExecution == plan.fireAt, "enable arms saved plan")
        scheduler.update(accountID: account, credit: nil, detailsAvailable: false)
        check(scheduler.nextExecution == plan.fireAt, "transient details failure preserves plan")
        let persisted = try JSONDecoder().decode(FullResetPlan.self, from: defaults.data(forKey: "autoFullResetPlan")!)
        check(persisted == plan, "persist exact absolute deadline")
        let restored = FullResetScheduler(defaults: defaults) { _, _ in fatalError("unexpected real execution") }
        check(restored.nextExecution == plan.fireAt, "restart restores timer")
        restored.enabled = false
        scheduler.enabled = false
        await scheduler.execute(plan)
        check(calls == 0, "disabled execution does not redeem")
        scheduler.enabled = true
        scheduler.update(accountID: "other-account", credit: nil, detailsAvailable: false)
        check(scheduler.nextExecution == nil, "account change clears plan even with unavailable details")
        await scheduler.execute(plan)
        check(calls == 0, "stale timer cannot redeem after account change")

        let due = FullResetPlan.make(accountID: account, credit: soon, now: .now)!
        defaults.set(try JSONEncoder().encode(due), forKey: "autoFullResetPlan")
        scheduler.enabled = false
        let executing = FullResetScheduler(defaults: defaults) { _, attempt in
            calls += 1
            keys.append(attempt.idempotencyKey)
            if shouldFail { throw FullResetError.timedOut }
            return outcome
        }
        executing.enabled = true
        shouldFail = true
        await executing.execute(due)
        check(calls == 1 && defaults.data(forKey: "autoFullResetAttempt") != nil, "ambiguous failure preserves attempt")
        let retry = try JSONDecoder().decode(FullResetPlan.self, from: defaults.data(forKey: "autoFullResetPlan")!)
        check(retry.fireAt > .now && executing.status.contains("重试"), "failure arms one-shot retry")
        shouldFail = false
        await executing.execute(retry)
        check(calls == 2 && keys[0] == keys[1], "retry reuses idempotency key")
        check(executing.lastSuccess != nil && defaults.data(forKey: "autoFullResetPlan") == nil, "success persisted and timer cleared")
        executing.enabled = false

        // An expired persisted plan may be encountered after a long sleep or shutdown.
        let expired = FullResetPlan(accountID: account, credit: .init(id: "expired", expiresAt: .now.addingTimeInterval(-1)), fireAt: .now.addingTimeInterval(-10))
        defaults.set(try JSONEncoder().encode(expired), forKey: "autoFullResetPlan")
        let waking = FullResetScheduler(defaults: defaults) { _, _ in calls += 1; return .reset }
        waking.enabled = true
        await waking.execute(expired)
        check(calls == 2 && waking.nextExecution == nil, "wake after expiry skips consume")
        waking.enabled = false

        let lastMinute = FullResetPlan.make(accountID: account, credit: .init(id: "last-minute", expiresAt: .now.addingTimeInterval(30)), now: .now)!
        defaults.set(try JSONEncoder().encode(lastMinute), forKey: "autoFullResetPlan")
        outcome = .nothingToReset
        let finalAttempt = FullResetScheduler(defaults: defaults) { _, _ in calls += 1; return outcome }
        finalAttempt.enabled = true
        await finalAttempt.execute(lastMinute)
        finalAttempt.update(accountID: account, credit: lastMinute.credit, detailsAvailable: true)
        check(calls == 3 && finalAttempt.nextExecution == nil, "routine refresh cannot rearm final failure")
        finalAttempt.enabled = false
        print("PASS: 21 policy, persistence and mocked redemption checks; no real credits consumed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
    }
}
