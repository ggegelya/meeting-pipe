// OnboardingPermissions — anticipated surface; visualizes the four-permission grant flow from SPEC.md §8.
const OnboardingPermissions = () => (
  <div style={{ width: 520, padding: 32, background: "var(--mp-bg)", fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)", borderRadius: 14, border: "1px solid var(--mp-border)", boxShadow: "var(--mp-shadow-lg)" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
      <Icon name="logomark" size={28}/>
      <span style={{ fontSize: 11, fontWeight: 600, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mp-fg-subtle)" }}>Step 2 of 3</span>
    </div>
    <div style={{ fontSize: 28, fontWeight: 600, letterSpacing: "-0.02em", fontFamily: "var(--mp-font-display)", marginTop: 6 }}>Grant four permissions.</div>
    <div style={{ fontSize: 13, color: "var(--mp-fg-muted)", marginTop: 8, lineHeight: 1.5 }}>Audio capture is fully on-device. None of these permissions send anything off your machine.</div>
    <div style={{ marginTop: 20, display: "flex", flexDirection: "column", gap: 8 }}>
      <PermRow icon="mic" name="Microphone" why="Captures your voice via AVAudioEngine." state="granted"/>
      <PermRow icon="monitor" name="Screen Recording" why="Captures system audio via ScreenCaptureKit. We don't record video." state="granted"/>
      <PermRow icon="user" name="Accessibility" why="Reads browser tab titles to detect Meet / Teams Web." state="needed" cta="Open System Settings"/>
      <PermRow icon="alert" name="Notifications" why="Record / skip prompts and completion alerts." state="needed"/>
    </div>
    <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 24, gap: 8 }}>
      <button style={{ height: 28, padding: "0 14px", borderRadius: 6, border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontFamily: "inherit", fontSize: 13, cursor: "pointer" }}>Skip for now</button>
      <button style={{ height: 28, padding: "0 14px", borderRadius: 6, border: "none", background: "var(--mp-signal-600)", color: "#fff", fontWeight: 500, fontFamily: "inherit", fontSize: 13, cursor: "pointer" }}>Continue</button>
    </div>
  </div>
);

const PermRow = ({ icon, name, why, state, cta }) => {
  const granted = state === "granted";
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "10px 14px", border: "1px solid var(--mp-border)", borderRadius: 10, background: "var(--mp-bg-raised)" }}>
      <div style={{ width: 32, height: 32, borderRadius: 8, background: "var(--mp-bg-sunk)", display: "flex", alignItems: "center", justifyContent: "center", color: "var(--mp-fg-muted)", flexShrink: 0 }}>
        <Icon name={icon} size={16}/>
      </div>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, fontWeight: 500 }}>{name}</div>
        <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 1 }}>{why}</div>
      </div>
      {granted
        ? <span style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 12, color: "var(--mp-success-600)" }}><Icon name="check-circle" size={14}/>Granted</span>
        : <button style={{ height: 24, padding: "0 10px", borderRadius: 6, border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontSize: 12, cursor: "pointer", fontFamily: "inherit" }}>{cta || "Grant"}</button>}
    </div>
  );
};

window.OnboardingPermissions = OnboardingPermissions;
