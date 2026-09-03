import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct AnswerButtonTests {
    private func card(buttons: [Int], nextReviews: [String]) -> CurrentCard {
        CurrentCard(cardId: 1, question: "q", answer: "a", css: "",
                    buttons: buttons, nextReviews: nextReviews,
                    modelName: "Basic", deckName: "Sample", fields: [:])
    }

    @Test func fourButtonsAreAnkisFullSet() {
        let buttons = card(buttons: [1, 2, 3, 4],
                           nextReviews: ["<1m", "<16m", "30m", "7d"]).answerButtons
        #expect(buttons.map(\.ease) == [.again, .hard, .good, .easy])
        #expect(buttons.map(\.label) == ["Again", "Hard", "Good", "Easy"])
        #expect(buttons.map(\.interval) == ["<1m", "<16m", "30m", "7d"])
    }

    /// Anki labels rating buttons by position, not by ease number
    /// (`aqt.reviewer._answerButtonList`): with three buttons, ease 2 is
    /// **Good** and ease 3 is Easy. Reading `Ease.label` off the raw value
    /// would show a Hard button that grades Good.
    @Test func threeButtonsDropHardRatherThanEasy() {
        let buttons = card(buttons: [1, 2, 3],
                           nextReviews: ["<1m", "<10m", "4d"]).answerButtons
        #expect(buttons.map(\.ease) == [.again, .hard, .good])
        #expect(buttons.map(\.label) == ["Again", "Good", "Easy"])
        #expect(buttons.map(\.meaning) == [.again, .good, .easy])
        #expect(buttons.map(\.interval) == ["<1m", "<10m", "4d"])
    }

    /// A button count Anki has no labelling for: fall back to each ease's own
    /// name rather than shifting labels off the end of the table.
    @Test func unexpectedButtonCountsFallBackToEaseNames() {
        let buttons = card(buttons: [1, 3], nextReviews: ["<1m", "10m"]).answerButtons
        #expect(buttons.map(\.ease) == [.again, .good])
        #expect(buttons.map(\.label) == ["Again", "Good"])
    }

    @Test func intervalsAreBidiStrippedAndOptional() {
        let stripped = card(buttons: [1, 2, 3, 4],
                            nextReviews: ["\u{2068}30\u{2069}m"]).answerButtons
        #expect(stripped.first?.interval == "30m")
        // Fewer previews than buttons: the rest simply show no interval.
        #expect(stripped.dropFirst().allSatisfy { $0.interval == nil })
    }

    @Test func unknownEaseNumbersAreDropped() {
        let buttons = card(buttons: [1, 2, 3, 9], nextReviews: []).answerButtons
        #expect(buttons.map(\.ease) == [.again, .hard, .good])
    }

    // MARK: Lookup by name

    @Test func lookupByNameFollowsTheButtonSet() {
        let three = card(buttons: [1, 2, 3], nextReviews: [])
        #expect(three.answerButton(labelled: .good)?.ease == .hard)
        #expect(three.answerButton(labelled: .easy)?.ease == .good)
        // Three-button cards offer no Hard at all.
        #expect(three.answerButton(labelled: .hard) == nil)

        let four = card(buttons: [1, 2, 3, 4], nextReviews: [])
        for ease in Ease.allCases {
            #expect(four.answerButton(labelled: ease)?.ease == ease)
        }
    }
}
