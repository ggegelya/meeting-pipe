// PreferencesWindow - faithful recreation of the shipped Preferences.
// Maps to PreferencesWindow.swift (NSWindow shell) + Preferences/PreferencesView.swift
// (NavigationSplitView) + the per-section files (General / Recording / Prompt /
// Pipeline / Integrations / Permissions / Advanced) + PreferencesControls.swift
// (the shared SettingsGroup / SettingsRow / ... primitives).
//
// Shipped: a 780x660 window, a 200pt sidebar List of 7 panes, and a scrolling
// detail pane (620 max-width). Panes are interactive here. All spacing mirrors
// the primitives: 168pt label column, 22pt inter-group gap, 10pt card radius.

const PANES = [
  { id: "general",      label: "General",      icon: "sliders" },
  { id: "recording",    label: "Recording",    icon: "mic" },
  { id: "prompt",       label: "Prompt",       icon: "waveform" },
  { id: "pipeline",     label: "Pipeline",     icon: "cpu" },
  { id: "integrations", label: "Integrations", icon: "plug" },
  { id: "permissions",  label: "Permissions",  icon: "shield" },
  { id: "advanced",     label: "Advanced",     icon: "command" },
];

const PreferencesWindow = () => {
  const [pane, setPane] = React.useState("general");
  return (
    <div style={{
      width: 780, height: 660, background: "var(--mp-bg)", display: "flex", overflow: "hidden",
      borderRadius: 10, fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)",
      border: "1px solid var(--mp-border)", boxShadow: "var(--mp-shadow-lg)",
    }}>
      {/* sidebar */}
      <div style={{ width: 200, flexShrink: 0, background: "var(--mp-bg-sunk)", borderRight: "1px solid var(--mp-border)", padding: "10px 8px", display: "flex", flexDirection: "column", gap: 2 }}>
        {PANES.map((p) => {
          const active = pane === p.id;
          return (
            <button key={p.id} onClick={() => setPane(p.id)} style={{
              display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
              border: "none", borderRadius: 6, cursor: "pointer", fontFamily: "inherit", fontSize: 13,
              background: active ? "var(--mp-signal-600)" : "transparent",
              color: active ? "#fff" : "var(--mp-fg)",
            }}>
              <Icon name={p.icon} size={14}/> {p.label}
            </button>
          );
        })}
      </div>
      {/* detail */}
      <div style={{ flex: 1, overflow: "auto", background: "var(--mp-bg)", padding: "28px 32px" }}>
        <div style={{ maxWidth: 620, margin: "0 auto" }}>
          {pane === "general" && <GeneralPane/>}
          {pane === "recording" && <RecordingPane/>}
          {pane === "prompt" && <PromptPane/>}
          {pane === "pipeline" && <PipelinePane/>}
          {pane === "integrations" && <IntegrationsPane/>}
          {pane === "permissions" && <PermissionsPane/>}
          {pane === "advanced" && <AdvancedPane/>}
        </div>
      </div>
    </div>
  );
};

/* ===================================================================== primitives */
const SectionHeader = ({ title, caption, trailing }) => (
  <div style={{ marginBottom: 18 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <div style={{ fontSize: 22, fontWeight: 600 }}>{title}</div>
      <div style={{ flex: 1 }}/>
      {trailing}
    </div>
    {caption && <div style={{ fontSize: 13, color: "var(--mp-fg-muted)", marginTop: 4 }}>{caption}</div>}
  </div>
);

const Group = ({ label, footer, children }) => (
  <div style={{ marginBottom: 22 }}>
    {label && <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", textTransform: "uppercase", color: "var(--mp-fg-subtle)", marginBottom: 6, paddingLeft: 2 }}>{label}</div>}
    <div style={{ background: "var(--mp-bg-raised)", border: "1px solid var(--mp-border)", borderRadius: 10, overflow: "hidden" }}>
      {children}
    </div>
    {footer && <div style={{ fontSize: 12, color: "var(--mp-fg-subtle)", marginTop: 6, paddingLeft: 2, lineHeight: 1.5 }}>{footer}</div>}
  </div>
);

const Row = ({ label, sublabel, children, alignTop, first }) => (
  <div style={{
    display: "flex", alignItems: alignTop ? "flex-start" : "center", gap: 14, padding: "12px 14px",
    borderTop: first ? "none" : "1px solid var(--mp-border-faint)",
  }}>
    <div style={{ flex: "0 0 168px", paddingTop: alignTop ? 2 : 0 }}>
      <div style={{ fontSize: 13 }}>{label}</div>
      {sublabel && <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2, lineHeight: 1.4 }}>{sublabel}</div>}
    </div>
    <div style={{ flex: 1, display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>{children}</div>
  </div>
);

const ToggleRow = ({ label, sublabel, on, first }) => (
  <Row label={label} sublabel={sublabel} first={first}>
    <div style={{ flex: 1 }}/>
    <Toggle on={on}/>
  </Row>
);

const Toggle = ({ on }) => (
  <span style={{ position: "relative", width: 34, height: 20, background: on ? "var(--mp-signal-600)" : "var(--mp-ink-300)", borderRadius: 999, display: "inline-block", flexShrink: 0 }}>
    <span style={{ position: "absolute", top: 2, left: on ? 16 : 2, width: 16, height: 16, background: "#fff", borderRadius: "50%", boxShadow: "0 1px 2px rgba(0,0,0,0.2)" }}/>
  </span>
);

const Field = ({ value, placeholder, mono, width }) => (
  <input defaultValue={value} placeholder={placeholder} style={{
    flex: width ? "none" : 1, width: width || "auto", height: 24, padding: "0 8px",
    fontFamily: mono ? "var(--mp-font-mono)" : "inherit", fontSize: mono ? 12 : 13,
    border: "1px solid var(--mp-border-strong)", borderRadius: 6,
    background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
  }}/>
);

const SmallButton = ({ children }) => (
  <button style={{ height: 24, padding: "0 10px", fontSize: 12, fontFamily: "inherit", border: "1px solid var(--mp-border-strong)", borderRadius: 6, background: "var(--mp-bg-raised)", color: "var(--mp-fg)", cursor: "pointer", whiteSpace: "nowrap" }}>{children}</button>
);

const IconButton = ({ name, title }) => (
  <button title={title} style={{ width: 24, height: 24, border: "1px solid var(--mp-border-strong)", borderRadius: 6, background: "var(--mp-bg-raised)", color: "var(--mp-fg-muted)", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}><Icon name={name} size={13}/></button>
);

const MenuPicker = ({ value, width }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 24, padding: "0 8px", borderRadius: 6, border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontSize: 13, cursor: "pointer", width: width || "auto", justifyContent: "space-between" }}>
    {value}<Icon name="chevron-down" size={10}/>
  </span>
);

const Segmented = ({ options, selected }) => (
  <span style={{ display: "inline-flex", padding: 2, borderRadius: 6, background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
    {options.map((o, i) => (
      <span key={o} style={{ fontSize: 12, padding: "3px 12px", borderRadius: 4, cursor: "pointer", background: i === selected ? "var(--mp-bg-raised)" : "transparent", color: i === selected ? "var(--mp-fg)" : "var(--mp-fg-muted)", boxShadow: i === selected ? "var(--mp-shadow-xs)" : "none" }}>{o}</span>
    ))}
  </span>
);

const Slider = ({ value, max, format, valueWidth }) => (
  <>
    <div style={{ flex: 1, position: "relative", height: 18, display: "flex", alignItems: "center" }}>
      <div style={{ flex: 1, height: 4, background: "var(--mp-ink-200)", borderRadius: 2, position: "relative" }}>
        <div style={{ width: `${(value / max) * 100}%`, height: "100%", background: "var(--mp-signal-600)", borderRadius: 2 }}/>
        <div style={{ position: "absolute", left: `calc(${(value / max) * 100}% - 8px)`, top: -6, width: 16, height: 16, background: "#fff", borderRadius: "50%", boxShadow: "0 1px 3px rgba(0,0,0,0.2)", border: "1px solid var(--mp-border-strong)" }}/>
      </div>
    </div>
    <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)", minWidth: valueWidth || 56, textAlign: "right" }}>{format}</span>
  </>
);

const Disclosure = ({ label, sublabel, children, first }) => {
  const [open, setOpen] = React.useState(false);
  return (
    <div style={{ borderTop: first ? "none" : "1px solid var(--mp-border-faint)" }}>
      <button onClick={() => setOpen(!open)} style={{ width: "100%", display: "flex", alignItems: "center", gap: 14, padding: "12px 14px", border: "none", background: "transparent", cursor: "pointer", fontFamily: "inherit", textAlign: "left" }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 13, color: "var(--mp-fg)" }}>{label}</div>
          {sublabel && <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2 }}>{sublabel}</div>}
        </div>
        <span style={{ color: "var(--mp-fg-subtle)", display: "flex", transform: open ? "rotate(90deg)" : "none", transition: "transform 0.18s" }}><Icon name="chevron-right" size={11}/></span>
      </button>
      {open && <div>{children}</div>}
    </div>
  );
};

const SecretField = ({ placeholder }) => {
  const [show, setShow] = React.useState(false);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, flex: 1 }}>
      <input type={show ? "text" : "password"} defaultValue={show ? "" : ""} placeholder={placeholder} style={{ flex: 1, height: 24, padding: "0 8px", fontFamily: "var(--mp-font-mono)", fontSize: 12, border: "1px solid var(--mp-border-strong)", borderRadius: 6, background: "var(--mp-bg-raised)", color: "var(--mp-fg)" }}/>
      <button onClick={() => setShow(!show)} style={{ width: 30, height: 22, border: "1px solid var(--mp-border)", borderRadius: 5, background: "var(--mp-bg-sunk)", color: show ? "var(--mp-signal-600)" : "var(--mp-fg-muted)", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center" }}><Icon name={show ? "eye" : "eye-off"} size={12}/></button>
    </div>
  );
};

const StatusPill = ({ tone, icon, text }) => {
  const c = { granted: "var(--mp-success-600)", needed: "var(--mp-warning-600)", denied: "var(--mp-danger-600)", neutral: "var(--mp-fg-subtle)" }[tone];
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 8px", borderRadius: 999, fontSize: 11, fontWeight: 500, color: c, background: "color-mix(in srgb, transparent 85%, currentColor)" }}>
      <Icon name={icon} size={10}/> {text}
    </span>
  );
};

const Tag = ({ children }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 4px 0 8px", borderRadius: 4, background: "var(--mp-bg-sunk)", border: "1px solid var(--mp-border)", fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)" }}>
    {children}<span style={{ color: "var(--mp-fg-subtle)", display: "flex", cursor: "pointer", padding: 2 }}><Icon name="x" size={9}/></span>
  </span>
);

const FullRow = ({ children, first }) => (
  <div style={{ padding: "10px 14px", borderTop: first ? "none" : "1px solid var(--mp-border-faint)" }}>{children}</div>
);

const HotkeyField = ({ value }) => (
  <span style={{ display: "inline-flex", alignItems: "center", height: 24, width: 200, padding: "0 10px", borderRadius: 5, border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg)", cursor: "pointer" }}>{value}</span>
);

/* ===================================================================== panes */
const GeneralPane = () => (
  <div>
    <SectionHeader title="General" caption="Global hotkeys, appearance, and startup behaviour."/>
    <Group label="Appearance">
      <Row first label="Theme" sublabel="Override the system appearance. SwiftUI windows and the recording HUD follow this choice.">
        <Segmented options={["Light", "System", "Dark"]} selected={1}/>
      </Row>
    </Group>
    <Group label="Startup" footer="Registers MeetingPipe with macOS via SMAppService. The relaunch-after-quit behaviour takes effect after the launch agent is reinstalled (re-run scripts/install.sh).">
      <ToggleRow first on label="Launch at login" sublabel="MeetingPipe will start automatically when you log in."/>
      <ToggleRow on={false} label="Relaunch after quitting" sublabel="On: Quit restarts MeetingPipe in the menu bar. Off: Quit fully closes it. Either way a crash still auto-recovers."/>
    </Group>
    <Group label="Sound">
      <ToggleRow first on={false} label="Play a tone when a meeting finishes" sublabel="A short system tone when the summary is ready. Off by default, and never during a call."/>
    </Group>
    <Group label="Hotkeys" footer="Click a field, then press the chord you want to bind (one or more of ⌃⌥⇧⌘ plus a letter). The toggle hotkey starts/stops; the force-stop hotkey only stops, so panic-pressing can never accidentally start a recording. Restart MeetingPipe after changing.">
      <Row first label="Manual toggle" sublabel="Start or stop a recording from anywhere."><HotkeyField value="⌃⌥M"/></Row>
      <Row label="Force stop" sublabel="Stop immediately, even if detection still thinks a meeting is live."><HotkeyField value="⌃⌥⇧M"/></Row>
    </Group>
  </div>
);

const RecordingPane = () => (
  <div>
    <SectionHeader title="Recording" caption="How audio is captured to disk, and which apps record automatically."/>
    <Group label="Audio">
      <Row first alignTop label="Output directory">
        <Field value="~/Documents/Meetings/raw" mono/>
        <SmallButton>Choose…</SmallButton>
        <IconButton name="external" title="Reveal in Finder"/>
      </Row>
      <Row label="Sample rate" sublabel="16 kHz matches Whisper. Higher rates are downsampled.">
        <MenuPicker value="16 kHz · recommended"/>
      </Row>
    </Group>
    <Group label="Microphone" footer="Voice processing takes effect on the next recording. Mute pausing applies to every meeting.">
      <ToggleRow first on label="Pause mic when muted" sublabel="Pauses mic capture while you're muted in Teams / Zoom / Slack / Webex. Uses the locale catalogue (en, uk, de, es, fr, ja, pt, ru)."/>
      <ToggleRow on={false} label="Voice processing" sublabel="Apple's noise-suppression + AGC. Drops your mic gain system-wide while recording, so other apps hear you quietly. Off by default; flip on only for solo voice memos."/>
    </Group>
    <Group label="Detection" footer="Debounce smooths out brief mic gaps. A higher start debounce avoids recording phantom audio; a higher end debounce avoids cutting off pauses.">
      <Row first label="Start debounce"><Slider value={5} max={30} format="5 s"/></Row>
      <Row label="End debounce"><Slider value={8} max={30} format="8 s"/></Row>
    </Group>
    <Group label="Auto-record allowlist" footer="When the daemon detects audio from these apps, recording starts without showing the prompt.">
      <FullRow first>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <Tag>us.zoom.xos</Tag>
          <Tag>com.microsoft.teams2</Tag>
        </div>
      </FullRow>
      <FullRow>
        <div style={{ display: "flex", gap: 8 }}>
          <Field placeholder="us.zoom.xos" mono/>
          <SmallButton>Add</SmallButton>
        </div>
      </FullRow>
    </Group>
  </div>
);

const PromptPane = () => (
  <div>
    <SectionHeader title="Prompt" caption="What happens the moment a meeting is detected."/>
    <Group label="When a meeting is detected" footer="The floating prompt panel asks whether to record. If you don't respond, the default action above fires when the timeout elapses.">
      <Row first label="Prompt timeout"><Slider value={30} max={120} format="30 s"/></Row>
      <Row label="Default action" sublabel="Suppress the call (no recording) when the prompt times out.">
        <MenuPicker value="Skip"/>
      </Row>
      <Row label="Re-prompt cooldown" sublabel="After a recording or skip, suppress new prompts for the same app for this many seconds. Catches post-call mic flickers from Teams/Zoom.">
        <Slider value={60} max={300} format="60 s"/>
      </Row>
    </Group>
    <Group label="Stop conditions" footer="Gated on voice activity, not raw level, so a brief pause does not trigger it. A 'still meeting?' nudge fires partway through; a quiet-but-live native call is kept and re-nudged rather than stopped.">
      <Row first label="Mic-only silence backstop" sublabel="Auto-stop if your mic is silent AND no system audio plays for this many seconds. Catches the 'everyone else left and I forgot to stop' case.">
        <Slider value={480} max={1800} format="8 min"/>
      </Row>
    </Group>
  </div>
);

const PipelinePane = () => (
  <div>
    <SectionHeader title="Pipeline" caption="What runs after the recording stops: summarization and languages. Transcription is in-process (FluidAudio)."/>
    <Group label="Summarization" footer="Tries Anthropic first; falls back to local if the API fails or the key is missing.">
      <Row first label="Backend"><MenuPicker value="Auto"/></Row>
      <Disclosure label="Configure local model" sublabel="Model preset, endpoint, active model, and preload.">
        <Row first label="Local model" sublabel="~9 GB on disk, ~30s per meeting. Best quality for the size.">
          <MenuPicker value="Recommended (Qwen 14B-4bit)"/>
        </Row>
        <Row label="Endpoint URL" sublabel="Local mlx_lm.server target."><Field value="http://127.0.0.1:8765" mono/></Row>
        <Row label="Active model" sublabel="Resident model on the local server."><span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)" }}>mlx-community/Qwen2.5-14B-Instruct-4bit</span></Row>
        <ToggleRow on={false} label="Preload at launch" sublabel="Warm the model when the app starts so the first summary skips the cold-start. Holds the model in RAM while idle."/>
      </Disclosure>
    </Group>
    <Group label="Summarization prompt" footer="Read-only preview of the system prompt sent to the summarizer, with your configured team context and summary language applied.">
      <Row first alignTop label="System prompt"><SmallButton>View prompt</SmallButton></Row>
    </Group>
    <Group label="Languages">
      <Row first label="Transcription" sublabel="Whisper. Auto-detect chooses per-meeting."><MenuPicker value="Auto-detect"/></Row>
      <Row label="Summary" sublabel="Output language for the Notion summary."><MenuPicker value="Match transcript"/></Row>
    </Group>
    <Group label="Long meetings" footer="When the transcript exceeds this size, the pipeline writes a paste-into-Claude bundle instead of calling the Anthropic API. 0 disables the guard. ~80,000 chars ≈ 1 hour of speech.">
      <Row first label="Chunking threshold"><Slider value={80000} max={300000} format="80.0k chars" valueWidth={100}/></Row>
    </Group>
  </div>
);

const IntegrationsPane = () => (
  <div>
    <SectionHeader title="Integrations" caption="Credentials for outbound services. Stored in ~/.config/meeting-pipe/secrets.env (mode 0600)." trailing={<SmallButton><span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}><Icon name="stethoscope" size={12}/> Run doctor…</span></SmallButton>}/>
    <Group label="Anthropic" footer="Used to summarize transcripts. Get a key at console.anthropic.com. Local MLX backend doesn't need this.">
      <Row first alignTop label="API key"><SecretField placeholder="sk-ant-…"/></Row>
      <Row label="Status"><StatusPill tone="granted" icon="check-circle" text="Configured"/><div style={{ flex: 1 }}/></Row>
    </Group>
    <Group label="Notion" footer="Create the integration at notion.so/profile/integrations, share your Meetings database with it, and paste the database ID here.">
      <Row first alignTop label="Integration token"><SecretField placeholder="ntn_…"/></Row>
      <Row label="Database ID"><Field placeholder="32-char hex from your database URL" mono/></Row>
      <Row label="Status"><StatusPill tone="needed" icon="alert-triangle" text="Not configured"/><div style={{ flex: 1 }}/></Row>
    </Group>
  </div>
);

const PERMISSIONS = [
  { name: "Microphone", icon: "mic", rationale: "Captures your voice via AVAudioEngine. Audio stays on this Mac.", tone: "granted", text: "Granted", action: "Open Settings" },
  { name: "Screen Recording", icon: "monitor", rationale: "Captures system audio via ScreenCaptureKit. No video is recorded.", tone: "granted", text: "Granted", action: "Open Settings" },
  { name: "Accessibility", icon: "user", rationale: "Reads browser tab titles to detect Meet and Teams Web sessions.", tone: "needed", text: "Needed", action: "Request" },
  { name: "Notifications", icon: "bell", rationale: "Record / skip prompts and 'meeting published' alerts.", tone: "granted", text: "Granted", action: "Open Settings" },
];

const PermissionsPane = () => (
  <div>
    <SectionHeader title="Permissions" caption="The four TCC permissions the daemon needs. None of these send anything off your machine." trailing={<SmallButton><span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}><Icon name="refresh" size={12}/> Re-check</span></SmallButton>}/>
    <Group>
      {PERMISSIONS.map((p, i) => (
        <div key={p.name} style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 14px", borderTop: i === 0 ? "none" : "1px solid var(--mp-border-faint)" }}>
          <div style={{ width: 32, height: 32, borderRadius: 8, background: "var(--mp-bg-sunk)", display: "flex", alignItems: "center", justifyContent: "center", color: "var(--mp-fg-muted)", flexShrink: 0 }}><Icon name={p.icon} size={16}/></div>
          <div style={{ flex: 1 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ fontSize: 13, fontWeight: 500 }}>{p.name}</span>
              <StatusPill tone={p.tone} icon={p.tone === "granted" ? "check-circle" : "alert-triangle"} text={p.text}/>
            </div>
            <div style={{ fontSize: 12, color: "var(--mp-fg-subtle)", marginTop: 2 }}>{p.rationale}</div>
          </div>
          <SmallButton>{p.action}</SmallButton>
        </div>
      ))}
    </Group>
    <div style={{ fontSize: 12, color: "var(--mp-fg-subtle)", margin: "-12px 0 18px", paddingLeft: 2, lineHeight: 1.5 }}>
      Granting Accessibility from System Settings requires a daemon restart for the change to take effect - macOS caches the trust verdict per-process at launch.
    </div>
    <Group label="Regulated mode" footer="Use for client / regulated meetings. The pipeline writes summaries to disk only - no transcript or summary is uploaded to Notion.">
      <ToggleRow first on={false} label="Skip Notion publish" sublabel="Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it)."/>
    </Group>
    <div style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "12px 14px", borderRadius: 10, background: "color-mix(in srgb, transparent 90%, var(--mp-signal-600))", border: "1px solid color-mix(in srgb, transparent 82%, var(--mp-signal-600))" }}>
      <span style={{ color: "var(--mp-signal-600)", display: "flex", flexShrink: 0, marginTop: 1 }}><Icon name="shield" size={16}/></span>
      <span style={{ fontSize: 12, lineHeight: 1.5, color: "var(--mp-fg-muted)" }}>Audio capture is fully on-device. The pipeline only reaches the network when sending the transcript to Anthropic for summarization, and when publishing to Notion.</span>
    </div>
  </div>
);

const AdvancedPane = () => (
  <div>
    <SectionHeader title="Advanced" caption="Plumbing for power users. Most people never come here."/>
    <Group label="Configuration">
      <Row first label="Config file" sublabel="~/.config/meeting-pipe/config.toml">
        <SmallButton>Open in editor</SmallButton>
        <SmallButton>Reveal in Finder</SmallButton>
      </Row>
      <Row label="Logs folder" sublabel="Rotated daily. Used by mp doctor and bug reports.">
        <SmallButton>Open logs</SmallButton>
      </Row>
    </Group>
    <Group label="Diagnostics" footer="Takes effect after restarting MeetingPipe - the env var is set at daemon launch and inherited by every subprocess spawned afterwards.">
      <ToggleRow first on={false} label="Verbose logging" sublabel="Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses."/>
    </Group>
    <div style={{ fontSize: 11, color: "var(--mp-fg-faint)", textAlign: "center", marginTop: 4, lineHeight: 1.5 }}>
      MeetingPipe - config lives in ~/.config/meeting-pipe/. Workflows live in ~/.config/meeting-pipe/workflows/. Both are plain TOML, safe to edit by hand if you know what you're doing.
    </div>
  </div>
);

window.PreferencesWindow = PreferencesWindow;
