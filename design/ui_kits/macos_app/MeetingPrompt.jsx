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
  onRecord, onSkip, onAlways, onBYO,
}) => {
  const glyphSrc = APP_GLYPH_MAP[source.displayName] ?? "../../assets/app-glyphs/_fallback.svg";
  return (
    <div style={{
      position: "relative", width: 600, height: 64,
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

      <div style={{ display: "flex", alignItems: "center", gap: 12, height: "100%", padding: "0 12px 0 26px" }}>
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

        {/* action cluster */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <PromptButton onClick={onBYO} title="Record, but skip the Anthropic API call. You'll summarize the transcript yourself.">Record (BYO)</PromptButton>
          <PromptButton primary onClick={onRecord}>Record</PromptButton>
          <PromptButton chevron title={`Always for ${source.displayName}  ·  Skip this meeting  ·  Open Screen Recording Settings…`}>
            <Icon name="chevron-down" size={12}/>
          </PromptButton>
        </div>
      </div>

      <DismissBar timeoutSec={timeoutSec}/>
    </div>
  );
};

/* --------------------------------------------------------------------------
   Live waveform - 4 bars, signal600. In Swift this reads
   AVAudioRecorder.averagePower(forChannel:) every ~50ms. Here a smoothed
   random walk gives the same visual fingerprint.                            */
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
        <div key={i} style={{ width: 2, height: `${Math.round(lv * 100)}%`, background: "var(--mp-signal-600)", borderRadius: 1, transition: "height 90ms linear" }}/>
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

window.MeetingPrompt = MeetingPrompt;
