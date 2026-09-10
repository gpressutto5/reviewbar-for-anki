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
        #expect(shortcuts.buryCard == "-")
        #expect(shortcuts.buryNote == "=")
        #expect(shortcuts.suspendCard == "@")
        #expect(shortcuts.suspendNote == "!")
        #expect(shortcuts.conflicts.isEmpty)
        #expect(shortcuts.cardActionConflicts.isEmpty)
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

@Suite struct CloseShortcutTests {
    @Test func noCloseKeyByDefault() {
        let shortcuts = ReviewShortcuts()
        #expect(shortcuts.close == nil)
        #expect(shortcuts.closeKeyConflicts == false)
        #expect(shortcuts.action(forKey: "q", answerShown: false) == nil)
    }

    @Test func closeKeyFiresInBothPhases() {
        let shortcuts = ReviewShortcuts(close: "q")
        #expect(shortcuts.action(forKey: "q", answerShown: false) == .close)
        #expect(shortcuts.action(forKey: "Q", answerShown: true) == .close)
        #expect(shortcuts.closeKeyConflicts == false)
        #expect(shortcuts.conflicts.isEmpty)
    }

    @Test func closeKeyWinsOverARatingAndIsFlagged() {
        let shortcuts = ReviewShortcuts(close: "3")
        #expect(shortcuts.action(forKey: "3", answerShown: true) == .close)
        #expect(shortcuts.conflicts == [.good])
        #expect(shortcuts.closeKeyConflicts == false)
    }

    @Test func closeKeyOnSpaceIsFlaggedAndIgnored() {
        // Space must keep flipping the card, so the close binding is the one
        // that gives way here.
        let shortcuts = ReviewShortcuts(close: " ")
        #expect(shortcuts.closeKeyConflicts)
        #expect(shortcuts.action(forKey: " ", answerShown: false) == .showAnswer)
    }

    @Test func oldBlobsWithoutACloseKeyStillDecode() throws {
        let data = Data(#"{"again":"1","hard":"2","good":"3","easy":"4","spaceAnswersGood":true}"#.utf8)
        let shortcuts = try JSONDecoder().decode(ReviewShortcuts.self, from: data)
        #expect(shortcuts == ReviewShortcuts())
    }
}

@Suite struct CardActionShortcutTests {
    @Test func cardKeysFireOnBothSidesOfTheCard() {
        let shortcuts = ReviewShortcuts()
        for (key, action) in [("-", CardAction.buryCard), ("=", .buryNote),
                              ("@", .suspendCard), ("!", .suspendNote)] {
            #expect(shortcuts.action(forKey: key, answerShown: false) == .cardAction(action))
            #expect(shortcuts.action(forKey: key, answerShown: true) == .cardAction(action))
        }
    }

    @Test func aClearedKeyDoesNothing() {
        var shortcuts = ReviewShortcuts()
        shortcuts.buryCard = nil
        #expect(shortcuts.action(forKey: "-", answerShown: true) == nil)
        #expect(shortcuts.cardActionConflicts.isEmpty)
    }

    @Test func cardKeyWinsOverARatingAndBothSidesAreFlagged() {
        var shortcuts = ReviewShortcuts()
        shortcuts.suspendCard = "3"
        #expect(shortcuts.action(forKey: "3", answerShown: true) == .cardAction(.suspendCard))
        #expect(shortcuts.conflicts == [.good])
        #expect(shortcuts.cardActionConflicts == [.suspendCard])
    }

    @Test func closeAndRevealKeysBeatCardKeys() {
        var shortcuts = ReviewShortcuts(close: "-")
        #expect(shortcuts.action(forKey: "-", answerShown: false) == .close)
        #expect(shortcuts.cardActionConflicts == [.buryCard])

        shortcuts = ReviewShortcuts()
        shortcuts.buryNote = " "
        #expect(shortcuts.action(forKey: " ", answerShown: false) == .showAnswer)
        #expect(shortcuts.cardActionConflicts == [.buryNote])
    }

    @Test func duplicateCardKeysAreFlaggedAndFirstWins() {
        var shortcuts = ReviewShortcuts()
        shortcuts.suspendNote = "-"
        #expect(shortcuts.cardActionConflicts == [.buryCard, .suspendNote])
        #expect(shortcuts.action(forKey: "-", answerShown: false) == .cardAction(.buryCard))
    }

    /// Absent keys (a blob from before these existed) mean Anki's defaults;
    /// a key the user cleared is stored as null and must stay cleared.
    @Test func decodingDistinguishesMissingFromCleared() throws {
        let old = Data(#"{"again":"1","hard":"2","good":"3","easy":"4","spaceAnswersGood":true}"#.utf8)
        #expect(try JSONDecoder().decode(ReviewShortcuts.self, from: old).buryCard == "-")

        var cleared = ReviewShortcuts()
        cleared.buryCard = nil
        cleared.suspendNote = "s"
        let data = try JSONEncoder().encode(cleared)
        let decoded = try JSONDecoder().decode(ReviewShortcuts.self, from: data)
        #expect(decoded == cleared)
        #expect(decoded.buryCard == nil)
        #expect(decoded.suspendNote == "s")
    }
}
