import SwiftUI
import ReviewBarKit
import os

/// The review surface inside the floating panel: drives ReviewSession end to
/// end, rendering cards through `CardWebView` (WKWebView + collection.media
/// handler). Always dark — it lives on the dark-glass panel.
struct ReviewPanelView: View {
    let state: AppState

    @State private var cardHeight: CGFloat = 220
    /// Seconds left on the batch screen's auto-close. Nil when it isn't
    /// counting (auto-close off, or another phase).
    @State private var secondsUntilClose: Int?

    /// Cards get as much height as they report needing, up to what fits on
    /// screen alongside the panel's header, buttons, and menu bar.
    private static var cardHeightRange: ClosedRange<CGFloat> {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return 120...max(480, screenHeight - 220)
    }

    private var session: ReviewSession { state.session }

    private static let log = Logger(subsystem: "com.reviewbar.app", category: "panel")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            phaseContent
        }
        .padding(PanelTheme.padding)
        .foregroundStyle(.white)
    }

    /// The reviewing phases flattened so header, controls row, and web view
    /// keep one structural identity from question through answer to the next
    /// card: content swaps in place inside the SAME WKWebView (no blink) and
    /// only the panel's size morphs, on the container's spring.
    private struct CardPhase: Equatable {
        let card: CurrentCard
        let revealed: Bool
        let submitting: Bool
    }

    private var cardPhase: CardPhase? {
        switch session.phase {
        case .question(let card):
            CardPhase(card: card, revealed: false, submitting: false)
        case .answer(let card):
            CardPhase(card: card, revealed: true, submitting: false)
        case .submitting(let card):
            CardPhase(card: card, revealed: true, submitting: true)
        case .idle, .entering, .batchComplete, .finished, .failed:
            nil
        }
    }

    @ViewBuilder private var phaseContent: some View {
        if let phase = cardPhase {
            // Controls sit above the card, at a fixed height, so they stay
            // in the same spot on screen (the panel hangs from the top of
            // the screen) no matter how the card below resizes.
            cardHeader(phase.card)
            controls(for: phase)
                .frame(maxWidth: .infinity, minHeight: PanelTheme.controlsHeight)
            cardBody(phase.revealed ? phase.card.webAnswer : phase.card.webQuestion,
                     card: phase.card)
        } else {
            switch session.phase {
            // Nothing has been asked of Anki yet: either the panel was opened
            // as a passive nudge, or the connection is already known bad. A
            // spinner here would be a lie in both cases.
            case .idle:
                if state.isStartingReview {
                    starting
                } else if state.connection.isConnected || state.connection == .unknown {
                    waiting
                } else {
                    failure(state.connection)
                }

            case .entering:
                starting

            case .question, .answer, .submitting:
                // Covered by cardPhase above.
                EmptyView()

            case .batchComplete(let answered):
                batchComplete(answered: answered)

            case .finished:
                finished

            case .failed(let connectionState):
                failure(connectionState)
            }
        }
    }

    @ViewBuilder private var starting: some View {
        ProgressView("Starting review…")
            .tint(.white)
            .foregroundStyle(PanelTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    /// Something is due but no review has started — the passive nudge, and
    /// where a menu-less entry point lands. An offer, not a spinner.
    @ViewBuilder private var waiting: some View {
        HStack {
            Label(state.dueSummary.isEmpty ? "Ready to review" : state.dueSummary,
                  systemImage: "tray.full.fill")
                .font(.title3.weight(.semibold))
            Spacer()
            CloseButton { closeSession() }
        }
        HStack(spacing: 8) {
            Button("Review Now") { Task { await state.startReview() } }
                .buttonStyle(TileButtonStyle())
                .keyboardShortcut(.defaultAction)
            Button("Later") { closeSession() }
                .buttonStyle(TileButtonStyle())
        }
    }

    /// Anki isn't answering. The notch is a one-click entry point with no menu
    /// behind it, so the recovery action has to live here too — otherwise the
    /// panel just states the problem and leaves the user to find the menu.
    /// "Open Anki" waits for Anki to come back (~10–15 s) and then starts the
    /// review that was asked for.
    @ViewBuilder private func failure(_ connectionState: ConnectionState) -> some View {
        HStack {
            Label(state.isLaunchingAnki ? "Starting Anki…" : connectionState.statusText,
                  systemImage: state.isLaunchingAnki
                      ? "hourglass" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange.mix(with: .white, by: 0.3))
            Spacer()
            CloseButton { closeSession() }
        }
        HStack(spacing: 8) {
            if connectionState.isUnreachable, state.canOpenAnki {
                Button("Open Anki") { Task { await state.openAnkiAndReview() } }
                    .buttonStyle(TileButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isLaunchingAnki)
            } else {
                Button("Try Again") { Task { await state.startReview() } }
                    .buttonStyle(TileButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Button("Close") { closeSession() }
                .buttonStyle(TileButtonStyle())
        }
    }

    /// End of a batch — the soft session's whole point. Cards are almost
    /// certainly still waiting, so this is a stopping *offer*, not a wall:
    /// Continue takes another batch without leaving Anki's reviewer, and the
    /// panel folds itself away if neither button is pressed.
    ///
    /// The countdown is view-local on purpose. It isn't app state and it dies
    /// with the phase — `.task(id:)` cancels it the moment Continue changes
    /// the phase, so the close can't fire onto a live card.
    @ViewBuilder private func batchComplete(answered: Int) -> some View {
        HStack {
            Label("Session done", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green.mix(with: .white, by: 0.3))
            Spacer()
            CloseButton { closeSession() }
        }
        Text(batchSummary(answered: answered))
            .foregroundStyle(PanelTheme.secondaryText)
        HStack(spacing: 8) {
            Button("Continue") {
                secondsUntilClose = nil
                Task { await state.continueReviewBatch() }
            }
            .buttonStyle(TileButtonStyle())
            .keyboardShortcut(.defaultAction)
            // The countdown rides the button it actually does: Done.
            Button(countdownLabel("Done")) { closeSession() }
                .buttonStyle(TileButtonStyle())
        }
        .task(id: answered) { await runAutoClose() }
    }

    /// Every deck is drained. Nothing is left to decide, so this closes
    /// itself on the same countdown as a finished batch.
    @ViewBuilder private var finished: some View {
        HStack {
            Label("All caught up", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green.mix(with: .white, by: 0.3))
            Spacer()
            CloseButton { closeSession() }
        }
        Text("Answered \(session.answeredCount) card\(session.answeredCount == 1 ? "" : "s").")
            .foregroundStyle(PanelTheme.secondaryText)
        Button(countdownLabel("Done")) { closeSession() }
            .buttonStyle(TileButtonStyle())
            .keyboardShortcut(.defaultAction)
            .task { await runAutoClose() }
    }

    private func batchSummary(answered: Int) -> String {
        let cards = "\(answered) card\(answered == 1 ? "" : "s")"
        guard let due = state.dueCount, due > 0 else { return "Answered \(cards)." }
        return "Answered \(cards). \(due) still waiting — come back later, or keep going."
    }

    /// Button title with the auto-close countdown appended while one is
    /// running, so the panel says how long is left instead of vanishing
    /// unannounced.
    private func countdownLabel(_ title: String) -> String {
        guard let seconds = secondsUntilClose else { return title }
        return "\(title) (\(seconds))"
    }

    /// Runs the auto-close down to a deadline. View-local on purpose: it isn't
    /// app state, and `.task` cancels it the moment the phase changes, so the
    /// close can't fire onto a live card.
    ///
    /// The remaining time is recomputed from the clock rather than counted
    /// down by sleeps — same rule as `AppState.tick()` — and refreshed several
    /// times a second, so the label can't drift or skip numbers if a sleep
    /// runs long (App Nap coalesces timers in a background app).
    private func runAutoClose() async {
        let delay = state.sessionSettings.autoCloseDelay
        guard delay > 0 else {
            secondsUntilClose = nil
            return
        }
        Self.log.debug("auto-close armed: \(delay, privacy: .public)s")
        let deadline = Date().addingTimeInterval(delay)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            secondsUntilClose = Int(remaining.rounded(.up))
            // Cancellation (the phase changed under us) throws out of here.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        secondsUntilClose = nil
        // Belt and braces: only ever close from an end state.
        switch session.phase {
        case .batchComplete, .finished: closeSession()
        case .idle, .entering, .question, .answer, .submitting, .failed: break
        }
    }

    @ViewBuilder private func controls(for phase: CardPhase) -> some View {
        if phase.revealed {
            ratingButtons(phase.card)
                .disabled(phase.submitting)
        } else {
            Button("Show Answer") {
                Task { await session.revealAnswer() }
            }
            .buttonStyle(TileButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func cardHeader(_ card: CurrentCard) -> some View {
        HStack {
            Text(card.deckName)
                .font(.caption.weight(.medium))
                .kerning(0.3)
                .foregroundStyle(PanelTheme.secondaryText)
                .lineLimit(1)
            Spacer()
            CloseButton { closeSession() }
        }
    }

    private func cardBody(_ html: String, card: CurrentCard) -> some View {
        CardWebView(cardHTML: html, css: card.css, mediaDir: state.mediaDir) { height in
            cardHeight = height.clamped(to: Self.cardHeightRange)
        }
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PanelTheme.cardSurface))
    }

    /// Labels, colours and interval previews all come from
    /// `CurrentCard.answerButtons`: a three-button card numbers its buttons
    /// 1/2/3 but names them Again/Good/Easy, so neither can be read off the
    /// ease number here.
    private func ratingButtons(_ card: CurrentCard) -> some View {
        HStack(spacing: 8) {
            ForEach(card.answerButtons) { button in
                Button {
                    Task {
                        await session.submit(ease: button.ease)
                        await state.refresh()
                    }
                } label: {
                    VStack(spacing: 1) {
                        Text(button.label)
                        if let interval = button.interval {
                            Text(interval)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(PanelTheme.tertiaryText)
                        }
                    }
                }
                .buttonStyle(TileButtonStyle(tint: button.meaning.tint))
            }
        }
    }

    private func closeSession() {
        state.dismissReview()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
