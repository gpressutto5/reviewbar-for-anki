import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct ReviewDisplaySettingsTests {
    private func card(buttons: [Int]) -> CurrentCard {
        CurrentCard(cardId: 1, question: "q", answer: "a", css: "",
                    buttons: buttons, nextReviews: [],
                    modelName: "Basic", deckName: "Sample", fields: [:])
    }

    @Test func defaultsKeepTheOldBehaviour() {
        let settings = ReviewDisplaySettings()
        #expect(settings.cardAppearance == .dark)
        #expect(settings.showsIntervals)
        #expect(settings.passFailOnly == false)
    }

    @Test func passFailHidesHardAndEasyByMeaning() {
        let settings = ReviewDisplaySettings(passFailOnly: true)
        // Four-button card: Again/Hard/Good/Easy → Again/Good, eases 1 and 3.
        let four = card(buttons: [1, 2, 3, 4])
        #expect(settings.visibleButtons(four.answerButtons).map(\.ease) == [.again, .good])
        // Three-button card: Again/Good/Easy → Again/Good, but Good is ease 2
        // here and must keep submitting ease 2.
        let three = card(buttons: [1, 2, 3])
        let visible = settings.visibleButtons(three.answerButtons)
        #expect(visible.map(\.meaning) == [.again, .good])
        #expect(visible.map(\.ease) == [.again, .hard])
        #expect(settings.allows(rating: .good))
        #expect(settings.allows(rating: .easy) == false)
    }

    @Test func everythingIsVisibleWhenPassFailIsOff() {
        let settings = ReviewDisplaySettings()
        let card = card(buttons: [1, 2, 3, 4])
        #expect(settings.visibleButtons(card.answerButtons).count == 4)
        #expect(Ease.allCases.allSatisfy { settings.allows(rating: $0) })
    }

    @Test func roundTripsThroughJSON() throws {
        let settings = ReviewDisplaySettings(cardAppearance: .system, showsIntervals: false)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ReviewDisplaySettings.self, from: data) == settings)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let data = Data(#"{"showsIntervals": false}"#.utf8)
        let settings = try JSONDecoder().decode(ReviewDisplaySettings.self, from: data)
        #expect(settings.showsIntervals == false)
        #expect(settings.cardAppearance == .dark)
    }
}
