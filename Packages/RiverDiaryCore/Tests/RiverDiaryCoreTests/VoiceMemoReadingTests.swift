import Foundation
import Testing
@testable import RiverDiaryCore

struct VoiceMemoReadingTests {
    @Test func trimsAndRejectsEmpty() {
        #expect(VoiceMemoReading.normalizedText("  今天去了河边\n") == "今天去了河边")
        #expect(VoiceMemoReading.normalizedText(" \n\t ") == nil)
    }

    @Test func capsVeryLongText() {
        let text = String(repeating: "字", count: VoiceMemoReading.maximumCharacters + 10)
        let normalized = VoiceMemoReading.normalizedText(text)
        #expect(normalized?.count == VoiceMemoReading.maximumCharacters)
    }
}
