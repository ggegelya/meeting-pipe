import Foundation

/// A publish sink, named the way the surfaces that report a finished run name it
/// (UX49).
///
/// `SummarizationEngine` is the same rule for a backend's display name, and this
/// exists for the same reason: the done notification and the detail header both
/// answer "where did this land?", and they each spelled the answer themselves.
/// The notification's spelling was the literal `"Open in Notion"` on every
/// meeting, consulting nothing, so the owner's nine consecutive filesystem
/// publishes were each announced as a Notion page and offered a local Markdown
/// file as if it were one.
///
/// A fourth type carrying this vocabulary, and deliberately so: `WorkflowSink`
/// is what a workflow turns *on* (Notion carries its database id, so its cases
/// cannot be built from a bare name), `PublishTarget` is the subset whose
/// destination is global config (Notion is absent by design), and this is what a
/// finished run reported landing *in*. `PublishLandingTests` pins the three
/// vocabularies against each other, so a fifth sink cannot appear on one side
/// only.
enum PublishSink: String, CaseIterable, Equatable {
    case notion
    case obsidian
    case filesystem
    case lan

    /// The name Python keys `<stem>.publish.json`'s `sinks` map by, which is the
    /// same `output.sinks` vocabulary as `WorkflowSink.typeName` and
    /// `PublishTarget.sinkTypeName`.
    var sinkTypeName: String { rawValue }

    /// The imperative phrase an affordance that opens this sink's output wears.
    ///
    /// One register, not two, even though the two surfaces open different URLs
    /// for the same sink: the detail header opens Obsidian's `obsidian://` deep
    /// link while the notification opens the note file the publisher wrote. The
    /// phrase names *where the summary landed*, which is true of both.
    var openPhrase: String {
        switch self {
        case .notion:     return "Open in Notion"
        case .obsidian:   return "Open in Obsidian"
        case .filesystem: return "Open the local note"
        case .lan:        return "Open the shared note"
        }
    }
}

/// Where a finished run's summary landed, as far as a surface may claim (UX49).
///
/// Derived from `<stem>.publish.json`, which is the only thing that knows: the
/// per-sink sidecars survive a failed run, and the top-level `page_url` says
/// what to open without saying who produced it.
enum PublishLanding: Equatable {
    /// Exactly one sink landed, so the surface can name it.
    case sink(PublishSink)
    /// There is something to open, but naming one sink would be a guess: more
    /// than one landed (`page_url` is whichever came first in `output.sinks`
    /// order, so naming it would promote a config detail into a claim about
    /// where the meeting lives), or the run's sink map is absent or carries a
    /// name this build does not know.
    case unnamed
    /// Nothing to open. The affordance is absent rather than dead.
    case nowhere

    /// - Parameters:
    ///   - publish: this run's `<stem>.publish.json`, when it wrote one. Absent
    ///     for every `run-all` short-circuit (no speech, BYO, too long, Apple
    ///     hand-off), which is not a failure.
    ///   - pageURL: what the Open affordance would open. Nil is decisive: a
    ///     landing nobody can open is `.nowhere` whatever the sink map says.
    static func decide(publish: PublishResult?, pageURL: URL?) -> PublishLanding {
        guard pageURL != nil else { return .nowhere }
        let landed = (publish?.sinks ?? []).filter { $0.ok }
        guard landed.count == 1, let sink = PublishSink(rawValue: landed[0].name) else {
            return .unnamed
        }
        return .sink(sink)
    }

    /// The phrase a button or a banner reads, or nil when there is nothing to
    /// open at all.
    var openPhrase: String? {
        switch self {
        case .sink(let sink): return sink.openPhrase
        case .unnamed:        return "Open summary"
        case .nowhere:        return nil
        }
    }

    /// Every landing that carries an Open affordance. `Notifier` registers one
    /// notification category per entry, because a category's action titles are
    /// fixed when it is registered.
    static var openable: [PublishLanding] {
        PublishSink.allCases.map(PublishLanding.sink) + [.unnamed]
    }
}

/// What the "meeting done" banner says, derived from what actually published
/// (UX49). Pure so the copy is assertable without a notification center.
struct DoneNotificationCopy: Equatable {
    var title: String
    var body: String
    /// The Open action's title, and the head of the body. Nil when nothing
    /// landed, in which case the banner offers no Open action at all.
    var openPhrase: String?

    /// - Parameter canCorrect: `<stem>.run.json` exists, so the summary is
    ///   gradeable and the banner asks about it.
    static func make(landing: PublishLanding, canCorrect: Bool) -> DoneNotificationCopy {
        let question = "How did this summary look?"
        guard let phrase = landing.openPhrase else {
            // The summary exists (the title says so) and reached no sink: a
            // regulated run whose only sink was Notion, or a short-circuit that
            // never published. The copy this replaced asserted "Local Markdown
            // ready (regulated mode)" for all of them, which keyed a claim about
            // the *mode* off a nil page URL and was therefore a guess.
            return DoneNotificationCopy(
                title: "Meeting processed",
                body: canCorrect ? "Nothing was published. \(question)" : "Nothing was published.",
                openPhrase: nil
            )
        }
        return DoneNotificationCopy(
            title: "Meeting published",
            body: canCorrect ? "\(phrase). \(question)" : phrase,
            openPhrase: phrase
        )
    }
}
