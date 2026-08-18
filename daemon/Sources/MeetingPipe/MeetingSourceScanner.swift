import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// Cold-start discovery scan: enumerate every concurrent meeting-app contender, score them, return the winner (TECH-C13 step 5). Lifted out of `Detector` so `Detector` and `MeetingDiscoveryWatcher` share one scan path. Carries no timing or state; owner provides the queue. Only retained state is the sticky-winner pin for the scorer's recency tie-break.
final class MeetingSourceScanner {

    /// Outcome of one scan pass.
    struct Result {
        /// Highest-scoring candidate above the disambiguation floor, or nil.
        let winner: MeetingSourceCandidate?
        let candidateCount: Int
        /// True when `winner` differs from the previous pass, so callers can log a winner-change without re-deriving it.
        let winnerChanged: Bool
        /// DET5: running candidates that carried at least one meeting signal but were not the
        /// confident winner (below threshold, uncorroborated, or outscored). Feeds
        /// `candidate_dropped` so DET3's auditor sees "an app was running with evidence and
        /// nothing fired" (a whitelist gap or recognizer rot), not just clean misses.
        let droppedCandidates: [MeetingSourceCandidate]
        /// DET11: whitelisted natives that produced NO signal at all because Accessibility is
        /// untrusted. They are invisible to `droppedCandidates` by construction (that list is
        /// built from candidates which already carry a signal, and every AX-gated native signal is
        /// false under a denied grant), so without this a running Teams call under a denied grant
        /// left not one line in `events.jsonl`. Feeds `candidate_unreadable`.
        ///
        /// DET12 narrowed which natives land here without changing what the list means. Process
        /// audio needs no Accessibility, so a Teams or Zoom candidate actually on the mic now
        /// carries one signal under a denied grant and is reported as a drop instead: still a line
        /// in `events.jsonl`, and a more informative one. An idle native, or any native outside
        /// `readsProcessAudio`, is unreadable exactly as before.
        let unreadableNatives: [MeetingSourceCandidate]
        /// DET6: plain-browser tabs that carried a weak meeting title and were refused at the
        /// admission gate. Invisible to `droppedCandidates` for the same structural reason
        /// `unreadableNatives` is: that list filters `candidates`, and a refused tab never enters
        /// it. Feeds `browser_tab_rejected`.
        let rejectedBrowserTabs: [RejectedBrowserTab]
    }

    /// DET6: one plain-browser tab refused at the admission gate, carried out of the scan so the
    /// refusal can be logged. A browser tab running Teams, Webex or a Slack huddle matches a weak
    /// brand-token title and is then rejected, and until this existed the rejection left no line in
    /// `events.jsonl` at all, so the miss rate could not be measured even in hindsight.
    struct RejectedBrowserTab: Equatable {
        let bundleID: String
        let displayName: String
        /// The window title that matched a weak matcher. A real page title, so it lands in the
        /// event log the way a meeting title already does.
        let title: String
        /// Why it was refused. One value today; a second would appear only if DET6's measurement
        /// widens the gate and introduces a different refusal.
        let reason: String

        /// A brand-token title (`microsoft teams`, `webex`, a `huddle` word) with no strong marker
        /// beside it.
        static let weakTitleOnly = "weak_title_only"
    }

    /// Known native meeting-app bundle IDs from `meeting_apps.toml`.
    let nativeBundles: Set<String>
    /// Known browser bundle IDs that can host a meeting tab.
    let browserBundles: Set<String>
    /// Meeting-URL fragments used to recognise a browser meeting tab.
    let browserURLFragments: [String]

    /// Loaded once per process; failure degrades `muteButton` to false (other signals carry).
    private static let muteCatalogue: MuteLabels? = {
        do {
            return try MuteLabelsLoader.loadDefault()
        } catch {
            return nil
        }
    }()

    /// Last scan's winner for the scorer's sticky-bonus tie-break (TECH-C15).
    private var lastScorerWinner: AppSource?

    /// DET12: the per-scan process-audio reader. One enumeration of the HAL process-object list
    /// serves every candidate in a pass; see `ProcessAudioScanProbe` for why the cache is the
    /// precondition for wiring the read in at all rather than a tuning afterthought.
    private let processAudio: ProcessAudioScanProbe

    /// - Parameter registry: bundle lists (bundled defaults + user overlay). Injectable so tests
    ///   can drive a synthetic registry; production reads `MeetingAppRegistry.shared` (DET4).
    /// - Parameter processAudio: injectable so a test can count enumerations and drive readings
    ///   without a HAL (DET12).
    init(
        registry: MeetingAppRegistry = .shared,
        processAudio: ProcessAudioScanProbe = ProcessAudioScanProbe()
    ) {
        self.nativeBundles = registry.nativeBundles
        self.browserBundles = registry.browserBundles
        self.browserURLFragments = registry.browserURLFragments
        self.processAudio = processAudio
    }

    /// Run one discovery pass and return the winner.
    ///
    /// This used to take a `keepStickyOnEmpty` flag whose `true` mode documented a
    /// mid-recording protection ("a transient empty scan must not unbias the next
    /// pass"). The one production caller passed `false` for the parameter's whole life,
    /// so the protection never existed, and ARCH6 removed it rather than wiring it.
    /// What the pin buys was measured against what wiring it would cost: the pin is a
    /// tie-break bonus in `MeetingSourceScorer.pickBest`, so it decides nothing unless
    /// two candidates score equal (never seen in this Teams-only dogfood), and the only
    /// other thing it feeds is `winnerChanged`, which gates one `discovery_shadow_pick`
    /// log line. Against that, `MeetingDiscoveryWatcher` does not know whether a
    /// recording is running and would have needed that plumbed in. Empty passes mid-call
    /// are common, not rare (DET9 measured 48 s between confident winners, END9 a 21-33 s
    /// AX blackout), so the flag would have been *active* often and still changed nothing
    /// observable. Re-open it if a second simultaneous candidate ever becomes real.
    func scan() -> Result {
        let axTrusted = AXIsProcessTrusted()
        let enumerated = enumerateCandidates(axTrusted: axTrusted)
        return scan(
            candidates: enumerated.candidates,
            axTrusted: axTrusted,
            rejectedBrowserTabs: enumerated.rejectedBrowserTabs
        )
    }

    /// Score an already-enumerated candidate list and return the winner. Split out of `scan` so the
    /// decisions below (the winner, the DET5 dropped list, the DET11 unreadable-native list) can be
    /// driven with explicit inputs: the enumeration above is the only half that needs a real
    /// workspace, and the Accessibility-denied case is otherwise untestable because `AXIsProcessTrusted`
    /// is a process-wide read no test can flip. Internal, not private, for exactly that reason.
    /// `rejectedBrowserTabs` is passed in rather than derived here, because a refused tab is not in
    /// `candidates` by definition (DET6). It defaults to empty so a caller driving only the scoring
    /// decisions does not have to spell it.
    func scan(
        candidates: [MeetingSourceCandidate],
        axTrusted: Bool,
        rejectedBrowserTabs: [RejectedBrowserTab] = []
    ) -> Result {
        var candidates = candidates
        let winner = MeetingSourceScorer.pickBest(&candidates, lastWinner: lastScorerWinner)
        let count = candidates.count
        // `pickBest` scored `candidates` in place; a dropped candidate is a running app that
        // carried a signal but is not the winner (DET5, for DET3's auditor).
        let dropped = candidates.filter {
            MeetingSourceScorer.distinctSignalCount($0.signals) > 0
                && $0.source.bundleID != winner?.source.bundleID
        }
        let unreadable = MeetingSourceScanner.unreadableNatives(in: candidates, axTrusted: axTrusted)
        guard let winner = winner else {
            // An empty pass drops the pin, so the next pass scores unbiased.
            lastScorerWinner = nil
            return Result(
                winner: nil,
                candidateCount: count,
                winnerChanged: false,
                droppedCandidates: dropped,
                unreadableNatives: unreadable,
                rejectedBrowserTabs: rejectedBrowserTabs
            )
        }
        let changed = lastScorerWinner?.bundleID != winner.source.bundleID
        lastScorerWinner = winner.source
        return Result(
            winner: winner,
            candidateCount: count,
            winnerChanged: changed,
            droppedCandidates: dropped,
            unreadableNatives: unreadable,
            rejectedBrowserTabs: rejectedBrowserTabs
        )
    }

    /// DET11: the natives a denied Accessibility grant made unreadable. Pure.
    ///
    /// With AX untrusted, `collectSignals` skips every AX-gated signal, so a native is enqueued
    /// (natives are always enqueued) and then dropped by the scorer's zero-evidence filter. Both
    /// halves are correct on their own and the result is a start-detection blackout that emits
    /// nothing: not a `candidate_dropped` (that list needs a signal), not a `discovery_shadow_pick`
    /// (there is no winner). Four user-facing surfaces said the cost of denying Accessibility was
    /// a late auto-stop, which is what the silence let stand for months.
    ///
    /// DET12 left one signal outside that gate: a Teams or Zoom candidate whose process audio reads
    /// true is no longer zero-evidence, so it drops out of this list and into `droppedCandidates`.
    /// That is the intended narrowing, not a hole. It does not make the AX-denied machine detect a
    /// meeting, since one signal does not clear `isConfidentNativeMeeting`; it makes the candidate
    /// visible with its evidence attached instead of visible as a permission complaint.
    ///
    /// Browsers and PWAs are absent by construction rather than by choice: their branches `guard
    /// axTrusted` before enqueueing at all, so a denied grant leaves nothing here to name. That is
    /// why this reports natives only, and why "no candidate at all" remains the right reading of an
    /// AX-denied browser meeting.
    static func unreadableNatives(
        in candidates: [MeetingSourceCandidate],
        axTrusted: Bool
    ) -> [MeetingSourceCandidate] {
        guard !axTrusted else { return [] }
        return candidates.filter {
            $0.source.kind == .native && MeetingSourceScorer.distinctSignalCount($0.signals) == 0
        }
    }

    // MARK: Candidate enumeration

    /// One enumeration pass: the candidates, plus the plain-browser tabs it refused (DET6). The
    /// refusals ride out separately because they are precisely the things that are *not* candidates.
    struct Enumeration {
        let candidates: [MeetingSourceCandidate]
        let rejectedBrowserTabs: [RejectedBrowserTab]
    }

    /// Produce one candidate per concurrent meeting-app contender. Native bundles are always included (scorer rejects those with zero signals, and DET11's `unreadableNatives` names the ones a denied Accessibility grant left with none). Browsers only qualify when at least one window matches a meeting-pattern title.
    private func enumerateCandidates(axTrusted: Bool) -> Enumeration {
        // DET12: one HAL process-object enumeration serves every candidate below. Dropping the
        // snapshot here rather than holding it across scans is deliberate; a synchronous scan has no
        // list-change listener to tell it when a cached object ID went stale.
        processAudio.beginScan()
        let apps = NSWorkspace.shared.runningApplications
        // DET5 walk-gate inputs (see `shouldWalkControlAX`): the frontmost app, and whether
        // exactly one native meeting app is running (so a lone native's control walk is cheap
        // and worth running even when its window title was renamed out of the recognizer).
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let loneNative = apps.reduce(into: 0) { count, a in
            if let b = a.bundleIdentifier, nativeBundles.contains(b) { count += 1 }
        } == 1
        var candidates: [MeetingSourceCandidate] = []
        var rejectedBrowserTabs: [RejectedBrowserTab] = []

        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier

            if nativeBundles.contains(bid) {
                let source = AppSource(
                    bundleID: bid,
                    displayName: app.localizedName ?? bid,
                    kind: .native
                )
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .native,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: nil,
                    isFrontmost: bid == frontmostBundle,
                    isLoneNative: loneNative
                )
                candidates.append(MeetingSourceCandidate(
                    source: source,
                    signals: signals,
                    hasAudioLeg: !MeetingSourceScanner.webexBundleIDs.contains(bid)
                ))
                continue
            }

            if browserBundles.contains(bid) {
                // Requires AX trust: without it we can't read window titles to confirm a meeting tab.
                // Natives are still enqueued without AX because they can win on audio + button signals alone.
                // START2/AUD-3: browsers put the PAGE TITLE in the window title, never the URL, so a
                // plain-tab Meet/Teams-web meeting is matched against the same page-title patterns the
                // browser lifecycle adapter owns (as the PWA branch below already does), keeping the URL
                // fragment as a bonus signal for any browser that does surface the URL in the title.
                guard axTrusted else { continue }
                // DET6 lifted the whole decision below into `decideBrowserAdmission`, a pure
                // function over the window titles. Two things fall out of that. The titles are now
                // collected once instead of once per predicate (the branch used to run up to three
                // separate recursive AX window walks per browser per scan), and every case the gate
                // can reach is reachable from a test, which it was not while the guards sat inline
                // in this `private` method behind live AX reads.
                let windowTitles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) ?? []
                let admission = MeetingSourceScanner.decideBrowserAdmission(
                    windowTitles: windowTitles,
                    urlFragments: browserURLFragments
                )
                let displayName = app.localizedName ?? "Browser"
                // END5: a strong meeting title / URL (a Google Meet code, `meet.google.com`) stands
                // alone; a bare brand-token title (a page whose title merely contains "webex" /
                // "microsoft teams" / "huddle") can't be told from a doc *about* those products, so
                // it is rejected here.
                //
                // END5 originally let such a title in when live process audio corroborated it (a
                // real browser call holds the mic). DET2 closed that signal on 2026-07-20, so the
                // disjunct was removed rather than left reading as if corroboration were still
                // possible. DET8 later refuted that close and revived the signal (2026-08-05: DET2
                // had translated the shell PID, which never registers as a CoreAudio client), but
                // end-side only, and did NOT re-add this disjunct. Re-admitting bare brand-token
                // titles is a start-side false-positive question, which is DET6's to answer with a
                // measurement rather than a free consequence of the end-side flip. The refusal
                // below is therefore still live today: a plain browser tab running Teams, Webex or
                // a Slack huddle never becomes a candidate, and Zoom-in-browser never reaches here
                // at all (no Zoom title matcher). Only Google Meet clears the strong gate, because
                // `strongTitleMatchers` holds only the Meet room-code pattern and the URL-fragment
                // disjunct reads the window title, which browsers fill with the page title and not
                // the URL.
                //
                // What DET6 changed is that the refusal is no longer silent. It still does not
                // enter `candidates`, so `droppedCandidates` still cannot see it; instead it rides
                // out on `rejectedBrowserTabs` and the watcher emits `browser_tab_rejected`, which
                // is what makes the miss rate countable. Native apps and Chromium PWAs remain
                // unaffected (the PWA branch below has no such gate).
                //
                // Do not "fix" this by widening `strongTitleMatchers`: an unmeasured widening
                // reopens the doc-title false start END5 closed. The measurement is DET6's probe
                // (`daemon/scripts/det6-browser-url-probe.swift`) and its pre-registered verdict
                // tree in `docs/spikes/det6-browser-url-readability.md`.
                switch admission {
                case .noMeetingSignal:
                    // Not a meeting window at all. Every browser on the machine is in this state
                    // most of the day, so it stays silent: this is a clean miss, not a refusal.
                    continue
                case .weakTitleOnly(let matchedTitle):
                    rejectedBrowserTabs.append(RejectedBrowserTab(
                        bundleID: bid,
                        displayName: displayName,
                        title: matchedTitle,
                        reason: RejectedBrowserTab.weakTitleOnly
                    ))
                    continue
                case .admit:
                    break
                }
                let source = AppSource(
                    bundleID: bid,
                    displayName: displayName,
                    kind: .browser
                )
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .browser,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: true,
                    isFrontmost: bid == frontmostBundle,
                    isLoneNative: false
                )
                candidates.append(MeetingSourceCandidate(source: source, signals: signals))
                continue
            }

            if BrowserMeetingLifecycleAdapter.isPWABundleID(bid) {
                // Chromium "installed PWA" (e.g. Google Meet as a desktop app): own process with a per-install bundle ID absent from both TOML lists (TECH-I5). No address bar, so windows carry page titles; match meeting-title patterns rather than URL fragments. Treated as `.browser` so existing browser end-detection and MicGate fallback apply.
                // Title matcher is strict and rejects transient solo-start titles; fall back to the PWA's localizedName, which the web manifest sets at install time and keeps stable across the meeting lifecycle (e.g. "Google Meet", "Microsoft Teams").
                guard axTrusted else { continue }
                let titleMatched = anyWindowMatchesMeetingTitle(pid: pid)
                let nameMatched = BrowserMeetingLifecycleAdapter
                    .matchesKnownMeetingPWA(localizedName: app.localizedName)
                guard titleMatched || nameMatched else { continue }
                let source = AppSource(
                    bundleID: bid,
                    displayName: app.localizedName ?? "Meeting",
                    kind: .browser
                )
                // START3/AUD-4: pass the REAL title match, not a synthetic `true`. A meeting-named PWA
                // idling on its landing page matches on `localizedName` alone, with no meeting-titled
                // window; stamping `titleMatch = true` there fabricated evidence that let the scorer
                // prompt on an idle PWA. With the honest value a name-only admission carries
                // `titleMatch = false`, so it must earn its place via an in-call corroborator
                // (the scorer's lone-candidate gate) or be dropped as zero-evidence.
                let signals = collectSignals(
                    bundleID: bid,
                    kind: .browser,
                    pid: pid,
                    axTrusted: axTrusted,
                    preTitleMatch: titleMatched,
                    isFrontmost: bid == frontmostBundle,
                    isLoneNative: false
                )
                candidates.append(MeetingSourceCandidate(source: source, signals: signals))
            }
        }

        return Enumeration(candidates: candidates, rejectedBrowserTabs: rejectedBrowserTabs)
    }

    /// Cisco Webex keeps the mic open after a call for ultrasound device discovery. That is why it
    /// was excluded from the original process-audio probe, and this set does two jobs beyond that
    /// exclusion: `shouldWalkControlAX` always walks these bundles, and `hasAudioLeg` is false for
    /// them so the scorer holds them to DET4's single-corroborator bar.
    ///
    /// It is no longer the audio exclusion itself. DET12 brought a start-side read back and pointed
    /// its gate at `NativeLifecycleConfig.usesProcessAudio`, which answers false for Webex and spark
    /// for the same ultrasound reason, so the carve-out is stated once for both ends of the meeting
    /// rather than duplicated here. Do not re-add it below.
    private static let webexBundleIDs: Set<String> = ["com.cisco.webexmeetingsapp", "com.cisco.spark"]

    /// PERF6 + DET5: whether the three control-button AX walks (toolbar / leave / mute) are worth
    /// running for a candidate. They are recursive AX-tree IPC and dominate idle discovery CPU,
    /// so PERF6 skips them for a backgrounded app that shows no cheap sign of a live meeting.
    ///
    /// DET5 adds two "this app deserves a walk even without a title match" cases, because start
    /// detection was single-gated on the exact window title and the audio leg is dead, so one
    /// vendor rename (a Zoom build that drops "Zoom Meeting" from the title) silently killed that
    /// app's start detection. `isFrontmost` (the user is actively looking at the window) and
    /// `isLoneNative` (it is the only native meeting app running, so the walk is cheap and there
    /// is nothing to disambiguate) both admit the walk. PERF6's cost gate still bites for an idle
    /// backgrounded app in a multi-native scan. Webex always walks (see `webexBundleIDs`).
    ///
    /// `processAudioIsRunningInput` is the fourth admission and the oldest: it was one of PERF6's two
    /// original preconditions, removed by the DET2 cleanup (2026-07-20) because the read could never
    /// be true, and restored by DET12 once DET8 measured that it can. It is the only admission here
    /// that is evidence of a live call rather than a cheap guess that one is plausible, so a Teams
    /// window renamed out of the recognizer while backgrounded in a multi-native scan now gets its
    /// control walk on the strength of the mic instead of being skipped.
    static func shouldWalkControlAX(
        titleMatch: Bool,
        processAudioIsRunningInput: Bool,
        isFrontmost: Bool,
        isLoneNative: Bool,
        bundleID: String
    ) -> Bool {
        if webexBundleIDs.contains(bundleID) { return true }
        return titleMatch || processAudioIsRunningInput || isFrontmost || isLoneNative
    }

    /// DET12: whether this candidate's process audio is read at all. The single gate, which is what
    /// lets `MeetingSourceScorer.hasCorroboratingSignal` OR the signal in without re-asking about
    /// kind.
    ///
    /// Native only, and then only the bundles whose lifecycle config opts in. Pointing at
    /// `NativeLifecycleConfig.usesProcessAudio` rather than keeping a second list here is the point:
    /// the start and end sides read the same HAL property, so which apps that read is trusted for is
    /// one fact, and turning Slack or Webex on stays a measurement rather than a flag flip on either
    /// side. Browsers and Chromium PWAs answer false because they hold no native config: a browser on
    /// the mic names the browser and never the tab, and whether a browser tab may be admitted on any
    /// evidence is DET6's question, gated on DET6's own measurement.
    static func readsProcessAudio(bundleID: String, kind: AppSourceKind) -> Bool {
        kind == .native && NativeLifecycleConfig.usesProcessAudio(bundleID: bundleID)
    }

    /// DET12: read one candidate's process audio, off the per-scan snapshot.
    ///
    /// Internal so a test can drive it with a counting probe: the enumeration-once-per-scan property
    /// is the precondition this whole seam rests on, and `enumerateCandidates` around it needs a real
    /// `NSWorkspace`. An unknown read (nothing matched, or the list would not enumerate) degrades to
    /// false, like every other signal in the tuple.
    func processAudioIsRunningInput(bundleID: String, kind: AppSourceKind, pid: pid_t) -> Bool {
        guard MeetingSourceScanner.readsProcessAudio(bundleID: bundleID, kind: kind) else {
            return false
        }
        return processAudio.isRunningInput(bundleID: bundleID, pid: pid) ?? false
    }

    /// Populate the signal tuple. Each signal degrades to false on a read failure, and every signal
    /// but `processAudioIsRunningInput` also degrades to false when Accessibility is denied (DET12
    /// put that one read outside the gate on purpose; see below).
    /// `preTitleMatch` short-circuits the per-bundle recognizer: browsers pass the already-computed
    /// browser title/URL match (`true` for a plain tab vetted by URL/title; the real per-window result
    /// for a PWA, which is `false` on a name-only admission, START3/AUD-4); natives pass `nil` so the recognizer runs.
    private func collectSignals(
        bundleID: String,
        kind: AppSourceKind,
        pid: pid_t,
        axTrusted: Bool,
        preTitleMatch: Bool?,
        isFrontmost: Bool,
        isLoneNative: Bool
    ) -> MeetingSourceCandidate.Signals {
        var signals = MeetingSourceCandidate.Signals()

        // DET12: the per-process audio read, ahead of the AX walks and OUTSIDE the `axTrusted` gate
        // below. Both halves of that placement are load-bearing.
        //
        // Ahead of the walks because it is one of PERF6's gate preconditions again: a true reading is
        // evidence of a live call, and it admits the recursive control-button walks for a candidate
        // that today is gated on cheaper and weaker evidence (a title, being frontmost, being alone).
        //
        // Outside the AX gate because it needs no Accessibility grant and no Screen Recording grant.
        // DET8's enumeration resolved from a disclaimed harness shell holding no TCC grant at all,
        // and DET11 established that every other native signal is AX-gated, after which the scorer
        // drops the zero-signal candidate. So on an Accessibility-denied machine this is the only
        // signal a native can carry, which is the difference between a candidate that leaves a
        // reasoned line in `events.jsonl` and one that vanishes. Moving this read inside the gate
        // would silently undo that.
        //
        // The cost that got the pre-DET2 probe removed is handled by the cache rather than by
        // skipping the read: resolution is now a whole-list enumeration, heavier than the old
        // per-process translate, so `ProcessAudioScanProbe` enumerates once per scan and matches every
        // candidate against that one snapshot.
        signals.processAudioIsRunningInput = processAudioIsRunningInput(
            bundleID: bundleID,
            kind: kind,
            pid: pid
        )

        if axTrusted {
            let axApp = AXUIElementCreateApplication(pid)

            if let pre = preTitleMatch {
                signals.titleMatch = pre
            } else if let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) {
                signals.titleMatch = titles.contains { title in
                    MeetingSourceScanner.isActiveMeetingWindow(
                        bundleID: bundleID,
                        kind: kind,
                        title: title
                    )
                }
            }

            // PERF6: only descend the recursive control-button trees when a cheap precondition
            // says a live meeting is plausible. An idle backgrounded app skips the walk and keeps
            // the default (false) control signals, which the scorer treats identically to
            // "walked and found nothing".
            if MeetingSourceScanner.shouldWalkControlAX(
                titleMatch: signals.titleMatch,
                processAudioIsRunningInput: signals.processAudioIsRunningInput,
                isFrontmost: isFrontmost,
                isLoneNative: isLoneNative,
                bundleID: bundleID
            ) {
                signals.callingControlsToolbar = MeetingAXHandleBuilder
                    .findCallingControlsToolbar(in: axApp, bundleID: bundleID) != nil

                signals.leaveButton = !MeetingAXHandleBuilder
                    .findAllLeaveButtons(in: axApp, bundleID: bundleID).isEmpty

                if let catalogue = MeetingSourceScanner.muteCatalogue {
                    signals.muteButton = !MeetingAXHandleBuilder
                        .findAllMuteButtons(
                            in: axApp,
                            bundleID: bundleID,
                            catalogue: catalogue
                        ).isEmpty
                }
            }
        }

        // shareableContentActive left false: SCShareableContent is async and the scan path is synchronous; needs an async pre-scan cache before it can be wired in.
        return signals
    }

    /// True when any AX window of `pid` matches a browser meeting-title pattern: a browser/PWA window carries the page title, not the URL, so it matches title patterns from the browser lifecycle adapter. Used by the Chromium PWA branch; the plain-browser branch reads its titles once and routes them through `decideBrowserAdmission` instead (DET6).
    private func anyWindowMatchesMeetingTitle(pid: pid_t) -> Bool {
        guard let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) else {
            return false
        }
        return titles.contains { MeetingSourceScanner.browserWindowIndicatesMeeting(title: $0) }
    }

    /// True when a browser/PWA window `title` looks like an active meeting. Pure (no AX), so the
    /// browser-discovery contract is unit-testable. START2/AUD-3: browsers put the page title, never
    /// the URL, in the window title, so a plain-tab Meet/Teams-web meeting is admitted by these
    /// patterns rather than the URL fragment. Shares the browser lifecycle adapter's matchers so
    /// discovery and end-detection agree on what a meeting window looks like.
    static func browserWindowIndicatesMeeting(title: String) -> Bool {
        BrowserMeetingLifecycleAdapter.defaultTitleMatchers.contains { $0(title) }
    }

    /// True when a browser/PWA window `title` matches a *strong* meeting pattern (END5): one that
    /// carries live-call structure (a Google Meet code / host) and so is trustworthy on its own at
    /// START, versus a bare brand-token match that also fires on pages about those products.
    static func browserWindowIndicatesStrongMeeting(title: String) -> Bool {
        BrowserMeetingLifecycleAdapter.strongTitleMatchers.contains { $0(title) }
    }

    // MARK: Plain-browser admission (DET6)

    /// What the plain-browser admission gate decided about one browser process, given its AX window
    /// titles. Pure, and that is the point: the gate used to be two inline `guard`s inside a
    /// `private` method behind live AX reads, so not one of the cases below could be pinned without
    /// a real browser holding a real call.
    enum BrowserAdmission: Equatable {
        /// Strong evidence. Enqueue the browser as a candidate.
        case admit
        /// No meeting signal at all, not even a weak brand token. A clean miss, and deliberately
        /// silent: this is the state every browser on the machine is in most of the day.
        case noMeetingSignal
        /// A weak brand-token title with nothing strong beside it, which is refused (END5: such a
        /// title also fires on a page *about* the product, e.g. "Webex vs Zoom Comparison"). Carries
        /// the title that matched, so the refusal can be reported instead of vanishing.
        case weakTitleOnly(matchedTitle: String)
    }

    /// Decide whether a plain browser tab is admitted as a meeting candidate.
    ///
    /// The three outcomes are exactly the three the inline guards had, in the same order:
    /// a URL fragment or a strong title admits, a weak title alone is refused, and anything else was
    /// never a meeting window. What changed with DET6 is only that the middle case is now a value
    /// rather than a bare `continue`.
    ///
    /// `urlFragments` is checked against the window TITLE, which is the defect DET6 exists to
    /// measure rather than to guess at: browsers put the page title there and never the URL, so this
    /// disjunct effectively never fires and every non-Meet product falls through to the weak case.
    /// It is left reading the title on purpose until the probe says whether the real URL is
    /// reachable through an accessible channel. See `docs/spikes/det6-browser-url-readability.md`.
    static func decideBrowserAdmission(
        windowTitles: [String],
        urlFragments: [String]
    ) -> BrowserAdmission {
        let fragmentMatch = windowTitles.contains { title in
            let lowered = title.lowercased()
            return urlFragments.contains { lowered.contains($0) }
        }
        if fragmentMatch { return .admit }
        guard let weakTitle = windowTitles.first(where: { browserWindowIndicatesMeeting(title: $0) })
        else {
            return .noMeetingSignal
        }
        if windowTitles.contains(where: { browserWindowIndicatesStrongMeeting(title: $0) }) {
            return .admit
        }
        return .weakTitleOnly(matchedTitle: weakTitle)
    }

    // MARK: Window-title recognizer

    /// True when `title` belongs to an active meeting window for the given app. Distinct from the per-app title extractors: those return nil for bare valid windows; this recognizer must be permissive about bare windows because a false negative here cuts the recording mid-call. Upstream caller ORs across all windows, so a single true is enough.
    static func isActiveMeetingWindow(bundleID: String, kind: AppSourceKind, title: String) -> Bool {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)

        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            // Active meeting windows always contain "zoom meeting". Idle launcher and dialogs explicitly rejected.
            if lowered == "zoom" { return false }                    // launcher
            if lowered.hasPrefix("schedule meeting") { return false } // dialog
            if lowered.hasPrefix("join meeting") { return false }     // dialog
            return lowered.contains("zoom meeting")

        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            // Teams (May 2026) dropped the "Meeting in/with <X>" prefix - title is now just the topic (e.g. "Echo | Microsoft Teams", "Standup | Microsoft Teams", or bare "Echo").
            // Old prefix-based recognizer was too strict and killed recordings mid-call. New contract prefers false-positives (recording into a stale thread; silence detector catches it at 5 min) over false-negatives (audio lost).
            // Reject only well-known chrome surfaces; both the bare and "| Microsoft Teams" forms share the same blacklist.
            let chrome: Set<String> = [
                "microsoft teams",
                "teams",
                "calendar",
                "settings",
                "activity",
                "chat",
                "files",
                "apps",
                "store",
                "join meeting",
                "schedule meeting",
            ]
            if chrome.contains(lowered) { return false }
            if lowered.hasSuffix("| microsoft teams") {
                let lead = String(lowered.dropLast("| microsoft teams".count))
                    .trimmingCharacters(in: .whitespaces)
                if lead.isEmpty { return false }                     // bare app chrome
                if chrome.contains(lead) { return false }
                return true
            }
            // No suffix - Teams sometimes spawns the meeting window with just the topic. Can't distinguish from chrome by title alone; blacklist above filters known chrome; empty title is inconclusive (upstream ORs across windows so it contributes nothing).
            return !lowered.isEmpty

        case ("com.cisco.webexmeetingsapp", _), ("com.cisco.spark", _):
            // Reject the idle launcher ("Webex" / "Cisco Webex") first: the scanner (start-side)
            // must be stricter about idle windows than the lifecycle adapter (end-side), which
            // tolerates a bare "Webex" reading live because a late end is only caught by the
            // backstop. The active meeting title and spark's shared Teams-style "Meeting" stem
            // then route through the shared vendor matcher, so the scanner recognizer and the
            // adapter cannot drift, and spark (added to meeting_apps.toml in DET4) gets a
            // recognizer branch instead of falling through to `default`.
            if lowered == "webex" || lowered == "cisco webex" { return false }
            return MeetingTitlePatterns.webex(title)

        case ("com.tinyspeck.slackmacgap", _):
            // Shared word-boundary huddle matcher (DET5), so discovery and the lifecycle adapter
            // cannot diverge. "team-huddles" (plural channel name) fails the boundary.
            return MeetingTitlePatterns.slackHuddle(title)

        default:
            // Unknown native bundle; probe upstream short-circuits before reaching here under normal operation.
            return false
        }
    }

    /// Walk AX windows of `pid` and return all non-empty titles. Returns `nil` (not `[]`) when AX reads fail outright (Accessibility revoked, process gone).
    static func collectAXWindowTitles(pid: pid_t) -> [String]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        var titles: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            titles.append(title)
        }
        return titles
    }
}
