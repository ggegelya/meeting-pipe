// RecordingHUD - faithful recreation of RecordingHUDWindow.swift.
// Shipped: a compact vertical floating pill, 60x162, top-right (16pt inset),
// always-on-top, hudWindow translucency, draggable. Exists because the menu-bar
// coral dot is easy to miss, and one-click Stop is essential for a "this got
// sensitive, kill it" moment.
//
// Layout (top to bottom): app glyph (24), the pulsing coral recording dot with
// its "Recording" label, the elapsed timer (the 24px anchor, mono tabular, grown
// under the Instrument layer), the voice-activity meter (10 discrete on-air LED
// segments, TECH-UX8), the workflow attribution line (TECH-B9), and the record
// key in its stop form (on-air ring + coral rounded square) at the foot.
//
// Second frozen frame: the degraded state (TECH-UX4). When system-audio capture
// fails mid-recording the pill widens into a card (232 wide) and a banner
// appears at the foot: "System audio not captured" + a one-click retry. Copy is
// verbatim from the Swift source.
//
// All top-level names are HUD-prefixed: the kit shares one global lexical scope.

const HUD_GLYPH = {
  Zoom: "../../assets/app-glyphs/zoom.svg",
  Teams: "../../assets/app-glyphs/teams.svg",
  Meet: "../../assets/app-glyphs/meet.svg",
  Slack: "../../assets/app-glyphs/slack.svg",
};

const RecordingHUD = ({
  source = "Zoom",
  workflow = "Engineering",
  elapsed = "12:07",
  meterLit = 6,
  degraded = false,
}) => {
  const glyphSrc = HUD_GLYPH[source];
  return (
    <div style={{
      position: "relative", boxSizing: "border-box",
      width: degraded ? 232 : 60, minHeight: 162,
      paddingTop: 12, paddingBottom: degraded ? 8 : 10,
      display: "flex", flexDirection: "column", alignItems: "center",
      borderRadius: "var(--mp-radius-lg)",
      background: "var(--mp-hud-bg)",
      backdropFilter: "blur(24px) saturate(180%)",
      WebkitBackdropFilter: "blur(24px) saturate(180%)",
      boxShadow: "var(--mp-hud-shadow)",
      border: "0.5px solid var(--mp-hud-stroke)",
      color: "var(--mp-fg)", fontFamily: "var(--mp-font-sans)", overflow: "hidden",
    }}>
      <style>{`
        @keyframes hudPulse { 0%,100%{opacity:1} 50%{opacity:.35} }
        @media (prefers-reduced-motion: reduce) { .hud-dot { animation: none !important; } }
      `}</style>

      {glyphSrc
        ? <img src={glyphSrc} width={24} height={24} alt="" style={{ display: "block", borderRadius: 6, flexShrink: 0 }}/>
        : <span style={{ color: "var(--mp-fg)", display: "flex" }}><Icon name="waveform-circle" size={22}/></span>}

      {/* pulsing coral recording dot + label; never colour alone */}
      <div style={{ display: "flex", alignItems: "center", gap: 5, marginTop: 8 }}>
        <span className="hud-dot" style={{ width: 8, height: 8, borderRadius: "var(--mp-radius-full)", background: "var(--mp-pulse-600)", animation: "hudPulse 1.6s ease-in-out infinite" }}/>
        <span style={{ fontSize: 10, fontWeight: 500, color: "var(--mp-fg-muted)" }}>Recording</span>
      </div>

      {/* elapsed timer -- the 24px surface anchor, mono tabular (Instrument) */}
      <div style={{ marginTop: 4, fontFamily: "var(--mp-font-mono)", fontVariantNumeric: "tabular-nums", fontSize: 24, fontWeight: 600, lineHeight: 1.1, color: "var(--mp-fg)" }}>{elapsed}</div>

      <HUDMeter lit={meterLit}/>

      <HUDWorkflowLine name={workflow}/>

      <div style={{ flex: 1, minHeight: 10 }}/>

      <HUDStopKey/>

      {degraded && <HUDBanner/>}
    </div>
  );
};

/* Voice-activity meter (TECH-UX8): 10 discrete LED segments, one per 6 dB. Lit
   segments run on-air (the Instrument lit-LED accent); the rest are hairline.
   Steps rather than slides -- no transition. Decorative (aria-hidden): the coral
   dot + "Recording" label carry the state. */
const HUDMeter = ({ lit = 6 }) => (
  <div aria-hidden style={{ display: "flex", alignItems: "center", gap: 2, width: 40, height: 6, marginTop: 6 }}>
    {Array.from({ length: 10 }, (_, i) => (
      <div key={i} style={{ flex: 1, height: "100%", borderRadius: 1, background: i < lit ? "var(--mp-onair-600)" : "var(--mp-border)" }}/>
    ))}
  </div>
);

/* Workflow attribution (TECH-B9): the name on its own row, truncating tail
   rather than widening the 60pt pill. */
const HUDWorkflowLine = ({ name }) => (
  name ? (
    <div style={{ marginTop: 4, maxWidth: "100%", padding: "0 4px", fontSize: 10, fontWeight: 500, color: "var(--mp-fg-muted)", textAlign: "center", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{name}</div>
  ) : null
);

/* Stop key: the Instrument record key in its recording form -- a 40px circular
   key with a concentric on-air ring (inset 5px, 1.5px) around a coral rounded
   square (the stop affordance; coral stays the recording colour). Press travels
   1.5px + compresses the ring (.mp-recordkey). */
const HUDStopKey = () => (
  <button className="mp-recordkey" title="Stop recording" aria-label="Stop recording" style={{
    position: "relative", width: 40, height: 40, flexShrink: 0, padding: 0, cursor: "pointer",
    borderRadius: "var(--mp-radius-full)", background: "var(--mp-bg-raised)",
    border: "0.5px solid var(--mp-border-strong)", boxShadow: "var(--mp-shadow-xs)",
    display: "flex", alignItems: "center", justifyContent: "center",
  }}>
    <span className="mp-recordkey-ring" style={{ position: "absolute", inset: 5, borderRadius: "var(--mp-radius-full)", border: "1.5px solid var(--mp-onair-600)" }}/>
    <span style={{ width: 13, height: 13, borderRadius: 3, background: "var(--mp-pulse-600)" }}/>
  </button>
);

/* Degraded banner (TECH-UX4): warns that system-audio capture failed to start
   and offers a one-click retry. Copy verbatim from RecordingHUDWindow.swift. */
const HUDBanner = () => (
  <div style={{ alignSelf: "stretch", marginTop: 10, padding: "0 8px", display: "flex", flexDirection: "column", gap: 6 }}>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
      <span style={{ color: "var(--mp-warning-600)", display: "flex", flexShrink: 0 }}><Icon name="alert-triangle" size={12}/></span>
      <span style={{ fontSize: 10, fontWeight: 500, color: "var(--mp-fg-muted)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>System audio not captured</span>
    </div>
    <button className="mp-pressable" style={{
      height: 22, width: "100%", padding: "0 10px", cursor: "pointer",
      borderRadius: "var(--mp-radius-full)", border: "0.5px solid var(--mp-border-strong)",
      background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
      fontFamily: "inherit", fontSize: 10, fontWeight: 500,
    }}>Retry system audio</button>
  </div>
);

window.RecordingHUD = RecordingHUD;
