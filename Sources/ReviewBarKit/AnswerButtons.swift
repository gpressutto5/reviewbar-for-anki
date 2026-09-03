import Foundation

/// One rating button as Anki's reviewer would draw it for *this* card.
public struct AnswerButton: Equatable, Sendable, Identifiable {
    /// The ease to send to `guiAnswerCard` — Anki's button number.
    public let ease: Ease
    /// The ease whose name (and colour) this button carries. Differs from
    /// `ease` on three-button cards, where button 2 is Good, not Hard.
    public let meaning: Ease
    /// Interval preview from `nextReviews`, bidi isolates already stripped.
    /// Nil when the card supplied fewer previews than buttons.
    public let interval: String?

    public var id: Int { ease.rawValue }
    public var label: String { meaning.label }

    public init(ease: Ease, meaning: Ease, interval: String?) {
        self.ease = ease
        self.meaning = meaning
        self.interval = interval
    }
}

extension Ease {
    /// The eases whose *names* Anki uses for a button set of the given size.
    ///
    /// Anki labels rating buttons by position, not by ease number
    /// (`aqt.reviewer._answerButtonList`): four buttons are
    /// Again/Hard/Good/Easy, but three are Again/**Good**/Easy — so on a
    /// three-button card ease 2 means Good and ease 3 means Easy. Nil for a
    /// button count Anki has no labelling for; the caller then falls back to
    /// each ease's own name.
    static func labelEases(forButtonCount count: Int) -> [Ease]? {
        switch count {
        case 3: [.again, .good, .easy]
        case 4: Ease.allCases
        default: nil
        }
    }
}

public extension CurrentCard {
    /// The rating buttons to show, in Anki's order, each carrying the label and
    /// interval preview that belong to it. `nextReviews` is index-matched to
    /// `buttons`, so both are read positionally.
    var answerButtons: [AnswerButton] {
        let intervals = displayIntervals
        let labels = Ease.labelEases(forButtonCount: buttons.count)
        return buttons.enumerated().compactMap { index, raw in
            guard let ease = Ease(rawValue: raw) else { return nil }
            let meaning = labels?.indices.contains(index) == true ? labels![index] : ease
            return AnswerButton(ease: ease, meaning: meaning,
                                interval: intervals.indices.contains(index)
                                    ? intervals[index] : nil)
        }
    }

    /// The button *labelled* for the given ease, if this card offers one.
    /// Keyboard shortcuts are configured by name (Again, Good…), so they
    /// resolve through here rather than by raw ease number.
    func answerButton(labelled meaning: Ease) -> AnswerButton? {
        answerButtons.first { $0.meaning == meaning }
    }
}
