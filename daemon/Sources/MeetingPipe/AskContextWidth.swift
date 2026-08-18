import Foundation

/// AI12: how much of the library one question is allowed to buy, plus the
/// sentence that makes turning the dial honest.
///
/// `mp ask` packs its retrieved context to `--context-tokens` (4000 by default)
/// and the daemon never passed the flag, so in the app the budget was a
/// constant. The width genuinely changes the answer, measured rather than
/// assumed: on 2026-07-31 the same question at 100000 tokens read 117 meetings
/// against 26 and cited seven of them against four.
///
/// **The two constraints are the whole difficulty, and they point opposite
/// ways.**
///
/// On a backend that answers on this Mac the tier ceiling is a *hard cap*, not
/// a default. `mp.ask.clamp_context_tokens` holds the request at
/// `resource_guard.tier_for(ram).context_token_ceiling`, and that ceiling exists
/// because going past it took this Mac down: the 2026-07-29 `mp ask` incident
/// ended in a hard reboot, and AI2 measured the 14B OOM-crashing at 16K. So a
/// position above the ceiling is **not offered at all**, and the control states
/// the cause rather than greying a row silently (the UX30 rule) or rounding the
/// request down where nobody sees it.
///
/// On a cloud backend nothing clamps and nothing can crash, and the cost is
/// money. So the warning there is about spend, and it names the multiple rather
/// than a token count, because a token count is not a thing anyone can price.
///
/// Pure, so the whole table is testable without a view, a config, or a spawn.
///
/// **Mirror rule**, the same standing arrangement `LocalModelTier` carries:
/// `defaultTokens` mirrors `mp.ask.DEFAULT_CONTEXT_TOKENS`, and the set of
/// backends this caps mirrors `mp.ask.ON_DEVICE_BACKENDS`, reached through
/// `SummarizationEngine.locality` rather than a second literal list. The ceiling
/// itself is not re-derived here: it comes from `LocalModelTier`, which already
/// mirrors `mp.resource_guard`.
enum AskContextWidth {

    /// One named position: what the control shows, and what it asks for.
    struct Position: Equatable, Identifiable {
        let id: String
        /// Plain words on purpose. "100000 tokens" names nothing to the person
        /// deciding whether to spend it, which is why this is a preset control
        /// and not a number field.
        let label: String
        /// What reaches `mp ask --context-tokens`.
        let tokens: Int
    }

    /// `mp.ask.DEFAULT_CONTEXT_TOKENS`. The resting position, so an owner who
    /// never touches the control asks for exactly what the CLI would have
    /// defaulted to anyway.
    static let defaultTokens = 4_000

    /// Ordered the way the control reads, left to right.
    ///
    /// The middle value is the 32 GB tier ceiling exactly, not a round number
    /// picked for looks: it is the widest a local answer on this Mac is allowed
    /// to be, so the machine this ships on gets a real second position locally
    /// instead of a control with nothing to choose. The widest is above every
    /// tier in the table (16000 at 48 GB is the highest there is), so it is
    /// cloud-only by construction rather than by a rule someone has to maintain.
    static let all: [Position] = [
        Position(id: "normal", label: "Normal", tokens: defaultTokens),
        Position(id: "wider", label: "Wider", tokens: 8_000),
        Position(id: "widest", label: "Widest", tokens: 100_000),
    ]

    /// The resting position. Always offered, on every backend and every machine.
    static var normal: Position { all[0] }

    /// The position an id names, falling back to the resting one for an id
    /// nothing pins. That fallback is load-bearing rather than defensive: a
    /// selection made on a cloud backend is still stored when the backend
    /// changes to a local one, and it must not survive as a width.
    static func position(forID id: String) -> Position {
        all.first { $0.id == id } ?? normal
    }

    /// How many normal questions one position is worth, which is the honest
    /// number to say out loud. Calibrated against the owner's own measurement: a
    /// 100000-token pack sent roughly 26x the input of a 4000-token one.
    static func multiple(_ position: Position) -> Int {
        max(1, Int((Double(position.tokens) / Double(defaultTokens)).rounded()))
    }

    // MARK: - The cap

    /// The ceiling one question is held at, or nil when nothing here caps it (a
    /// cloud answer).
    ///
    /// `regulatedMode` is checked first because it is the wider clamp:
    /// `config.effective_backend` forces the on-device path whenever zero-egress
    /// holds, whatever backend is configured, so reading the backend id alone
    /// would offer a cloud-only width to a machine that is about to answer
    /// locally. That is exactly the silent-clamp shape this task exists to
    /// remove. `ReSummarizeMenu` orders its two clamps the same way and for the
    /// same reason.
    ///
    /// An id this build cannot resolve is capped. Python treats an unknown
    /// backend as uncapped, which is right for *its* job (it must not refuse to
    /// answer), but here the cost of guessing wrong is a wide local pack, so the
    /// guess goes the safe way.
    static func ceiling(backendID: String, regulatedMode: Bool, ramGB: Double) -> Int? {
        if !regulatedMode, SummarizationEngine.resolve(backendID)?.locality == .cloud { return nil }
        return LocalModelTier.tier(forRamGB: ramGB).contextTokenCeiling
    }

    // MARK: - The offer

    /// What the control shows for one backend on one machine.
    struct Offer: Equatable {
        /// The positions this machine and backend can honestly be asked for.
        let positions: [Position]
        /// The resolved selection: what was asked for when it is still offered,
        /// the resting position otherwise.
        let selection: Position
        /// What the selected position costs, in the currency that actually
        /// applies. Always present, and always shown *before* the ask: a warning
        /// that arrives with the bill is not a warning.
        let sublabel: String
        /// Why the wider positions are missing. Nil when none are.
        let reason: String?

        /// A one-position control is a readout, so the surface draws the reason
        /// alone rather than a picker nobody can move (UX43's rule: an option
        /// always on offer that does nothing is not an option).
        var showsPicker: Bool { positions.count > 1 }

        /// What reaches `mp ask --context-tokens`.
        var contextTokens: Int { selection.tokens }
    }

    /// The whole decision: which positions are offered, which is selected, and
    /// what the two lines under the control say.
    static func offer(
        backendID: String,
        regulatedMode: Bool,
        ramGB: Double,
        selectedID: String
    ) -> Offer {
        let cap = ceiling(backendID: backendID, regulatedMode: regulatedMode, ramGB: ramGB)
        // The resting position is always offered: it is the floor of the control
        // and what `mp ask` passes with no flag at all, so dropping it on a
        // machine whose ceiling is below 4000 would empty the control while
        // changing nothing about what that machine already does. The clamp holds
        // that request at the ceiling today and still will, which is why this
        // consumes the guard rather than negotiating with it.
        let offered = all.filter { p in
            p.id == normal.id || cap.map { p.tokens <= $0 } ?? true
        }
        let selection = offered.first { $0.id == selectedID } ?? normal
        let engine = SummarizationEngine.resolve(backendID)
        return Offer(
            positions: offered,
            selection: selection,
            sublabel: sublabel(
                selection, engine: engine, capped: cap != nil, regulatedMode: regulatedMode
            ),
            reason: offered.count == all.count
                ? nil
                : reason(engine: engine, regulatedMode: regulatedMode, ramGB: ramGB)
        )
    }

    // MARK: - Copy

    /// What the selected position costs. The currency changes with the backend,
    /// and saying the wrong one would be worse than saying nothing: money is not
    /// the risk on this Mac, and memory is not the risk in the cloud.
    private static func sublabel(
        _ position: Position,
        engine: SummarizationEngine?,
        capped: Bool,
        regulatedMode: Bool
    ) -> String {
        let m = multiple(position)
        guard m > 1 else { return "Reads the meetings closest to your question." }
        if !capped {
            let name = engine?.name ?? "the cloud backend"
            return "About \(m)x the text sent to \(name), so about \(m)x the cost of a normal question."
        }
        if !regulatedMode, engine?.locality == .cloudThenLocal, let name = engine?.name {
            return "About \(m)x the text either way: about \(m)x the cost when \(name) answers in "
                + "the cloud, and a longer wait when it falls back to this Mac."
        }
        return "About \(m)x as much text for the model on this Mac to read, so the answer takes "
            + "longer. Nothing leaves this Mac."
    }

    /// Why the wider positions are gone. Names this Mac's memory, in the
    /// `LocalModelTier` register ("Needs about 24 GB; this Mac has 16 GB"), and
    /// offers the way out only where there is one: under regulated mode every
    /// backend is clamped, so pointing at Preferences would point at a door that
    /// opens onto a wall (`ReSummarizeMenu.offersWorkflowChange`, same rule).
    ///
    /// **UX72: the incident stays out of what the control says.** The refusal used
    /// to close by naming the 2026-07-29 reboot as something that had happened to
    /// this Mac. True of the machine this was written on, and a report of that
    /// machine's past to a reader who has no such past: unverifiable where it is
    /// read, and mildly alarming on a Mac that has never crashed. What is left is
    /// the cause the reader can check, this backend and this Mac's memory, in the
    /// same shape the sublabels beside it use. Why the ceiling exists is not lost,
    /// it is in the type comment above, where a maintainer looks and a user does
    /// not. `AskContextWidthTests` fences the old sentence out of `daemon/Sources`,
    /// because it is quoted in this task's spec and in the backlog row and both
    /// are what a later session reads before editing this file.
    private static func reason(
        engine: SummarizationEngine?,
        regulatedMode: Bool,
        ramGB: Double
    ) -> String {
        let ram = LocalModelTier.gb(ramGB)
        if regulatedMode {
            return "Regulated mode keeps every answer on this Mac, so the width is capped at what "
                + "\(ram) GB can hold."
        }
        guard let engine else {
            return "The summarization backend in your config is not one this build knows, so the "
                + "width is capped at what this Mac (\(ram) GB) can hold."
        }
        let opener = engine.locality == .cloudThenLocal
            ? "\(engine.name) can fall back to the model on this Mac"
            : "\(engine.name) answers on this Mac"
        return "\(opener), so the width is capped at what \(ram) GB can hold. Switch to a cloud "
            + "backend in Preferences \u{25B8} Pipeline to read wider."
    }
}
