import Foundation
import Testing
@testable import RiverDiaryCore

struct HealthSourceStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    @Test func unsupportedSourceWinsOverEverything() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isSupported: false,
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: hoursAgo(1),
            now: now
        )
        #expect(status.state == .unsupported)
        #expect(status.lastSampleAt == nil)
    }

    @Test func failureWinsOverAuthorization() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: hoursAgo(1),
            failure: "HealthKit 读取失败",
            now: now
        )
        #expect(status.state == .failed)
        #expect(status.detail == "HealthKit 读取失败")
    }

    @Test func explicitDenialIsNotUnknown() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: false,
            hasSamples: false,
            lastSampleAt: nil,
            now: now
        )
        #expect(status.state == .notAuthorized)
    }

    @Test func recentSampleIsHealthy() {
        let sample = hoursAgo(8)
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: sample,
            now: now
        )
        #expect(status.state == .healthy)
        #expect(status.lastSampleAt == sample)
    }

    @Test func oldSampleIsStaleNotHealthy() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: hoursAgo(48),
            now: now
        )
        #expect(status.state == .stale)
    }

    @Test func staleBoundaryIsExclusive() {
        let exactlyBoundary = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true, hasSamples: true,
            lastSampleAt: hoursAgo(36), now: now
        )
        let justOver = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true, hasSamples: true,
            lastSampleAt: hoursAgo(36.01), now: now
        )
        #expect(exactlyBoundary.state == .healthy)
        #expect(justOver.state == .stale)
    }

    @Test func authorizedWithoutSamplesIsNoSamplesNotUnknown() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: false,
            lastSampleAt: nil,
            now: now
        )
        #expect(status.state == .noSamples)
    }

    @Test func healthKitStyleUnknownAuthorizationIsUnknownWithoutSamples() {
        // HealthKit 读权限无法查询：不能因为请求过就宣称已授权。
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: nil,
            hasSamples: false,
            lastSampleAt: nil,
            now: now
        )
        #expect(status.state == .unknown)
    }

    @Test func samplesSpeakEvenWhenAuthorizationIsUnknown() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: nil,
            hasSamples: true,
            lastSampleAt: hoursAgo(2),
            now: now
        )
        #expect(status.state == .healthy)
    }

    @Test func samplesWithoutTimestampStayUnknown() {
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: nil,
            now: now
        )
        #expect(status.state == .unknown)
    }

    @Test func customStalePolicyIsHonoured() {
        let policy = HealthSourcePolicy(staleAfter: 2 * 3600)
        let status = HealthSourceStatusEvaluator.evaluate(
            isAuthorized: true,
            hasSamples: true,
            lastSampleAt: hoursAgo(3),
            now: now,
            policy: policy
        )
        #expect(status.state == .stale)
    }
}
