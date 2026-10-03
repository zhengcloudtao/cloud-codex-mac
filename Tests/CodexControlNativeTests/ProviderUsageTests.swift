import XCTest
@testable import CloudCodex

final class ProviderUsageTests: XCTestCase {
    private func provider(_ service: SupportedModelService = .deepseek) -> ModelProviderConfiguration {
        var value = ModelProviderConfiguration(enabled: true)
        value.select(service)
        return value
    }
    private func tokens(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "cachedInputTokens": cached,
         "reasoningOutputTokens": reasoning, "totalTokens": input + output]
    }
    private func usage(_ last: [String: Any], total: [String: Any], turn: String = "turn") -> [String: Any] {
        ["threadId": "thread", "turnId": turn, "tokenUsage": ["last": last, "total": total]]
    }

    func testHistoricalTotalsAreExcludedAndRepeatedEventsAreDeduplicated() throws {
        var ledger = ProviderUsageLedger()
        let first = usage(tokens(100, 20, cached: 30, reasoning: 5), total: tokens(1100, 120, cached: 330, reasoning: 25))
        XCTAssertTrue(ledger.consume("thread/tokenUsage/updated", params: first, configuration: provider()))
        XCTAssertFalse(ledger.consume("thread/tokenUsage/updated", params: first, configuration: provider()))
        var saved = try JSONDecoder().decode(ProviderUsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(saved.consume("thread/tokenUsage/updated", params: first, configuration: provider()))
        let second = usage(tokens(50, 10, cached: 10, reasoning: 3), total: tokens(1150, 130, cached: 340, reasoning: 28))
        XCTAssertTrue(saved.consume("thread/tokenUsage/updated", params: second, configuration: provider()))
        let summary = try XCTUnwrap(saved.summaries().first)
        XCTAssertEqual(summary.calls, 2)
        XCTAssertEqual(summary.turns, 1)
        XCTAssertEqual(summary.tokens.total, 180)
        XCTAssertEqual(summary.tokens.cached, 40)
        XCTAssertEqual(summary.tokens.reasoning, 8)
        // A late, older cumulative event must not increase either counter.
        XCTAssertFalse(saved.consume("thread/tokenUsage/updated", params: first, configuration: provider()))
    }

    func testNewTurnsDoNotImportPriorUsageAndMissingUsageIsExplicit() throws {
        var ledger = ProviderUsageLedger()
        let config = provider()
        _ = ledger.consume("turn/started", params: ["threadId": "thread", "turn": ["id": "one"]], configuration: config)
        _ = ledger.consume("turn/completed", params: ["threadId": "thread", "turn": ["id": "one", "status": "failed"]], configuration: config)
        _ = ledger.consume("thread/tokenUsage/updated", params: usage(tokens(10, 2), total: tokens(9010, 902), turn: "two"), configuration: config)
        _ = ledger.consume("turn/completed", params: ["threadId": "thread", "turn": ["id": "two", "status": "completed"]], configuration: config)
        let summary = try XCTUnwrap(ledger.summaries().first)
        XCTAssertEqual(summary.turns, 2)
        XCTAssertEqual(summary.calls, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.missingUsage, 1)
        XCTAssertEqual(summary.tokens.total, 12)
    }

    func testProvidersAndModelsAreSeparatedAndTimeRangeFilters() throws {
        var ledger = ProviderUsageLedger()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let event = usage(tokens(10, 2), total: tokens(10, 2))
        _ = ledger.consume("thread/tokenUsage/updated", params: event, configuration: provider(), now: oldDate)
        _ = ledger.consume("thread/tokenUsage/updated", params: event, configuration: provider(.aliyun), now: newDate)
        var another = provider(); another.modelID = "deepseek-v4-pro"
        _ = ledger.consume("thread/tokenUsage/updated", params: event, configuration: another, now: newDate)
        XCTAssertEqual(ledger.summaries().count, 3)
        XCTAssertEqual(ledger.summaries(since: newDate).count, 2)
        var disabled = provider(); disabled.enabled = false
        XCTAssertFalse(ledger.consume("thread/tokenUsage/updated", params: event, configuration: disabled))
    }

    func testInvalidUsageCannotBecomeZeroTokensOrSuccessfulCalls() throws {
        var ledger = ProviderUsageLedger()
        _ = ledger.consume("thread/tokenUsage/updated", params: usage([:], total: [:]), configuration: provider())
        XCTAssertEqual(ledger.summaries().first?.calls, 0)
        XCTAssertEqual(ledger.summaries().first?.missingUsage, 1)
        _ = ledger.consume("thread/tokenUsage/updated", params: usage(tokens(0, 0), total: tokens(0, 0)), configuration: provider())
        XCTAssertEqual(ledger.summaries().first?.calls, 0)
        XCTAssertNil(ProviderUsageLedger.Tokens(json: tokens(-1, 2)))
        var bad = tokens(1, 2); bad["inputTokens"] = true
        XCTAssertNil(ProviderUsageLedger.Tokens(json: bad))
    }

    func testDailyTrendsFillGapsSeparateModelsAndMatchTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))
        var ledger = ProviderUsageLedger()
        var flash = provider(); flash.modelID = "deepseek-flash"
        var pro = provider(); pro.modelID = "deepseek-v4-pro"
        _ = ledger.consume("thread/tokenUsage/updated", params: usage(tokens(10, 2), total: tokens(10, 2)), configuration: flash, now: start)
        _ = ledger.consume("thread/tokenUsage/updated", params: usage(tokens(20, 3), total: tokens(20, 3), turn: "two"), configuration: flash, now: start.addingTimeInterval(3600))
        _ = ledger.consume("turn/started", params: ["threadId": "thread", "turn": ["id": "missing"]], configuration: pro, now: end)
        let points = ledger.dailySummaries(since: start, through: end, calendar: calendar)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(Set(points.map(\.id)).count, 6)
        let first = try XCTUnwrap(points.first { $0.date == start && $0.summary.model == flash.modelID })
        XCTAssertEqual(first.summary.calls, 2)
        XCTAssertEqual(first.summary.tokens.total, 35)
        let gap = points.filter { $0.date == calendar.date(byAdding: .day, value: 1, to: start) }
        XCTAssertEqual(gap.count, 2)
        XCTAssertTrue(gap.allSatisfy { $0.summary.turns == 0 && $0.summary.tokens.total == 0 })
        XCTAssertEqual(points.last?.summary.missingUsage, 1)
        for summary in ledger.summaries(since: start) {
            let series = points.filter { $0.summary.provider == summary.provider && $0.summary.model == summary.model }
            XCTAssertEqual(series.reduce(Int64(0)) { $0 + $1.summary.tokens.total }, summary.tokens.total)
            XCTAssertEqual(series.reduce(0) { $0 + $1.summary.turns }, summary.turns)
        }
        XCTAssertEqual(ledger.dailySummaries(since: end, through: end, calendar: calendar).count, 1)
        XCTAssertTrue(ProviderUsageLedger().dailySummaries().isEmpty)
    }

    func testDailyTrendUsesLocalDaysAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 30)))
        let entry = ProviderUsageLedger.Entry(id: "late", provider: "DeepSeek", model: "deepseek-flash", startedAt: late)
        let ledger = ProviderUsageLedger(entries: [entry])
        let points = ledger.dailySummaries(since: start, through: end, calendar: calendar)
        XCTAssertEqual(points.map { calendar.component(.day, from: $0.date) }, [7, 8, 9])
        XCTAssertEqual(points.map { $0.summary.turns }, [0, 1, 0])
        XCTAssertEqual(ledger.dailySummaries(through: end, calendar: calendar).count, 2)
    }

    @MainActor
    func testBackgroundThreadUsageIsPersistedByAppModel() throws {
        let suite = "ProviderUsageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(provider()), forKey: ModelProviderConfiguration.defaultsKey)
        let app = AppModel(remoteDefaults: defaults)
        app.selectedThreadID = "different-thread"
        app.handleEvent("thread/tokenUsage/updated", usage(tokens(100, 20), total: tokens(100, 20)))
        XCTAssertEqual(app.providerUsage.summaries().first?.calls, 1)
        let restarted = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(restarted.providerUsage.summaries().first?.tokens.total, 120)
        restarted.handleEvent("thread/tokenUsage/updated", usage(tokens(100, 20), total: tokens(100, 20)))
        XCTAssertEqual(restarted.providerUsage.summaries().first?.calls, 1)
        let data = try XCTUnwrap(defaults.data(forKey: ProviderUsageLedger.defaultsKey))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("CLOUDCODEX_MODEL_API_KEY"))
        XCTAssertFalse(text.contains("tokenUsage")) // Raw event payloads are never retained.
    }
}
