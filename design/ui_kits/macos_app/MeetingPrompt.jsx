// MeetingPrompt - faithful recreation of MeetingPromptWindow.swift.
// Shipped: a Notion-style HORIZONTAL pill, 600x64, centered near the top of the
// screen (80pt inset), hudWindow translucency, 14pt corner radius.
//
// Layout (left to right): a top-left close x that means Skip, the app glyph, a
// stacked eyebrow (UPPERCASE app name) over the title "Record this meeting?",
// the live mic waveform, the workflow chip, then the action cluster
// [Record (BYO)] [Record] [v]. The secondary actions live under the v chevron
// menu (Always / Skip / Open Screen Recording Settings) because inline buttons
// for "Always for Microsoft Teams" alone are ~190pt and crowd the cluster.
//
// Two signature behaviors are preserved:
//   - Live mic waveform: 4 bars driven by RMS while the prompt is up. Nothing
//     is captured to disk yet, only level is read.
//   - Auto-dismiss: a 2px hairline along the bottom drains over the timeout
//     (default 30s). Pauses on hover so a reader does not lose the prompt.
//
// CAL2 adds the "Last time" disclosure: a quiet ghost capsule left of the
// workflow chip that expands the panel DOWNWARD in place (never a popup, never
// a focus steal) to recap the last meeting in this workflow. It is absent
// entirely when there is nothing to show, which is the common case for a
// workflow's first meeting, so the collapsed pill is unchanged from the above.
//
// AI9 adds the routing hint: when repeated "Change workflow..." corrections
// disagree with the matching rules, the chip carries the corrected workflow and
// an 11pt caption sits directly under it reading "Suggested . Undo". It is a
// caption, not a capsule, deliberately: the pill already has exactly one primary
// action and a third bordered control beside the chip would compete with it. The
// chip rides up 7pt so the pair stays optically centred in the 64pt band. When
// the suggestion is shown but NOT pre-selected (the rules routed the meeting to
// an NDA workflow and the suggestion is not one), the same caption instead reads
// "Use <Workflow>?" and the chip stays on the NDA workflow.

const APP_GLYPH_MAP = {
  "Zoom":        "../../assets/app-glyphs/zoom.svg",
  "Teams":       "../../assets/app-glyphs/teams.svg",
  "Microsoft Teams": "../../assets/app-glyphs/teams.svg",
  "Meet":        "../../assets/app-glyphs/meet.svg",
  "Google Meet": "../../assets/app-glyphs/meet.svg",
  "Slack":       "../../assets/app-glyphs/slack.svg",
  "Slack huddle":"../../assets/app-glyphs/slack.svg",
};

const MeetingPrompt = ({
  source = { displayName: "Zoom" },
  workflow = { name: "General", color: "var(--mp-signal-600)" },
  timeoutSec = 30,
  // AI9. Null (the common case) means no correction pattern exists yet and the
  // caption is not rendered at all, so the pill is unchanged. `preselects:false`
  // is the NDA direction: shown, not armed.
  routingHint = null,
  // The workflow the matching rules picked, which is where Undo goes back to.
  // Only meaningful alongside a preselecting `routingHint`.
  ruleWorkflow = null,
  // CAL2. Null means the workflow has no meeting worth recapping, and then the
  // "Last time" capsule is not rendered at all.
  prepCard = {
    title: "Weekly sync with Acme",
    when: "3 days ago",
    points: ["Scoped the pilot to two regions", "Agreed pricing lands next week"],
    actions: [
      { task: "Send the revised SOW", owner: "Georgy", due: "2026-07-25" },
      { task: "Confirm the pilot scope" },
    ],
    moreActions: 2,
  },
  onRecord, onSkip, onAlways, onBYO,
}) => {
  const glyphSrc = APP_GLYPH_MAP[source.displayName] ?? "../../assets/app-glyphs/_fallback.svg";
  const [expanded, setExpanded] = React.useState(false);
  const showCard = !!prepCard && expanded;
  return (
    <div style={{
      position: "relative", width: 600, height: showCard ? "auto" : 64,
      borderRadius: "var(--mp-radius-lg)",
      background: "var(--mp-hud-bg)",
      backdropFilter: "blur(24px) saturate(180%)",
      WebkitBackdropFilter: "blur(24px) saturate(180%)",
      boxShadow: "var(--mp-hud-shadow)",
      border: "0.5px solid var(--mp-hud-stroke)",
      color: "var(--mp-fg)", fontFamily: "var(--mp-font-sans)", overflow: "hidden",
    }}>
      {/* close x (top-left) == Skip, matching Notion's idiom */}
      <button onClick={onSkip} title="Skip" aria-label="Skip" style={{
        position: "absolute", top: 7, left: 8, width: 16, height: 16, borderRadius: "50%",
        border: "none", background: "transparent", color: "var(--mp-fg-faint)",
        display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer", padding: 0,
      }}><Icon name="x" size={11}/></button>

      <div style={{ display: "flex", alignItems: "center", gap: 12, height: 64, padding: "0 12px 0 26px" }}>
        <img src={glyphSrc} width={28} height={28} alt="" style={{ display: "block", borderRadius: 6, flexShrink: 0 }}/>

        {/* eyebrow + question */}
        <div style={{ display: "flex", flexDirection: "column", justifyContent: "center", minWidth: 0 }}>
          <div style={{
            fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase",
            color: "var(--mp-fg-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
          }}>{source.displayName}</div>
          <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: "-0.01em", marginTop: 1, whiteSpace: "nowrap" }}>Record this meeting?</div>
        </div>

        <div style={{ flex: 1 }}/>

        <LiveWaveform/>

        {/* CAL2 "Last time": ghost capsule, resting fill-less like the v chevron
            so the prompt keeps exactly one primary action. `aria-expanded`
            because it is a disclosure, not a command. */}
        {prepCard && (
          <button
            className="mp-pressable"
            onClick={() => setExpanded((v) => !v)}
            aria-expanded={expanded}
            title={`What the last ${workflow?.name ?? ""} meeting covered`}
            style={{
              height: 22, padding: "0 11px", flexShrink: 0, whiteSpace: "nowrap",
              display: "inline-flex", alignItems: "center", fontFamily: "inherit",
              fontSize: 12, fontWeight: 500, color: "var(--mp-fg)",
              borderRadius: "var(--mp-radius-full)", cursor: "pointer",
              border: "1px solid var(--mp-border)",
              // Appearance-aware, like the workflow chip beside it: the resting
              // state is fill-less on paper and faintly raised on the dark HUD.
              background: expanded ? "var(--mp-bg-raised)" : "transparent",
            }}
          >Last time</button>
        )}

        {workflow && (
          <button title="Change workflow" style={{
            display: "inline-flex", alignItems: "center", gap: 5, height: 22, padding: "0 8px",
            borderRadius: 999, border: "0.5px solid var(--mp-border)", background: "var(--mp-bg-raised)",
            color: "var(--mp-fg-muted)", fontFamily: "inherit", fontSize: 11, cursor: "pointer",
          }}>
            <span style={{ width: 7, height: 7, borderRadius: "50%", background: workflow.color }}/>
            {workflow.name}<Icon name="chevron-down" size={8}/>
          </button>
        )}

        {/* action cluster -- the primary Record is now the Instrument record key */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <PromptButton onClick={onBYO} title="Record, but skip the Anthropic API call. You'll summarize the transcript yourself.">Record (BYO)</PromptButton>
          <PromptRecordKey label="Record" onClick={onRecord}/>
          <PromptButton chevron title={`Always for ${source.displayName}  ·  Skip this meeting  ·  Open Screen Recording Settings…`}>
            <Icon name="chevron-down" size={12}/>
          </PromptButton>
        </div>
      </div>

      {/* AI9 caption. Absolutely positioned in the pill's lower margin, right
          -aligned under the chip it annotates, rather than stacked with the chip
          in the flex row: the waveform is vertically centred and 14pt tall, so a
          caption hung directly under a centred chip lands 2pt inside the
          waveform's box as soon as it is wider than the chip. Down here it clears
          the waveform outright at any width. The Swift pins the same two edges. */}
      {workflow && routingHint && (
        <button
          className="mp-pressable"
          title={routingHint.preselects
            ? `Suggested from ${routingHint.corrections} past corrections. Undo to record under ${ruleWorkflow?.name ?? "the usual workflow"}.`
            : `You moved ${routingHint.corrections} past meetings here. Not pre-selected: this meeting is routed to an NDA workflow.`}
          style={{
            // Borderless on purpose: fg-muted clears the 4.5:1 floor where
            // fg-faint does not, and hover is the only affordance a caption has,
            // so it takes both full-strength fg and an underline.
            position: "absolute", top: 46, right: 194, height: 14, lineHeight: "14px",
            border: "none", background: "transparent", padding: 0, cursor: "pointer",
            fontFamily: "inherit", fontSize: 11, fontWeight: 500,
            color: "var(--mp-fg-muted)", whiteSpace: "nowrap",
          }}
        >{routingHint.preselects ? "Suggested · Undo" : `Use ${routingHint.workflowName}?`}</button>
      )}

      {showCard && <PrepCard card={prepCard}/>}

      <DismissBar timeoutSec={timeoutSec}/>
    </div>
  );
};

/* --------------------------------------------------------------------------
   Prep card (CAL2) - the stratum the panel grows to reveal. Single-line rows
   with tail truncation: it answers "what was this about" at a glance, and the
   Library holds the full text one click away. No mark-done control here; the
   prompt is a read surface and the meeting has not started yet.             */
const PrepCard = ({ card }) => (
  <div style={{
    borderTop: "1px solid var(--mp-border-faint)",
    padding: "10px 12px 14px 14px", display: "flex", flexDirection: "column", gap: 2,
  }}>
    <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
      <div style={{
        fontSize: "var(--mp-text-base)", fontWeight: 600, minWidth: 0,
        whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
      }}>{card.title}</div>
      <div style={{ flex: 1 }}/>
      <div style={{ fontSize: 11, color: "var(--mp-fg-muted)", whiteSpace: "nowrap" }}>{card.when}</div>
    </div>

    <div style={{ marginTop: 4, display: "flex", flexDirection: "column" }}>
      {card.points.map((p, i) => (
        <Row key={i} bullet={<span style={{ color: "var(--mp-fg-muted)" }}>·</span>}>{p}</Row>
      ))}
    </div>

    {card.actions?.length > 0 && (
      <>
        <div style={{
          marginTop: 8, marginBottom: 3, fontSize: 11, fontWeight: 600,
          letterSpacing: "0.08em", textTransform: "uppercase", color: "var(--mp-fg-muted)",
        }}>Open actions</div>
        {card.actions.map((a, i) => (
          <Row key={i} bullet={<Icon name="circle" size={9}/>}>
            {[a.task, a.owner, a.due && `due ${a.due}`].filter(Boolean).join("  ·  ")}
          </Row>
        ))}
        {card.moreActions > 0 && (
          <div style={{ marginLeft: 15, fontSize: 11, color: "var(--mp-fg-muted)" }}>
            {card.moreActions} more in the Library
          </div>
        )}
      </>
    )}
  </div>
);

const Row = ({ bullet, children }) => (
  <div style={{ display: "flex", alignItems: "baseline", gap: 6, height: 18 }}>
    <span style={{ width: 9, flexShrink: 0, color: "var(--mp-fg-muted)" }}>{bullet}</span>
    <span style={{
      fontSize: 12, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
    }}>{children}</span>
  </div>
);

/* --------------------------------------------------------------------------
   Live waveform - 4 bars in on-air (the DSN21 lit-LED capture accent). In Swift
   this reads AVAudioRecorder.averagePower(forChannel:) every ~50ms. Here a
   smoothed random walk gives the same visual fingerprint.                     */
const LiveWaveform = () => {
  const [levels, setLevels] = React.useState([0.4, 0.7, 0.5, 0.3]);
  React.useEffect(() => {
    let raf;
    const tick = () => {
      setLevels((prev) => prev.map((v) => {
        const next = v + (Math.random() - 0.5) * 0.55;
        return Math.max(0.18, Math.min(1, next));
      }));
      raf = setTimeout(() => requestAnimationFrame(tick), 90);
    };
    tick();
    return () => clearTimeout(raf);
  }, []);
  return (
    <div aria-hidden title="Listening for level" style={{ display: "flex", alignItems: "center", gap: 2, height: 16 }}>
      {levels.map((lv, i) => (
        <div key={i} style={{ width: 2, height: `${Math.round(lv * 100)}%`, background: "var(--mp-onair-600)", borderRadius: 1, transition: "height 90ms linear" }}/>
      ))}
    </div>
  );
};

/* --------------------------------------------------------------------------
   Dismiss bar - drains over `timeoutSec`. Pauses on hover.                  */
const DismissBar = ({ timeoutSec }) => {
  const [pct, setPct] = React.useState(100);
  const [paused, setPaused] = React.useState(false);
  const ref = React.useRef();

  React.useEffect(() => {
    const start = performance.now();
    let pausedAt = null;
    let totalPaused = 0;
    let raf;

    const onEnter = () => { pausedAt = performance.now(); };
    const onLeave = () => {
      if (pausedAt) { totalPaused += performance.now() - pausedAt; pausedAt = null; }
    };
    const node = ref.current?.parentElement;
    node?.addEventListener("mouseenter", onEnter);
    node?.addEventListener("mouseleave", onLeave);

    const loop = (now) => {
      const effectivePaused = totalPaused + (pausedAt ? now - pausedAt : 0);
      const elapsed = (now - start - effectivePaused) / 1000;
      const remain = Math.max(0, 1 - elapsed / timeoutSec) * 100;
      setPct(remain);
      setPaused(!!pausedAt);
      if (remain > 0) raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => {
      cancelAnimationFrame(raf);
      node?.removeEventListener("mouseenter", onEnter);
      node?.removeEventListener("mouseleave", onLeave);
    };
  }, [timeoutSec]);

  return (
    <div ref={ref} aria-hidden style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 2, background: "var(--mp-border-faint)" }}>
      <div style={{ height: "100%", width: `${pct}%`, background: "var(--mp-signal-600)", opacity: paused ? 0.30 : 0.60, transition: "opacity 120ms linear" }}/>
    </div>
  );
};

const PromptButton = ({ children, primary, chevron, ...rest }) => {
  const base = {
    height: 26, padding: chevron ? "0 8px" : "0 13px",
    display: "inline-flex", alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
    fontSize: "var(--mp-text-base)", fontWeight: 500, fontFamily: "inherit",
    borderRadius: "var(--mp-radius-full)", cursor: "pointer", flexShrink: 0,
    transition: "background var(--mp-dur-fast) var(--mp-ease-out)",
  };
  const styles = primary
    ? { ...base, background: "var(--mp-signal-fill)", color: "var(--mp-fg-on-signal)", border: "1px solid transparent", boxShadow: "0 1px 0 rgba(22,25,29,0.10)" }
    : { ...base, background: "var(--mp-bg-raised)", color: "var(--mp-fg)", border: "1px solid var(--mp-border-strong)", boxShadow: "0 1px 0 rgba(22,25,29,0.04)" };
  return <button className="mp-pressable" style={styles} {...rest}>{children}</button>;
};

/* --------------------------------------------------------------------------
   Record key (DSN21 "Instrument"): a 40px circular key -- a concentric on-air
   ring inset 5px at 1.5px around a coral disc core -- replacing the text Record
   button. Press travels 1.5px down and compresses the ring (.mp-recordkey). A
   text label sits beside it so the action is never colour alone. On the prompt
   the key is always in its idle (record-a-disc) state; the disc becomes a
   rounded square once recording has started (see the HUD / Library stop key). */
const PromptRecordKey = ({ label = "Record", onClick }) => (
  <button className="mp-recordkey" onClick={onClick} aria-label={label} style={{
    display: "inline-flex", alignItems: "center", gap: 8, padding: 0,
    border: "none", background: "transparent", cursor: "pointer", flexShrink: 0, fontFamily: "inherit",
  }}>
    <span style={{
      position: "relative", width: 40, height: 40, flexShrink: 0,
      borderRadius: "var(--mp-radius-full)", background: "var(--mp-bg-raised)",
      border: "0.5px solid var(--mp-border-strong)", boxShadow: "var(--mp-shadow-xs)",
      display: "flex", alignItems: "center", justifyContent: "center",
    }}>
      <span className="mp-recordkey-ring" style={{ position: "absolute", inset: 5, borderRadius: "var(--mp-radius-full)", border: "1.5px solid var(--mp-onair-600)" }}/>
      <span style={{ width: 15, height: 15, borderRadius: "var(--mp-radius-full)", background: "var(--mp-pulse-600)" }}/>
    </span>
    <span style={{ fontSize: "var(--mp-text-base)", fontWeight: 500, color: "var(--mp-fg)" }}>{label}</span>
  </button>
);

window.MeetingPrompt = MeetingPrompt;
