import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct ReviewShortcutsTests {
    @Test func defaultsMatchAnki() {
        let shortcuts = ReviewShortcuts()
        #expect(shortcuts.again == "1")
        #expect(shortcuts.hard == "2")
        #expect(shortcuts.good == "3")
        #expect(shortcuts.easy == "4")
        #expect(shortcuts.spaceAnswersGood)
        #expect(shortcuts.conflicts.isEmpty)
    }

    @Test func spaceRevealsThenAnswersGood() {
        let shortcuts = ReviewShortcuts()
        #expect(shortcuts.action(forKey: " ", answerShown: false) == .showAnswer)
        #expect(shortcuts.action(forKey: " ", answerShown: true) == .rate(.good))
    }

    @Test func spaceOnlyRevealsWhenAnsweringIsOff() {
        let shortcuts = ReviewShortcuts(spaceAnswersGood: false)
        #expect(shortcuts.action(forKey: " ", answerShown: false) == .showAnswer)
        #expect(shortcuts.action(forKey: " ", answerShown: true) == nil)
    }

    @Test func returnActsLikeSpace() {
        let shortcuts = ReviewShortcuts()
        #expect(shortcuts.action(forKey: "\r", answerShown: false) == .showAnswer)
        #expect(shortcuts.action(forKey: "\n", answerShown: true) == .rate(.good))
    }

    @Test func ratingKeysOnlyFireWithTheAnswerShowing() {
        let shortcuts = ReviewShortcuts()
        for ease in Ease.allCases {
            #expect(shortcuts.action(forKey: shortcuts[ease], answerShown: false) == nil)
            #expect(shortcuts.action(forKey: shortcuts[ease], answerShown: true) == .rate(ease))
        }
    }

    @Test func customLetterKeysAreCaseInsensitive() {
        var shortcuts = ReviewShortcuts()
        shortcuts.easy = "e"
        #expect(shortcuts.action(forKey: "E", answerShown: true) == .rate(.easy))
        #expect(shortcuts.action(forKey: "e", answerShown: true) == .rate(.easy))
    }

    @Test func unboundAndUnusableKeysDoNothing() {
        let shortcuts = ReviewShortcuts()
        #expect(shortcuts.action(forKey: "z", answerShown: true) == nil)
        // Escape, delete and multi-character input never reach a binding —
        // Escape in particular has to stay with the panel's close button.
        #expect(ReviewShortcuts.normalized(key: "\u{1B}") == nil)
        #expect(ReviewShortcuts.normalized(key: "\u{7F}") == nil)
        #expect(ReviewShortcuts.normalized(key: "ab") == nil)
    }

    @Test func conflictsFlagBothSidesAndTheRevealKey() {
        var shortcuts = ReviewShortcuts()
        shortcuts.hard = "3"
        #expect(shortcuts.conflicts == [.hard, .good])
        // First match wins so the binding stays predictable.
        #expect(shortcuts.action(forKey: "3", answerShown: true) == .rate(.hard))

        var spaced = ReviewShortcuts()
        spaced.easy = " "
        #expect(spaced.conflicts == [.easy])
        #expect(spaced.action(forKey: " ", answerShown: true) == .rate(.good))
    }

    @Test func displayLabels() {
        #expect(ReviewShortcuts.displayLabel(for: "1") == "1")
        #expect(ReviewShortcuts.displayLabel(for: "e") == "E")
        #expect(ReviewShortcuts.displayLabel(for: " ") == "Space")
        #expect(ReviewShortcuts.displayLabel(for: "") == "—")
    }

    @Test func roundTripsThroughJSON() throws {
        var shortcuts = ReviewShortcuts()
        shortcuts.again = "a"
        shortcuts.spaceAnswersGood = false
        let data = try JSONEncoder().encode(shortcuts)
        #expect(try JSONDecoder().decode(ReviewShortcuts.self, from: data) == shortcuts)
    }
}
