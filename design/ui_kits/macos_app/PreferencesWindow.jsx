// PreferencesWindow — recreates PreferencesWindow.swift's TabView.
// Three tabs: Recording / Detection / Modes.

const PreferencesWindow = () => {
  const [tab, setTab] = React.useState("recording");
  return (
    <div style={{
      width: 480, height: 560,
      background: "var(--mp-bg)",
      borderRadius: 10, overflow: "hidden",
      display: "flex", flexDirection: "column",
      fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)",
      boxShadow: "var(--mp-shadow-lg)",
    }}>
      <PrefsTabBar tab={tab} setTab={setTab}/>
      <div style={{ flex: 1, overflow: "auto", padding: 20, background: "var(--mp-bg-sunk)" }}>
        {tab === "recording" && <RecordingTab/>}
        {tab === "detection" && <DetectionTab/>}
        {tab === "modes" && <ModesTab/>}
      </div>
    </div>
  );
};

const PrefsTabBar = ({ tab, setTab }) => (
  <div style={{
    display: "flex", justifyContent: "center", gap: 4,
    padding: "10px 20px 12px",
    background: "var(--mp-bg)",
    borderBottom: "1px solid var(--mp-border)",
  }}>
    <PrefsTab id="recording" tab={tab} setTab={setTab} icon="mic" label="Recording"/>
    <PrefsTab id="detection" tab={tab} setTab={setTab} icon="waveform" label="Detection"/>
    <PrefsTab id="modes" tab={tab} setTab={setTab} icon="lock" label="Modes"/>
  </div>
);

const PrefsTab = ({ id, tab, setTab, icon, label }) => {
  const active = tab === id;
  return (
    <button onClick={() => setTab(id)} style={{
      display: "flex", flexDirection: "column", alignItems: "center", gap: 3,
      padding: "6px 14px", borderRadius: 6,
      background: active ? "var(--mp-ink-100)" : "transparent",
      color: active ? "var(--mp-fg)" : "var(--mp-fg-muted)",
      border: "none", cursor: "pointer", fontFamily: "inherit",
    }}>
      <Icon name={icon} size={20}/>
      <span style={{ fontSize: 11 }}>{label}</span>
    </button>
  );
};

const PrefsSection = ({ title, children }) => (
  <div style={{ marginBottom: 18 }}>
    {title && <div style={{ fontSize: 11, fontWeight: 600, color: "var(--mp-fg-subtle)", textTransform: "uppercase", letterSpacing: ".08em", marginBottom: 6, paddingLeft: 12 }}>{title}</div>}
    <div style={{ background: "var(--mp-bg-raised)", border: "1px solid var(--mp-border)", borderRadius: 10, overflow: "hidden" }}>
      {children}
    </div>
  </div>
);

const PrefsRow = ({ label, children, hint }) => (
  <div style={{ borderBottom: "1px solid var(--mp-border-faint)" }}>
    <div style={{ display: "flex", alignItems: "center", padding: "10px 12px", gap: 12 }}>
      <div style={{ flex: "0 0 140px", fontSize: 13, color: "var(--mp-fg-muted)" }}>{label}</div>
      <div style={{ flex: 1, display: "flex", alignItems: "center", gap: 8 }}>{children}</div>
    </div>
    {hint && <div style={{ padding: "0 12px 10px 152px", fontSize: 11, color: "var(--mp-fg-subtle)", lineHeight: 1.5 }}>{hint}</div>}
  </div>
);

const TextField = ({ value, mono }) => (
  <input defaultValue={value} style={{
    flex: 1, height: 24, padding: "0 8px",
    fontFamily: mono ? "var(--mp-font-mono)" : "inherit",
    fontSize: mono ? 12 : 13,
    border: "1px solid var(--mp-border-strong)", borderRadius: 6,
    background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
  }}/>
);

const SmallButton = ({ children }) => (
  <button style={{
    height: 24, padding: "0 10px", fontSize: 12, fontFamily: "inherit",
    border: "1px solid var(--mp-border-strong)", borderRadius: 6,
    background: "var(--mp-bg-raised)", color: "var(--mp-fg)", cursor: "pointer",
  }}>{children}</button>
);

const Toggle = ({ on }) => (
  <span style={{
    position: "relative", width: 34, height: 20,
    background: on ? "var(--mp-signal-600)" : "var(--mp-ink-300)",
    borderRadius: 999, transition: "background var(--mp-dur-base)", display: "inline-block",
  }}>
    <span style={{
      position: "absolute", top: 2, left: on ? 16 : 2, width: 16, height: 16,
      background: "#fff", borderRadius: "50%",
      boxShadow: "0 1px 2px rgba(0,0,0,0.2)",
      transition: "left var(--mp-dur-base)",
    }}/>
  </span>
);

const RecordingTab = () => (
  <div>
    <PrefsSection>
      <PrefsRow label="Output directory">
        <TextField value="~/Documents/Meetings/raw" mono/>
        <SmallButton>Choose…</SmallButton>
      </PrefsRow>
      <PrefsRow label="Sample rate">
        <select defaultValue="16" style={{ height: 24, padding: "0 8px", border: "1px solid var(--mp-border-strong)", borderRadius: 6, background: "var(--mp-bg-raised)", fontFamily: "inherit", fontSize: 13 }}>
          <option value="16">16 kHz (recommended)</option>
          <option value="24">24 kHz</option>
          <option value="48">48 kHz</option>
        </select>
      </PrefsRow>
    </PrefsSection>
    <PrefsSection title="Auto-record without prompt">
      <div style={{ padding: "10px 12px", display: "flex", justifyContent: "space-between", alignItems: "center", borderBottom: "1px solid var(--mp-border-faint)" }}>
        <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 12 }}>us.zoom.xos</span>
        <span style={{ color: "var(--mp-danger-600)", cursor: "pointer", fontSize: 18 }}>−</span>
      </div>
      <div style={{ padding: "10px 12px", display: "flex", gap: 8 }}>
        <TextField value="" mono/>
        <SmallButton>Add</SmallButton>
      </div>
    </PrefsSection>
  </div>
);

const DetectionTab = () => (
  <div>
    <PrefsSection title="Debounce">
      <PrefsRow label="Start (sec)"><Slider value={5} max={30}/><Mono>5s</Mono></PrefsRow>
      <PrefsRow label="End (sec)"><Slider value={5} max={30}/><Mono>5s</Mono></PrefsRow>
    </PrefsSection>
    <PrefsSection title="Hotkey">
      <PrefsRow label="Manual record" hint="Format: 'ctrl+option+m', 'cmd+shift+r'. Restart MeetingPipe after changing.">
        <TextField value="ctrl+option+m" mono/>
      </PrefsRow>
    </PrefsSection>
    <PrefsSection title="Prompt">
      <PrefsRow label="Timeout (sec)"><Slider value={30} max={120}/><Mono>30s</Mono></PrefsRow>
    </PrefsSection>
  </div>
);

const Slider = ({ value, max }) => (
  <div style={{ flex: 1, position: "relative", height: 18, display: "flex", alignItems: "center" }}>
    <div style={{ flex: 1, height: 4, background: "var(--mp-ink-200)", borderRadius: 2, position: "relative" }}>
      <div style={{ width: `${(value/max)*100}%`, height: "100%", background: "var(--mp-signal-600)", borderRadius: 2 }}/>
      <div style={{ position: "absolute", left: `calc(${(value/max)*100}% - 8px)`, top: -6, width: 16, height: 16, background: "#fff", borderRadius: "50%", boxShadow: "0 1px 3px rgba(0,0,0,0.2)", border: "1px solid var(--mp-border-strong)" }}/>
    </div>
  </div>
);

const Mono = ({ children }) => <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)", minWidth: 36, textAlign: "right" }}>{children}</span>;

const ModesTab = () => (
  <div>
    <PrefsSection title="Regulated mode">
      <PrefsRow label="Skip Notion publish" hint="When enabled, the pipeline writes summaries to disk only — no transcript or summary is uploaded to Notion. Use for client / regulated meetings.">
        <Toggle on={false}/>
        <span style={{ fontSize: 12, color: "var(--mp-fg-muted)" }}>Off</span>
      </PrefsRow>
    </PrefsSection>
    <PrefsSection title="Tools">
      <div style={{ padding: "8px 12px", display: "flex", flexDirection: "column", gap: 6 }}>
        <SmallButton>Open config in editor</SmallButton>
        <SmallButton>Reveal config in Finder</SmallButton>
      </div>
    </PrefsSection>
  </div>
);

window.PreferencesWindow = PreferencesWindow;
