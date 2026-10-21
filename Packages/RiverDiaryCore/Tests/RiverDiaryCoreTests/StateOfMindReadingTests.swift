import Foundation
import Testing
@testable import RiverDiaryCore

struct StateOfMindReadingTests {
    @Test func clampsToHealthKitRange() {
        #expect(StateOfMindReading.normalizedValence(0.5) == 0.5)
        #expect(StateOfMindReading.normalizedValence(2) == 1)
        #expect(StateOfMindReading.normalizedValence(-2) == -1)
    }

    @Test func nonFiniteBecomesNeutral() {
        #expect(StateOfMindReading.normalizedValence(.nan) == 0)
        #expect(StateOfMindReading.normalizedValence(.infinity) == 0)
    }
}
