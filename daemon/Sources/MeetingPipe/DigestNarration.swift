import Foundation

/// Which engine will narrate the next weekly digest, and what the Preferences
/// group says about it (UX63).
///
/// The toggle that installs the digest's LaunchAgent carried one unconditional
/// footer: "The digest summarizes your open actions and recent decisions across
/// the whole library, on-device (no new egress)." The digest narrates through
/// `engine.complete_text` under `effective_backend()`, so on the owner's
/// `anthropic` config that was false in the way that matters: an unattended run
/// on 2026-08-03 logged `POST https://api.anthropic.com/v1/messages` and
/// "narrative via anthropic", which is a launchd job sending a slice of the
/// whole library's open actions and decisions to Anthropic every Monday at
/// 09:00, switched on by a control that said on-device.
///
/// The parenthetical was the sharp end. The module's own docstring uses the
/// correct qualified form ("No new always-on egress: this is a command you run
/// or schedule"), and the qualification is the entire content: it is a claim
/// about *scheduling*, not about the network. Dropped, it reads as a guarantee.
///
/// Owner's call, 2026-08-16, was neither of the two the spec offered but both:
/// tell the truth **and** ship the opt-out, as a real control rather than a key
/// sitting silently in `config.toml`. So this type answers one question, "which
/// engine will actually write the sentences", by composing the three rules that
/// decide it, and the copy is built from that answer rather than written beside
/// it. `RegulatedMode` is the same shape for the same reason one pane away.
enum DigestNarration {

    /// The engine that will narrate, or nil for a configured backend this build
    /// cannot name (UX31's rule: no raw config id reaches the screen, and no
    /// invented name either).
    ///
    /// Three rules, in the order the pipeline applies them:
    ///
    /// 1. `summarization.digest_local_only` pins it local (`digest.narration_config`).
    /// 2. The zero-egress clamp forces local under regulated mode
    ///    (`config.effective_backend`, mirrored by `RegulatedMode`).
    /// 3. `apple_intelligence` has no free-form path, so `engine.complete_text`
    ///    answers on the local MLX model (the substitution UX64 renders in Ask).
    ///
    /// Order matters only in that all three narrow toward the same engine, which
    /// is why they compose without a precedence argument: none of them can ever
    /// select a *cloud* engine.
    ///
    /// `auto` is deliberately reported as itself rather than resolved. It picks
    /// per run, at run time, on whether the cloud answered; predicting one here
    /// would be a guess, and its own name already says "cloud, fall back to
    /// local", which is the honest thing to tell someone about a future run.
    static func engine(
        configuredBackend: String,
        regulatedMode: Bool,
        localOnly: Bool
    ) -> SummarizationEngine? {
        if localOnly { return .local }
        let clamped = RegulatedMode.effectiveBackend(
            configured: configuredBackend, regulated: regulatedMode, workflowNDA: false
        )
        if clamped == SummarizationEngine.appleIntelligence.id { return .local }
        return SummarizationEngine.resolve(clamped)
    }

    /// True when the narration cannot reach the network. The footer's promise
    /// hangs off this and nothing else, so a wording change cannot outlive the
    /// routing that justified it.
    static func staysOnThisMac(
        configuredBackend: String,
        regulatedMode: Bool,
        localOnly: Bool
    ) -> Bool {
        engine(configuredBackend: configuredBackend, regulatedMode: regulatedMode, localOnly: localOnly)?
            .locality == .onDevice
    }

    // MARK: - Copy

    static let toggleTitle = "Keep the digest on this Mac"

    /// The line under the opt-out. It has to be useful in the case where the
    /// toggle changes nothing (an already-local backend, or regulated mode), and
    /// saying so is better than disabling a control whose value is a durable
    /// preference that will matter the next time the backend changes.
    static func toggleSublabel(configuredBackend: String, regulatedMode: Bool, localOnly: Bool) -> String {
        if staysOnThisMac(configuredBackend: configuredBackend, regulatedMode: regulatedMode, localOnly: false) {
            return "Your summaries already run on this Mac, so the digest does too. Leaving this on keeps it that way if you switch engines later."
        }
        return localOnly
            ? "On - the narrative is written on this Mac by \(SummarizationEngine.local.name), so nothing about your meetings is sent anywhere. It reads less well than the cloud version."
            : "Off - the narrative is written by the engine below, which is where a slice of your open actions and decisions is sent on each run."
    }

    /// The group footer: what actually happens, naming the engine that will run
    /// so the string cannot go stale when the backend changes.
    ///
    /// The old copy's two claims are kept but separated, because both were true
    /// of different halves and the sentence had merged them: the facts genuinely
    /// are gathered on-device, and there genuinely is no *always-on* egress.
    /// What was false was the reader's takeaway, that nothing goes out at all.
    static func footer(configuredBackend: String, regulatedMode: Bool, localOnly: Bool) -> String {
        let lead = "The digest gathers your open actions and recent decisions across the whole library on this Mac."
        let tail = "It runs only when you generate one or when the schedule fires, never continuously. Read the results in the Library's Digests view."
        guard let engine = engine(
            configuredBackend: configuredBackend, regulatedMode: regulatedMode, localOnly: localOnly
        ) else {
            // An engine this build cannot name: say nothing about where the
            // narrative goes rather than guess, the same nil-over-fallback rule
            // the Ask footer follows.
            return "\(lead) \(tail)"
        }
        switch engine.locality {
        case .onDevice:
            return "\(lead) The narrative is written on this Mac too, by \(engine.name), so nothing leaves it. \(tail)"
        case .cloud:
            return "\(lead) The narrative is written by \(engine.name), so a slice of those actions and decisions is sent there on every run, including the scheduled ones nobody is watching. Turn on \"\(toggleTitle)\" above to narrate on-device instead. \(tail)"
        case .cloudThenLocal:
            return "\(lead) The narrative is written by whichever engine \(engine.name) reaches first, so a slice of those actions and decisions may be sent to the cloud on any run, including the scheduled ones nobody is watching. Turn on \"\(toggleTitle)\" above to narrate on-device instead. \(tail)"
        }
    }
}
