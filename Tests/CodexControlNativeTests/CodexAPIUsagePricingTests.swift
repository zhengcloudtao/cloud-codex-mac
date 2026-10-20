import XCTest
@testable import CloudCodex

final class CodexAPIUsagePricingTests: XCTestCase {
    func testPartitionsCachedInputAndDoesNotChargeItTwice() throws {
        let tokens = CodexAPIUsagePricing.Tokens(input: 100_000, cached: 60_000, cacheWrite: 20_000, output: 10_000)
        let line = CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "default", tokens: tokens, observedTokens: 110_000)
        // 20K ordinary * $2 + 60K read * $.1 + 20K write * $2.5 + 10K output * $10.
        XCTAssertEqual(try XCTUnwrap(line.dollars), 0.196, accuracy: 1e-12)
        XCTAssertTrue(line.basis.contains("Standard"))
    }

    func testLongContextIsPerRequestAndFastUsesDocumentedMultiplier() throws {
        let short = CodexAPIUsagePricing.Tokens(input: 272_000, cached: 100_000, cacheWrite: 0, output: 1000)
        let long = CodexAPIUsagePricing.Tokens(input: 272_001, cached: 100_000, cacheWrite: 0, output: 1000)
        let a = CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "default", tokens: short, observedTokens: 273_000)
        let b = CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "priority", tokens: long, observedTokens: 273_001)
        XCTAssertEqual(a.rates?.input, 2)
        XCTAssertEqual(b.rates?.input, 8)
        XCTAssertEqual(b.rates?.output, 30)
        XCTAssertEqual(b.rates?.cached, 0.4)
    }

    func testUnknownModelsOrMissingCategoriesAreNotFreeAndMixedCostsRemainPartial() throws {
        let t = CodexAPIUsagePricing.Tokens(input: 100, cached: 0, cacheWrite: 0, output: 10)
        var report = CodexAPIUsagePricing.Report()
        report.add(CodexAPIUsagePricing.line(model: "gpt-5.6-luna", tier: "default", tokens: t, observedTokens: 110))
        report.add(CodexAPIUsagePricing.line(model: "future-model", tier: "default", tokens: t, observedTokens: 110))
        report.add(CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: nil, tokens: nil, observedTokens: 1000))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.unpricedTokens, 1110)
        XCTAssertEqual(report.knownDollars, 0.000032, accuracy: 1e-12)
        XCTAssertEqual(try JSONDecoder().decode(CodexAPIUsagePricing.Report.self, from: JSONEncoder().encode(report)), report)
    }

    func testPreviousGenerationFastAlsoUsesItsOwnModelPrice() throws {
        let t = CodexAPIUsagePricing.Tokens(input: 100_000, cached: 0, cacheWrite: 0, output: 10_000)
        let fast = CodexAPIUsagePricing.line(model: "gpt-5.6-luna", tier: "fast", tokens: t, observedTokens: 110_000)
        XCTAssertEqual(try XCTUnwrap(fast.dollars), 0.064, accuracy: 1e-12)
        XCTAssertEqual(fast.rates?.input, 0.4)
        XCTAssertEqual(fast.rates?.output, 2.4)
        XCTAssertNil(CodexAPIUsagePricing.line(model: "gpt-6-sol", tier: "ultrafast", tokens: t, observedTokens: 110_000).dollars)
    }

    func testMissingSpeedIsUnpricedAndOldStandardAssumptionsAreRetracted() {
        let t = CodexAPIUsagePricing.Tokens(input: 100, cached: 0, cacheWrite: 0, output: 10)
        let unknown = CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: nil, tokens: t, observedTokens: 110)
        XCTAssertNil(unknown.dollars)
        var report = CodexAPIUsagePricing.Report()
        var legacy = unknown
        legacy = .init(model: legacy.model, basis: "Standard · 日志未提供速度，按标准价", tokens: t,
                       observedTokens: 110, rates: nil, dollars: 1, issue: nil)
        report.add(legacy)
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.knownDollars, 0)
        XCTAssertEqual(report.unpricedTokens, 110)
        var sample = WeeklyQuotaComparison.Sample(plan: "Plus", percent: 5, tokens: 110, dollars: 1, monthlyPrice: nil)
        sample.costReport = report
        XCTAssertNil(sample.weeklyDollars)
    }

    func testInvalidCachePartitionAndUnverifiedTierAreUnpriced() {
        let t = CodexAPIUsagePricing.Tokens(input: 100, cached: 90, cacheWrite: 20, output: 10)
        XCTAssertNil(CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "default", tokens: t, observedTokens: 110).dollars)
        let valid = CodexAPIUsagePricing.Tokens(input: 100, cached: 0, cacheWrite: 0, output: 10)
        XCTAssertNil(CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "unknown", tokens: valid, observedTokens: 110).dollars)
    }
}
