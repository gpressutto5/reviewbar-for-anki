import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct ModelDecodingTests {
    @Test func currentCardDecodesRealPayload() throws {
        // Trimmed from a live guiCurrentCard response captured 2026-08-28.
        let json = """
        {"cardId": 1787924094784,
         "question": "<style>.card {}</style>What is 2+2?",
         "answer": "<style>.card {}</style>What is 2+2?<hr id=answer>4",
         "buttons": [1, 2, 3, 4],
         "nextReviews": ["<\u{2068}1\u{2069}m", "<\u{2068}16\u{2069}m", "\u{2068}30\u{2069}m", "\u{2068}7\u{2069}d"],
         "modelName": "Basic", "deckName": "ReviewBar Spike",
         "css": ".card {}", "template": "Card 1",
         "fields": {"Front": {"value": "q", "order": 0}}, "fieldOrder": 0}
        """
        let card = try JSONDecoder().decode(CurrentCard.self, from: Data(json.utf8))
        #expect(card.cardId == 1787924094784)
        #expect(card.buttons == [1, 2, 3, 4])
        #expect(card.displayIntervals == ["<1m", "<16m", "30m", "7d"])
    }

    @Test func deckStatsDecodesSnakeCase() throws {
        let json = """
        {"deck_id": 1, "name": "日本語", "new_count": 10,
         "learn_count": 3, "review_count": 58, "total_in_deck": 0}
        """
        let stats = try JSONDecoder().decode(DeckStats.self, from: Data(json.utf8))
        #expect(stats.dueTotal == 71)
    }
}

@Suite struct ConnectionStateTests {
    @Test func classifiesErrors() {
        #expect(ConnectionState.from(AnkiConnectError.unreachable("refused")) == .unreachable)
        #expect(ConnectionState.from(AnkiConnectError.incompatibleVersion(4)) == .incompatibleVersion(4))
        #expect(ConnectionState.from(AnkiConnectError.api("boom")) == .error("boom"))
    }

    @Test func reviewInactiveIsRecognized() {
        let error = AnkiConnectError.api("Gui review is not currently active.")
        #expect(error.isReviewInactive)
        #expect(!AnkiConnectError.api("deck not found").isReviewInactive)
    }
}

@Suite struct DueCountTests {
    @Test func topLevelFiltersSubdecks() {
        let names = ["Default", "日本語", "日本語::Kaishi 1.5k", "A::B::C"]
        #expect(DueCount.topLevelDecks(from: names) == ["Default", "日本語"])
    }

    @Test func totalsAcrossDecks() async throws {
        let mock = MockAnkiConnectClient()
        let decks = DueCount.topLevelDecks(from: try await mock.deckNames())
        let stats = try await mock.deckStats(decks: decks)
        #expect(DueCount.total(from: stats) == 4) // Sample: 2 new + 2 review
    }

    @Test func scopeFiltersToChosenDecks() {
        let topLevel = ["Default", "日本語", "Music"]
        #expect(DueCount.scoped(topLevel, to: ["日本語"]) == ["日本語"])
        #expect(DueCount.scoped(topLevel, to: ["Music", "Default"]) == ["Default", "Music"])
    }

    @Test func emptyOrStaleScopeMeansAllDecks() {
        let topLevel = ["Default", "日本語"]
        #expect(DueCount.scoped(topLevel, to: []) == topLevel)
        // Every chosen deck renamed/deleted: fall back to all, not to nothing.
        #expect(DueCount.scoped(topLevel, to: ["Old Deck"]) == topLevel)
    }
}

@Suite struct EndpointParsingTests {
    @Test func acceptsHTTPURLsAndTrimsWhitespace() {
        #expect(AnkiConnectHTTPClient.endpoint(from: "http://127.0.0.1:8765")
                == URL(string: "http://127.0.0.1:8765"))
        #expect(AnkiConnectHTTPClient.endpoint(from: " https://anki.local:8765 ")
                == URL(string: "https://anki.local:8765"))
    }

    @Test func rejectsNonHTTPAndHostlessStrings() {
        #expect(AnkiConnectHTTPClient.endpoint(from: "") == nil)
        #expect(AnkiConnectHTTPClient.endpoint(from: "127.0.0.1:8765") == nil)
        #expect(AnkiConnectHTTPClient.endpoint(from: "file:///etc/hosts") == nil)
        #expect(AnkiConnectHTTPClient.endpoint(from: "http://") == nil)
        #expect(AnkiConnectHTTPClient.endpoint(from: "not a url") == nil)
    }
}

@Suite struct MockReviewFlowTests {
    @Test func fullReviewFlow() async throws {
        let mock = MockAnkiConnectClient()
        try await mock.startReview(deckName: "Sample")
        #expect(try await mock.reviewActive())

        let first = try await mock.currentCard()
        try await mock.showAnswer()
        try await mock.answerCurrentCard(ease: .good)

        let second = try await mock.currentCard()
        #expect(second.cardId != first.cardId)
        try await mock.showAnswer()
        try await mock.answerCurrentCard(ease: .again)

        // Queue drained: reviewer exits, matching live Anki behavior.
        #expect(!(try await mock.reviewActive()))
        await #expect(throws: AnkiConnectError.self) {
            _ = try await mock.currentCard()
        }
        #expect(await mock.answered.map(\.ease) == [.good, .again])
    }

    @Test func answerWithoutShowAnswerIsRejected() async throws {
        let mock = MockAnkiConnectClient()
        try await mock.startReview(deckName: "Sample")
        _ = try await mock.currentCard()
        await #expect(throws: AnkiConnectError.self) {
            try await mock.answerCurrentCard(ease: .good)
        }
    }
}

@Suite struct AnkiMediaTests {
    @Test func resolvesPlainFilenames() {
        let url = URL(string: "anki-media://collection/kanji%20card.jpg")!
        let file = AnkiMedia.fileURL(for: url, mediaDir: "/tmp/collection.media")
        #expect(file?.path == "/tmp/collection.media/kanji card.jpg")
    }

    @Test func rejectsTraversalAndNonFilenames() {
        for bad in ["anki-media://collection/../secrets",
                    "anki-media://collection/..",
                    "anki-media://collection/",
                    "anki-media://collection/%2e%2e%2fsecrets"] {
            let url = URL(string: bad)!
            #expect(AnkiMedia.fileURL(for: url, mediaDir: "/tmp/m") == nil,
                    "\(bad) should be rejected")
        }
    }

    @Test func mapsCommonMimeTypes() {
        #expect(AnkiMedia.mimeType(for: URL(fileURLWithPath: "/a/b.jpg")) == "image/jpeg")
        #expect(AnkiMedia.mimeType(for: URL(fileURLWithPath: "/a/b.mp3")) == "audio/mpeg")
        #expect(AnkiMedia.mimeType(for: URL(fileURLWithPath: "/a/b.weird"))
            == "application/octet-stream")
    }

    @Test func wrapsCardInAnkiReviewerDOM() {
        let doc = AnkiMedia.documentHTML(cardHTML: "<b>hi</b>", css: ".card { color: red; }")
        // Note-type CSS depends on Anki's exact reviewer shape:
        // body.card with a direct #qa child holding the card HTML.
        #expect(doc.contains("<body class=\"card isMac\"><div id=\"qa\"><b>hi</b></div>"))
        #expect(doc.contains(".card { color: red; }"))
        // Dark themes key off Anki's night classes, mirrored from the system.
        #expect(doc.contains("nightMode"))
        #expect(doc.contains("night_mode"))
    }

    @Test func darkensStockTemplatesLikeAnkiDoes() {
        // The stock template paints .card white; Anki's reviewer.css beats it
        // with a body.nightMode rule of higher specificity. That rule — and
        // Anki's canvas/fg colours — must come along, and ahead of the
        // note-type CSS the way Anki orders them.
        let doc = AnkiMedia.documentHTML(
            cardHTML: "x", css: ".card { color: black; background-color: white; }")
        let rule = "body.nightMode { background-color: var(--canvas); color: var(--fg); }"
        #expect(doc.contains(rule))
        #expect(doc.contains("--canvas: #2c2c2c"))
        #expect(doc.contains("--fg: #fcfcfc"))
        let ruleIndex = doc.range(of: rule)!.lowerBound
        let templateIndex = doc.range(of: "background-color: white")!.lowerBound
        #expect(ruleIndex < templateIndex)
    }
}

@Suite struct AVTagRestorerTests {
    @Test func replacesMarkersViaFieldTemplates() {
        // Kiku-style: markers embedded in <template data-field="…"> wrappers.
        // Template order (sentence before expression) deliberately disagrees
        // with field order to prove containment wins over the global pool.
        let html = """
        <template data-field="SentenceAudio">[anki:play:a:0]</template>
        <template data-field="ExpressionAudio">[anki:play:a:1]</template>
        """
        let fields = [
            "ExpressionAudio": CardField(value: "[sound:word.mp3]", order: 0),
            "SentenceAudio": CardField(value: "[sound:sentence.mp3]", order: 1),
        ]
        let restored = AVTagRestorer.replaceAVMarkers(in: html, fields: fields)
        #expect(restored.contains(
            AVTagRestorer.replayElement(file: "sentence.mp3") + "</template>"))
        #expect(restored.contains(
            AVTagRestorer.replayElement(file: "word.mp3") + "</template>"))
        #expect(!restored.contains("[anki:play"))
    }

    @Test func fallsBackToFieldOrderWithoutTemplates() {
        let html = "front [anki:play:q:0] middle [anki:play:q:1] end"
        let fields = [
            "Audio2": CardField(value: "[sound:b.mp3]", order: 5),
            "Audio1": CardField(value: "[sound:a.mp3]", order: 1),
        ]
        let restored = AVTagRestorer.replaceAVMarkers(in: html, fields: fields)
        let a = AVTagRestorer.replayElement(file: "a.mp3")
        let b = AVTagRestorer.replayElement(file: "b.mp3")
        #expect(restored == "front \(a) middle \(b) end")
    }

    @Test func leavesUnresolvableMarkersAndPlainHTMLAlone() {
        let fields = ["Front": CardField(value: "no audio here", order: 0)]
        let html = "text [anki:play:a:0] more"
        #expect(AVTagRestorer.replaceAVMarkers(in: html, fields: fields) == html)
        #expect(AVTagRestorer.replaceAVMarkers(in: "plain", fields: fields) == "plain")
    }

    @Test func replayElementEmbedsPlayableAudioAndEscapes() {
        let element = AVTagRestorer.replayElement(file: "a \"b\"&<c>.mp3")
        #expect(element.contains("<audio src=\"a &quot;b&quot;&amp;&lt;c>.mp3\" preload=\"none\">"))
        #expect(element.hasPrefix("<a class=\"replay-button soundLink\""))
        #expect(element.contains("a.play()"))
    }

    @Test func extractsSoundTagsInOrder() {
        let sounds = AVTagRestorer.soundTags(in: "[sound:a.mp3]text[sound:b ç.ogg]")
        #expect(sounds == ["a.mp3", "b ç.ogg"])
    }
}

@Suite struct ByteRangeTests {
    @Test func parsesCommonForms() {
        #expect(AnkiMedia.byteRange(fromHeader: "bytes=0-499", size: 1000) == 0..<500)
        #expect(AnkiMedia.byteRange(fromHeader: "bytes=500-", size: 1000) == 500..<1000)
        #expect(AnkiMedia.byteRange(fromHeader: "bytes=-200", size: 1000) == 800..<1000)
        // End clamped to the resource size.
        #expect(AnkiMedia.byteRange(fromHeader: "bytes=900-2000", size: 1000) == 900..<1000)
    }

    @Test func rejectsMalformedOrUnsatisfiable() {
        for header in ["bytes=1000-", "bytes=5-2", "bytes=0-1,5-9", "items=0-1",
                       "bytes=-0", "bytes=", "bytes=a-b"] {
            #expect(AnkiMedia.byteRange(fromHeader: header, size: 1000) == nil,
                    "\(header) should be rejected")
        }
        #expect(AnkiMedia.byteRange(fromHeader: "bytes=0-10", size: 0) == nil)
    }
}

@Suite struct SessionSettingsTests {
    @Test func limitIsNilWhenOffAndClampedWhenOn() {
        #expect(SessionSettings(isLimited: false, cardsPerBatch: 10).cardLimit == nil)
        #expect(SessionSettings(cardsPerBatch: 10).cardLimit == 10)
        // A stored zero would otherwise pause before the first card.
        #expect(SessionSettings(cardsPerBatch: 0).cardLimit == 1)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let stored = Data(#"{"cardsPerBatch": 25}"#.utf8)
        let settings = try JSONDecoder().decode(SessionSettings.self, from: stored)
        #expect(settings.cardsPerBatch == 25)
        #expect(settings.isLimited == SessionSettings().isLimited)
        #expect(settings.autoCloseDelay == SessionSettings().autoCloseDelay)
    }

    @Test func zeroDelayMeansWaitForTheUser() {
        #expect(SessionSettings(autoCloseDelay: 0).autoCloses == false)
        #expect(SessionSettings(autoCloseDelay: 6).autoCloses)
    }
}

@Suite @MainActor struct ReviewSessionTests {
    @Test func happyPathReviewsWholeQueue() async throws {
        let mock = MockAnkiConnectClient()
        let session = ReviewSession(client: mock)

        await session.start(decks: ["Sample"])
        guard case .question(let first) = session.phase else {
            Issue.record("expected question, got \(session.phase)"); return
        }
        #expect(first.cardId == 1)

        await session.revealAnswer()
        #expect(session.phase == .answer(first))
        await session.submit(ease: .good)
        guard case .question(let second) = session.phase else {
            Issue.record("expected second question, got \(session.phase)"); return
        }
        #expect(second.cardId == 2)

        await session.revealAnswer()
        await session.submit(ease: .again)
        #expect(session.phase == .finished)
        #expect(session.answeredCount == 2)
        #expect(await mock.answered.map(\.ease) == [.good, .again])
    }

    @Test func submitIsGuardedAgainstInvalidPhaseAndEase() async throws {
        let mock = MockAnkiConnectClient()
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"])

        // Question showing: rating must be a no-op until the answer is revealed.
        await session.submit(ease: .good)
        guard case .question = session.phase else {
            Issue.record("submit before reveal changed phase to \(session.phase)"); return
        }
        #expect(await mock.answered.isEmpty)

        // Second card offers buttons [1, 2, 3] only — Easy must be rejected.
        await session.revealAnswer()
        await session.submit(ease: .good)
        await session.revealAnswer()
        await session.submit(ease: .easy)
        guard case .answer = session.phase else {
            Issue.record("unavailable ease changed phase to \(session.phase)"); return
        }
        #expect(session.answeredCount == 1)
    }

    /// Shortcuts are configured by name, so a three-button card's "Good" key
    /// has to submit ease 2 — the button that *says* Good.
    @Test func ratingByNameFollowsTheCardsButtonSet() async throws {
        // Second sample card offers buttons [1, 2, 3].
        let mock = MockAnkiConnectClient(queue: [MockAnkiConnectClient.sampleQueue[1]])
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"])
        await session.revealAnswer()

        await session.submit(rating: .good)
        #expect(await mock.answered.map(\.ease) == [.hard])
        #expect(session.phase == .finished)
    }

    @Test func ratingByANameTheCardDoesNotOfferIsANoOp() async throws {
        let mock = MockAnkiConnectClient(queue: [MockAnkiConnectClient.sampleQueue[1]])
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"])
        await session.revealAnswer()

        await session.submit(rating: .hard)
        guard case .answer = session.phase else {
            Issue.record("unoffered rating changed phase to \(session.phase)"); return
        }
        #expect(await mock.answered.isEmpty)
    }

    @Test func batchLimitPausesWithoutFetchingTheNextCard() async throws {
        let mock = MockAnkiConnectClient()
        let session = ReviewSession(client: mock)

        await session.start(decks: ["Sample"], cardLimit: 1)
        await session.revealAnswer()
        await session.submit(ease: .good)
        #expect(session.phase == .batchComplete(answered: 1))
        #expect(session.answeredCount == 1)
        // The reviewer is left standing, holding the un-fetched next card.
        #expect(await mock.reviewInProgress)

        // Continuing resumes it — no deck is re-entered, no card skipped.
        await session.continueBatch()
        guard case .question(let card) = session.phase else {
            Issue.record("expected the next card, got \(session.phase)"); return
        }
        #expect(card.cardId == 2)
        #expect(session.batchAnsweredCount == 0)

        await session.revealAnswer()
        await session.submit(ease: .good)
        #expect(session.phase == .batchComplete(answered: 1))
        #expect(session.answeredCount == 2)
    }

    @Test func continuingIntoADrainedDeckFinishes() async throws {
        let mock = MockAnkiConnectClient(queue: [MockAnkiConnectClient.sampleQueue[0]])
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"], cardLimit: 1)
        await session.revealAnswer()
        await session.submit(ease: .good)
        #expect(session.phase == .batchComplete(answered: 1))

        await session.continueBatch()
        #expect(session.phase == .finished)
    }

    @Test func continueBatchIsIgnoredMidCard() async throws {
        let session = ReviewSession(client: MockAnkiConnectClient())
        await session.start(decks: ["Sample"], cardLimit: 5)
        let midPhase = session.phase
        await session.continueBatch()
        #expect(session.phase == midPhase)
    }

    @Test func noLimitReviewsTheWholeQueue() async throws {
        let session = ReviewSession(client: MockAnkiConnectClient())
        await session.start(decks: ["Sample"], cardLimit: nil)
        for _ in 0..<2 {
            await session.revealAnswer()
            await session.submit(ease: .good)
        }
        #expect(session.phase == .finished)
    }

    @Test func startIsIgnoredMidSession() async throws {
        let mock = MockAnkiConnectClient()
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"])
        await session.revealAnswer()
        await session.submit(ease: .good)
        let midPhase = session.phase

        await session.start(decks: ["Sample"])
        #expect(session.phase == midPhase)
        #expect(session.answeredCount == 1)
    }

    @Test func emptyQueueFinishesImmediately() async throws {
        let session = ReviewSession(client: MockAnkiConnectClient(queue: []))
        await session.start(decks: ["Sample"])
        #expect(session.phase == .finished)
        #expect(session.answeredCount == 0)
    }

    @Test func unreachableAnkiFailsTheSession() async throws {
        let mock = MockAnkiConnectClient()
        await mock.setUnreachable(true)
        let session = ReviewSession(client: mock)
        await session.start(decks: ["Sample"])
        #expect(session.phase == .failed(.unreachable))
    }

    @Test func drainedDecksAreSkippedUntilOneHasCards() async throws {
        let client = MultiDeckClient(queues: [
            "Empty": [], "Sample": MockAnkiConnectClient.sampleQueue,
        ])
        let session = ReviewSession(client: client)
        await session.start(decks: ["Empty", "Sample", "AlsoMissing"])
        guard case .question(let card) = session.phase else {
            Issue.record("expected question, got \(session.phase)"); return
        }
        #expect(card.deckName == "Sample")

        await session.revealAnswer()
        await session.submit(ease: .good)
        await session.revealAnswer()
        await session.submit(ease: .good)
        // Sample drained; AlsoMissing has no queue — session must finish.
        #expect(session.phase == .finished)
        #expect(session.answeredCount == 2)
    }
}

/// Protocol double with per-deck queues, for exercising ReviewSession's
/// sequential deck iteration (the shared mock has a single queue).
private actor MultiDeckClient: AnkiConnectClient {
    private var queues: [String: [CurrentCard]]
    private var activeDeck: String?
    private var answerShown = false
    private var reviewedCount = 0

    init(queues: [String: [CurrentCard]]) { self.queues = queues }

    func version() async throws -> Int { 6 }
    func deckNames() async throws -> [String] { Array(queues.keys) }
    func deckStats(decks: [String]) async throws -> [DeckStats] { [] }
    func mediaDirPath() async throws -> String { "/tmp" }
    func sync() async throws {}
    func numCardsReviewedToday() async throws -> Int { reviewedCount }

    func startReview(deckName: String) async throws {
        activeDeck = queues[deckName]?.isEmpty == false ? deckName : nil
    }

    func reviewActive() async throws -> Bool { activeDeck != nil }

    func currentCard() async throws -> CurrentCard {
        guard let deck = activeDeck, let card = queues[deck]?.first else {
            throw AnkiConnectError.api("Gui review is not currently active.")
        }
        return card
    }

    func startCardTimer() async throws {}
    func showAnswer() async throws { answerShown = true }

    func answerCurrentCard(ease: Ease) async throws {
        guard let deck = activeDeck, answerShown, queues[deck]?.isEmpty == false else {
            throw AnkiConnectError.api("Not in answer state")
        }
        queues[deck]?.removeFirst()
        reviewedCount += 1
        answerShown = false
        if queues[deck]?.isEmpty == true { activeDeck = nil }
    }
}
