// MeetingPrompt — recreates MeetingPromptWindow.swift
// Floating HUD panel: 380×auto, top-right, hudWindow translucency.
//
// Three signature behaviors:
//   1. App glyph in the eyebrow — surfaces NSWorkspace.shared.icon(forFile:)
//      at runtime; falls back to the signal-blue waveform mark.
//   2. Live mic waveform — 4 bars driven by AVAudioRecorder.averagePower RMS.
//      ONLY visible while the prompt is up; nothing is captured to disk yet.
//      Copy makes that explicit.
//   3. Auto-dismiss progress — 2px hairline along the bottom edge that drains
//      over the timeout (default 30s, from PreferencesWindow → Detection).

const APP_GLYPH_MAP = {
  "Zoom":       "../../assets/app-glyphs/zoom.svg",
  "Teams":      "../../assets/app-glyphs/teams.svg",
  "Microsoft Teams": "../../assets/app-glyphs/teams.svg",
  "Meet":       "../../assets/app-glyphs/meet.svg",
  "Google Meet":"../../assets/app-glyphs/meet.svg",
  "Slack":      "../../assets/app-glyphs/slack.svg",
  "Slack huddle":"../../assets/app-glyphs/slack.svg",
};

const MeetingPrompt = ({
  source = { displayName: "Zoom" },
  timeoutSec = 30,
  onRecord, onSkip, onAlways, onBYO,
}) => {
  const promptStyle = {
    position: "relative",
    width: 380,
    borderRadius: "var(--mp-radius-lg)",
    background: "var(--mp-hud-bg)",
    backdropFilter: "blur(24px) saturate(180%)",
    WebkitBackdropFilter: "blur(24px) saturate(180%)",
    boxShadow: "var(--mp-hud-shadow)",
    border: "0.5px solid var(--mp-hud-stroke)",
    padding: "14px 16px 16px",
    color: "var(--mp-fg)",
    fontFamily: "var(--mp-font-sans)",
    overflow: "hidden",
  };
  const glyphSrc = APP_GLYPH_MAP[source.displayName] ?? "../../assets/app-glyphs/_fallback.svg";

  return (
    <div style={promptStyle}>
      {/* Eyebrow row: app glyph + "Meeting detected" + live waveform */}
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <img
          src={glyphSrc}
          width={24}
          height={24}
          alt=""
          style={{ display: "block", borderRadius: 6, flexShrink: 0 }}
        />
        <div style={{
          fontSize: "var(--mp-text-base)",
          fontWeight: 600,
          color: "var(--mp-fg-muted)",
          flex: 1,
        }}>
          Meeting detected
        </div>
        <LiveWaveform/>
      </div>

      {/* Source name */}
      <div style={{
        fontSize: "var(--mp-text-lg)",
        fontWeight: 600,
        marginTop: 4,
        letterSpacing: "var(--mp-tracking-snug)",
      }}>
        {source.displayName}
      </div>

      {/* Lead + privacy clarification */}
      <div style={{ fontSize: "var(--mp-text-base)", color: "var(--mp-fg-muted)", marginTop: 8 }}>
        Record this meeting?
      </div>
      <div style={{
        fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 4,
        lineHeight: 1.45,
      }}>
        Listening for level only — nothing is captured until you choose Record.
      </div>

      {/* Buttons */}
      <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
        <PromptButton onClick={onSkip}>Skip</PromptButton>
        <PromptButton onClick={onAlways}>Always for {source.displayName}</PromptButton>
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 8, justifyContent: "flex-end" }}>
        <PromptButton onClick={onBYO} title="Record, but skip the API call. You'll summarize the transcript yourself.">Record (BYO)</PromptButton>
        <PromptButton primary onClick={onRecord}>Record</PromptButton>
      </div>

      {/* Auto-dismiss progress hairline */}
      <DismissBar timeoutSec={timeoutSec}/>
    </div>
  );
};

/* -------------------------------------------------------------------------- */
/*  Live waveform — 4 bars, signal600. In Swift this would read
    AVAudioRecorder.averagePower(forChannel:) every ~50ms and map dB → height.
    Here we simulate with smoothed random walk; same visual fingerprint.    */
/* -------------------------------------------------------------------------- */
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
    <div
      aria-hidden
      title="Listening for level"
      style={{
        display: "flex", alignItems: "center", gap: 2,
        height: 14, width: 14 + (4 * 2) /* 14pt visual width */,
        marginRight: -2,
      }}
    >
      {levels.map((lv, i) => (
        <div key={i} style={{
          width: 2,
          height: `${Math.round(lv * 100)}%`,
          background: "var(--mp-signal-600)",
          borderRadius: 1,
          transition: "height 90ms linear",
        }}/>
      ))}
    </div>
  );
};

/* -------------------------------------------------------------------------- */
/*  Dismiss bar — drains over `timeoutSec`. Pauses on hover so users who are
    reading don't lose the prompt out from under them.                        */
/* -------------------------------------------------------------------------- */
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
    <div
      ref={ref}
      style={{
        position: "absolute", left: 0, right: 0, bottom: 0,
        height: 2,
        background: "rgba(20,22,26,0.05)",
      }}
      aria-hidden
    >
      <div style={{
        height: "100%",
        width: `${pct}%`,
        background: "var(--mp-signal-600)",
        opacity: paused ? 0.30 : 0.60,
        transition: "opacity 120ms linear",
      }}/>
    </div>
  );
};

const PromptButton = ({ children, primary, ...rest }) => {
  const base = {
    height: 28,
    padding: "0 12px",
    fontSize: "var(--mp-text-base)",
    fontWeight: 500,
    fontFamily: "inherit",
    borderRadius: "var(--mp-radius-sm)",
    cursor: "pointer",
    transition: "background var(--mp-dur-fast) var(--mp-ease-out)",
  };
  const styles = primary
    ? { ...base, background: "var(--mp-signal-600)", color: "var(--mp-fg-on-signal)", border: "1px solid transparent", boxShadow: "0 1px 0 rgba(20,22,26,0.10)" }
    : { ...base, background: "var(--mp-bg-raised)", color: "var(--mp-fg)", border: "1px solid var(--mp-border-strong)", boxShadow: "0 1px 0 rgba(20,22,26,0.04)" };
  return <button style={styles} {...rest}>{children}</button>;
};

window.MeetingPrompt = MeetingPrompt;
