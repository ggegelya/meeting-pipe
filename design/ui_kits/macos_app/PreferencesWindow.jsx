// PreferencesWindow - faithful recreation of the shipped Preferences.
// Maps to PreferencesWindow.swift (NSWindow shell) + Preferences/PreferencesView.swift
// (NavigationSplitView) + the per-section files (General / Recording / Prompt /
// Pipeline / Integrations / Permissions / Advanced) + PreferencesControls.swift
// (the shared SettingsGroup / SettingsRow / ... primitives).
//
// Shipped: a 780x660 window, a 200pt sidebar List of 7 panes, and a scrolling
// detail pane (620 max-width). Panes are interactive here.
//
// Row model (the layout fix): a settings row is [info grows · control hugs right].
// The label and its description take the full available width and wrap to one or two
// lines instead of being crammed into a fixed 168pt label column; compact controls
// (toggle, segmented, menu, status) sit on the right. Wide or descriptive controls
// (sliders, file paths, API keys) use the stacked variant PWStackRow: label and
// description on top, full-width control below. This mirrors the Permissions list
// and macOS System Settings, and removes the ragged-sublabel / empty-gap look.
//
// All top-level names are PW-prefixed: the kit shares one global lexical scope, so
// every const must be unique across the whole kit (see SummaryLibrary's SL* convention).

const PW_PANES = [
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
      borderRadius: "var(--mp-radius-lg)", fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)",
      border: "1px solid var(--mp-border)", boxShadow: "var(--mp-shadow-lg)",
    }}>
      {/* sidebar */}
      <div style={{ width: 200, flexShrink: 0, background: "var(--mp-bg-sunk)", borderRight: "1px solid var(--mp-border)", padding: "10px 8px", display: "flex", flexDirection: "column", gap: 2 }}>
        {PW_PANES.map((p) => {
          const active = pane === p.id;
          return (
            <button key={p.id} onClick={() => setPane(p.id)} style={{
              display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
              border: "none", borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontFamily: "inherit", fontSize: 13,
              background: active ? "var(--mp-signal-fill)" : "transparent",
              color: active ? "var(--mp-fg-on-signal)" : "var(--mp-fg)",
            }}>
              <Icon name={p.icon} size={14}/> {p.label}
            </button>
          );
        })}
      </div>
      {/* detail */}
      <div style={{ flex: 1, overflow: "auto", background: "var(--mp-bg)", padding: "28px 32px" }}>
        <div style={{ maxWidth: 620, margin: "0 auto" }}>
          {pane === "general" && <PWGeneralPane/>}
          {pane === "recording" && <PWRecordingPane/>}
          {pane === "prompt" && <PWPromptPane/>}
          {pane === "pipeline" && <PWPipelinePane/>}
          {pane === "integrations" && <PWIntegrationsPane/>}
          {pane === "permissions" && <PWPermissionsPane/>}
          {pane === "advanced" && <PWAdvancedPane/>}
        </div>
      </div>
    </div>
  );
};

/* ===================================================================== primitives */
const PWSectionHeader = ({ title, caption, trailing }) => (
  <div style={{ marginBottom: 18 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <div style={{ fontSize: 17, fontWeight: 600 }}>{title}</div>
      <div style={{ flex: 1 }}/>
      {trailing}
    </div>
    {caption && <div style={{ fontSize: 13, color: "var(--mp-fg-muted)", marginTop: 4, lineHeight: 1.45 }}>{caption}</div>}
  </div>
);

const PWGroup = ({ label, footer, children }) => (
  <div style={{ marginBottom: 22 }}>
    {label && <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase", color: "var(--mp-fg-subtle)", marginBottom: 6, paddingLeft: 2 }}>{label}</div>}
    <div style={{ background: "var(--mp-bg-raised)", border: "1px solid var(--mp-border)", borderRadius: "var(--mp-radius-md)", overflow: "hidden" }}>
      {children}
    </div>
    {footer && <div style={{ fontSize: 12, color: "var(--mp-fg-subtle)", marginTop: 6, paddingLeft: 2, lineHeight: 1.5 }}>{footer}</div>}
  </div>
);

// Inline row: info (label + sublabel) grows and wraps across the full width; the
// control hugs the right at its natural size. For compact controls only.
const PWRow = ({ label, sublabel, children, alignTop, first }) => (
  <div style={{
    display: "flex", alignItems: alignTop ? "flex-start" : "center", gap: 16, padding: "11px 14px",
    borderTop: first ? "none" : "1px solid var(--mp-border-faint)",
  }}>
    <div style={{ flex: "1 1 auto", minWidth: 0, paddingTop: alignTop ? 1 : 0 }}>
      <div style={{ fontSize: 13 }}>{label}</div>
      {sublabel && <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2, lineHeight: 1.4 }}>{sublabel}</div>}
    </div>
    <div style={{ flexShrink: 0, display: "flex", alignItems: "center", gap: 8 }}>{children}</div>
  </div>
);

// Stacked row: label + sublabel on top, full-width control below. For sliders, file
// paths, endpoints, API keys - anything that wants room or carries a long description.
const PWStackRow = ({ label, sublabel, children, first }) => (
  <div style={{ padding: "11px 14px", borderTop: first ? "none" : "1px solid var(--mp-border-faint)" }}>
    <div style={{ fontSize: 13 }}>{label}</div>
    {sublabel && <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2, lineHeight: 1.4 }}>{sublabel}</div>}
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8 }}>{children}</div>
  </div>
);

const PWToggleRow = ({ label, sublabel, on, first }) => (
  <PWRow label={label} sublabel={sublabel} first={first}>
    <PWToggle on={on}/>
  </PWRow>
);

const PWToggle = ({ on }) => (
  <span style={{ position: "relative", width: 34, height: 20, background: on ? "var(--mp-signal-600)" : "var(--mp-ink-300)", borderRadius: 999, display: "inline-block", flexShrink: 0 }}>
    <span style={{ position: "absolute", top: 2, left: on ? 16 : 2, width: 16, height: 16, background: "#fff", borderRadius: "50%", boxShadow: "0 1px 2px rgba(0,0,0,0.2)" }}/>
  </span>
);

const PWField = ({ value, placeholder, mono, width }) => (
  <input defaultValue={value} placeholder={placeholder} style={{
    flex: width ? "0 0 auto" : 1, width: width || "auto", minWidth: 0, height: 24, padding: "0 8px",
    fontFamily: mono ? "var(--mp-font-mono)" : "inherit", fontSize: mono ? 12 : 13,
    border: "1px solid var(--mp-border-strong)", borderRadius: "var(--mp-radius-sm)",
    background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
  }}/>
);

const PWSmallButton = ({ children }) => (
  <button className="mp-pressable" style={{ height: 24, padding: "0 12px", fontSize: 12, fontFamily: "inherit", border: "1px solid var(--mp-border-strong)", borderRadius: "var(--mp-radius-full)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)", cursor: "pointer", whiteSpace: "nowrap", flexShrink: 0 }}>{children}</button>
);

const PWIconButton = ({ name, title }) => (
  <button title={title} className="mp-pressable" style={{ width: 24, height: 24, border: "1px solid var(--mp-border-strong)", borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-raised)", color: "var(--mp-fg-muted)", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}><Icon name={name} size={13}/></button>
);

const PWMenuPicker = ({ value, width }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 24, padding: "0 8px", borderRadius: "var(--mp-radius-sm)", border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontSize: 13, cursor: "pointer", width: width || "auto", justifyContent: "space-between", whiteSpace: "nowrap" }}>
    {value}<Icon name="chevron-down" size={10}/>
  </span>
);

const PWSegmented = ({ options, selected }) => (
  <span style={{ display: "inline-flex", padding: 2, borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
    {options.map((o, i) => (
      <span key={o} style={{ fontSize: 12, padding: "3px 12px", borderRadius: "var(--mp-radius-xs)", cursor: "pointer", background: i === selected ? "var(--mp-bg-raised)" : "transparent", color: i === selected ? "var(--mp-fg)" : "var(--mp-fg-muted)", boxShadow: i === selected ? "var(--mp-shadow-xs)" : "none" }}>{o}</span>
    ))}
  </span>
);

// Renders inside a stacked row; the track fills the full width and the value sits right.
const PWSlider = ({ value, max, format, valueWidth }) => (
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

const PWDisclosure = ({ label, sublabel, children, first }) => {
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

const PWSecretField = ({ placeholder }) => {
  const [show, setShow] = React.useState(false);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, flex: 1, minWidth: 0 }}>
      <input type={show ? "text" : "password"} placeholder={placeholder} style={{ flex: 1, minWidth: 0, height: 24, padding: "0 8px", fontFamily: "var(--mp-font-mono)", fontSize: 12, border: "1px solid var(--mp-border-strong)", borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)" }}/>
      <button onClick={() => setShow(!show)} style={{ width: 30, height: 22, border: "1px solid var(--mp-border)", borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-sunk)", color: show ? "var(--mp-signal-600)" : "var(--mp-fg-muted)", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}><Icon name={show ? "eye" : "eye-off"} size={12}/></button>
    </div>
  );
};

const PWStatusPill = ({ tone, icon, text }) => {
  const c = { granted: "var(--mp-success-600)", needed: "var(--mp-warning-600)", denied: "var(--mp-danger-600)", neutral: "var(--mp-fg-subtle)" }[tone];
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 8px", borderRadius: 999, fontSize: 11, fontWeight: 500, color: c, background: "color-mix(in srgb, transparent 85%, currentColor)", border: "0.5px solid color-mix(in srgb, transparent 72%, currentColor)" }}>
      <Icon name={icon} size={10}/> {text}
    </span>
  );
};

const PWTag = ({ children }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 4px 0 8px", borderRadius: 4, background: "var(--mp-bg-sunk)", border: "1px solid var(--mp-border)", fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)" }}>
    {children}<span style={{ color: "var(--mp-fg-subtle)", display: "flex", cursor: "pointer", padding: 2 }}><Icon name="x" size={9}/></span>
  </span>
);

const PWFullRow = ({ children, first }) => (
  <div style={{ padding: "10px 14px", borderTop: first ? "none" : "1px solid var(--mp-border-faint)" }}>{children}</div>
);

const PWHotkeyField = ({ value }) => (
  <span style={{ display: "inline-flex", alignItems: "center", height: 24, width: 200, padding: "0 10px", borderRadius: "var(--mp-radius-sm)", border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg)", cursor: "pointer" }}>{value}</span>
);

/* ===================================================================== panes */
const PWGeneralPane = () => (
  <div>
    <PWSectionHeader title="General" caption="Global hotkeys, appearance, and startup behaviour."/>
    <PWGroup label="Appearance">
      <PWRow first label="Theme" sublabel="Override the system appearance. SwiftUI windows and the recording HUD follow this choice.">
        <PWSegmented options={["Light", "System", "Dark"]} selected={1}/>
      </PWRow>
    </PWGroup>
    <PWGroup label="Startup" footer="Registers MeetingPipe with macOS via SMAppService. The relaunch-after-quit behaviour takes effect after the launch agent is reinstalled (re-run scripts/install.sh).">
      <PWToggleRow first on label="Launch at login" sublabel="MeetingPipe will start automatically when you log in."/>
      <PWToggleRow on={false} label="Relaunch after quitting" sublabel="On: Quit restarts MeetingPipe in the menu bar. Off: Quit fully closes it. Either way a crash still auto-recovers."/>
    </PWGroup>
    <PWGroup label="Sound">
      <PWToggleRow first on={false} label="Play a tone when a meeting finishes" sublabel="A short system tone when the summary is ready. Off by default, and never during a call."/>
    </PWGroup>
    <PWGroup label="Hotkeys" footer="Click a field, then press the chord you want to bind (one or more of ⌃⌥⇧⌘ plus a letter). The toggle hotkey starts/stops; the force-stop hotkey only stops, so panic-pressing can never accidentally start a recording. Restart MeetingPipe after changing.">
      <PWRow first label="Manual toggle" sublabel="Start or stop a recording from anywhere."><PWHotkeyField value="⌃⌥M"/></PWRow>
      <PWRow label="Force stop" sublabel="Stop immediately, even if detection still thinks a meeting is live."><PWHotkeyField value="⌃⌥⇧M"/></PWRow>
    </PWGroup>
  </div>
);

const PWRecordingPane = () => (
  <div>
    <PWSectionHeader title="Recording" caption="How audio is captured to disk, and which apps record automatically."/>
    <PWGroup label="Audio" footer="Recordings are stereo 16 kHz WAV: your mic on the left channel, system audio on the right.">
      <PWStackRow first label="Output directory">
        <PWField value="~/Documents/Meetings/raw" mono/>
        <PWSmallButton>Choose…</PWSmallButton>
        <PWIconButton name="external" title="Reveal in Finder"/>
      </PWStackRow>
    </PWGroup>
    <PWGroup label="Microphone" footer="Voice processing takes effect on the next recording. Mute pausing applies to every meeting.">
      <PWToggleRow first on label="Pause mic when muted" sublabel="Pauses mic capture while you're muted in Teams / Zoom / Slack / Webex. Uses the locale catalogue (en, uk, de, es, fr, ja, pt, ru)."/>
      <PWToggleRow on={false} label="Voice processing" sublabel="Apple's noise-suppression + AGC. Drops your mic gain system-wide while recording, so other apps hear you quietly. Off by default; flip on only for solo voice memos."/>
    </PWGroup>
    <PWGroup label="Detection" footer="How long the detector waits after a meeting's signals go away before ending the recording, so a brief gap does not cut off a pause. Takes effect on the next daemon launch.">
      <PWStackRow first label="End debounce"><PWSlider value={8} max={30} format="8 s"/></PWStackRow>
    </PWGroup>
    <PWGroup label="Auto-record allowlist" footer="When the daemon detects audio from these apps, recording starts without showing the prompt.">
      <PWFullRow first>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          <PWTag>us.zoom.xos</PWTag>
          <PWTag>com.microsoft.teams2</PWTag>
        </div>
      </PWFullRow>
      <PWFullRow>
        <div style={{ display: "flex", gap: 8 }}>
          <PWField placeholder="us.zoom.xos" mono/>
          <PWSmallButton>Add</PWSmallButton>
        </div>
      </PWFullRow>
    </PWGroup>
  </div>
);

const PWPromptPane = () => (
  <div>
    <PWSectionHeader title="Prompt" caption="What happens the moment a meeting is detected."/>
    <PWGroup label="When a meeting is detected" footer="The floating prompt panel asks whether to record. If you don't respond, the default action above fires when the timeout elapses.">
      <PWStackRow first label="Prompt timeout"><PWSlider value={30} max={120} format="30 s"/></PWStackRow>
      <PWRow label="Default action" sublabel="Suppress the call (no recording) when the prompt times out.">
        <PWMenuPicker value="Skip"/>
      </PWRow>
      <PWStackRow label="Re-prompt cooldown" sublabel="After a recording or skip, suppress new prompts for the same app for this many seconds. Catches post-call mic flickers from Teams/Zoom.">
        <PWSlider value={60} max={300} format="60 s"/>
      </PWStackRow>
    </PWGroup>
    <PWGroup label="Stop conditions" footer="Gated on voice activity, not raw level, so a brief pause does not trigger it. A 'still meeting?' nudge fires partway through; a quiet-but-live native call is kept and re-nudged rather than stopped.">
      <PWStackRow first label="Mic-only silence backstop" sublabel="Auto-stop if your mic is silent AND no system audio plays for this many seconds. Catches the 'everyone else left and I forgot to stop' case.">
        <PWSlider value={480} max={1800} format="8 min"/>
      </PWStackRow>
    </PWGroup>
  </div>
);

const PWPipelinePane = () => (
  <div>
    <PWSectionHeader title="Pipeline" caption="What runs after the recording stops: summarization and languages. Transcription is in-process (FluidAudio)."/>
    <PWGroup label="Summarization" footer="Tries Anthropic first; falls back to local if the API fails or the key is missing.">
      <PWRow first label="Backend"><PWMenuPicker value="Auto"/></PWRow>
      <PWDisclosure label="Configure local model" sublabel="Model preset, endpoint, active model, and preload.">
        <PWRow first label="Local model" sublabel="~9 GB on disk, ~30s per meeting. Best quality for the size.">
          <PWMenuPicker value="Recommended (Qwen 14B-4bit)"/>
        </PWRow>
        <PWStackRow label="Endpoint URL" sublabel="Local mlx_lm.server target."><PWField value="http://127.0.0.1:8765" mono/></PWStackRow>
        <PWStackRow label="Active model" sublabel="Resident model on the local server.">
          <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 12, color: "var(--mp-fg-muted)" }}>mlx-community/Qwen2.5-14B-Instruct-4bit</span>
        </PWStackRow>
        <PWToggleRow on={false} label="Preload at launch" sublabel="Warm the model when the app starts so the first summary skips the cold-start. Holds the model in RAM while idle."/>
      </PWDisclosure>
    </PWGroup>
    <PWGroup label="Summarization prompt" footer="Read-only preview of the system prompt sent to the summarizer, with your configured team context and summary language applied.">
      <PWRow first label="System prompt"><PWSmallButton>View prompt</PWSmallButton></PWRow>
    </PWGroup>
    <PWGroup label="Languages">
      <PWRow first label="Transcription" sublabel="On-device ASR (FluidAudio Parakeet TDT). Auto-detect chooses per meeting; a fixed code skips detection. Applies on the next daemon launch."><PWMenuPicker value="Auto-detect"/></PWRow>
      <PWRow label="Summary" sublabel="Output language for the Notion summary."><PWMenuPicker value="Match transcript"/></PWRow>
    </PWGroup>
    <PWGroup label="Long meetings" footer="When the transcript exceeds this size, the pipeline writes a paste-into-Claude bundle instead of calling the Anthropic API. 0 disables the guard. ~80,000 chars ≈ 1 hour of speech.">
      <PWStackRow first label="Chunking threshold"><PWSlider value={80000} max={300000} format="80.0k chars" valueWidth={100}/></PWStackRow>
    </PWGroup>
  </div>
);

const PWIntegrationsPane = () => (
  <div>
    <PWSectionHeader title="Integrations" caption="Credentials for outbound services. Stored in ~/.config/meeting-pipe/secrets.env (mode 0600)." trailing={<PWSmallButton><span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}><Icon name="stethoscope" size={12}/> Run doctor…</span></PWSmallButton>}/>
    <PWGroup label="Anthropic" footer="Used to summarize transcripts. Get a key at console.anthropic.com. Local MLX backend doesn't need this.">
      <PWStackRow first label="API key"><PWSecretField placeholder="sk-ant-…"/></PWStackRow>
      <PWRow label="Status"><PWStatusPill tone="granted" icon="check-circle" text="Configured"/></PWRow>
    </PWGroup>
    <PWGroup label="Notion" footer="Create the integration at notion.so/profile/integrations, share your Meetings database with it, and paste the database ID here.">
      <PWStackRow first label="Integration token"><PWSecretField placeholder="ntn_…"/></PWStackRow>
      <PWStackRow label="Database ID"><PWField placeholder="32-char hex from your database URL" mono/></PWStackRow>
      <PWRow label="Status"><PWStatusPill tone="needed" icon="alert-triangle" text="Not configured"/></PWRow>
    </PWGroup>
  </div>
);

const PW_PERMISSIONS = [
  { name: "Microphone", icon: "mic", rationale: "Captures your voice via AVAudioEngine. Audio stays on this Mac.", tone: "granted", text: "Granted", action: "Open Settings" },
  { name: "Screen Recording", icon: "monitor", rationale: "Captures system audio via ScreenCaptureKit. No video is recorded.", tone: "granted", text: "Granted", action: "Open Settings" },
  { name: "Accessibility", icon: "user", rationale: "Reads browser tab titles to detect Meet and Teams Web sessions.", tone: "needed", text: "Needed", action: "Request" },
  { name: "Notifications", icon: "bell", rationale: "Record / skip prompts and 'meeting published' alerts.", tone: "granted", text: "Granted", action: "Open Settings" },
];

const PWPermissionsPane = () => (
  <div>
    <PWSectionHeader title="Permissions" caption="The four TCC permissions the daemon needs. None of these send anything off your machine." trailing={<PWSmallButton><span style={{ display: "inline-flex", alignItems: "center", gap: 5 }}><Icon name="refresh" size={12}/> Re-check</span></PWSmallButton>}/>
    <PWGroup footer="Granting Accessibility from System Settings requires a daemon restart for the change to take effect - macOS caches the trust verdict per-process at launch.">
      {PW_PERMISSIONS.map((p, i) => (
        <div key={p.name} style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 14px", borderTop: i === 0 ? "none" : "1px solid var(--mp-border-faint)" }}>
          <div style={{ width: 32, height: 32, borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-sunk)", display: "flex", alignItems: "center", justifyContent: "center", color: "var(--mp-fg-muted)", flexShrink: 0 }}><Icon name={p.icon} size={16}/></div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ fontSize: 13, fontWeight: 500 }}>{p.name}</span>
              <PWStatusPill tone={p.tone} icon={p.tone === "granted" ? "check-circle" : "alert-triangle"} text={p.text}/>
            </div>
            <div style={{ fontSize: 12, color: "var(--mp-fg-subtle)", marginTop: 2 }}>{p.rationale}</div>
          </div>
          <PWSmallButton>{p.action}</PWSmallButton>
        </div>
      ))}
    </PWGroup>
    <PWGroup label="Regulated mode" footer="Use for client / regulated meetings. The pipeline writes summaries to disk only - no transcript or summary is uploaded to Notion.">
      <PWToggleRow first on={false} label="Skip Notion publish" sublabel="Off - meetings publish to each workflow's own sinks (Notion only if that workflow enables it)."/>
    </PWGroup>
    <div style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "12px 14px", borderRadius: "var(--mp-radius-md)", background: "color-mix(in srgb, transparent 90%, var(--mp-signal-600))", border: "1px solid color-mix(in srgb, transparent 82%, var(--mp-signal-600))" }}>
      <span style={{ color: "var(--mp-signal-600)", display: "flex", flexShrink: 0, marginTop: 1 }}><Icon name="shield" size={16}/></span>
      <span style={{ fontSize: 12, lineHeight: 1.5, color: "var(--mp-fg-muted)" }}>Audio capture is fully on-device. The pipeline only reaches the network when sending the transcript to Anthropic for summarization, and when publishing to Notion.</span>
    </div>
  </div>
);

const PWAdvancedPane = () => (
  <div>
    <PWSectionHeader title="Advanced" caption="Plumbing for power users. Most people never come here."/>
    <PWGroup label="Configuration">
      <PWRow first label="Config file" sublabel="~/.config/meeting-pipe/config.toml">
        <PWSmallButton>Open in editor</PWSmallButton>
        <PWSmallButton>Reveal in Finder</PWSmallButton>
      </PWRow>
      <PWRow label="Logs folder" sublabel="Rotated daily. Used by mp doctor and bug reports.">
        <PWSmallButton>Open logs</PWSmallButton>
      </PWRow>
    </PWGroup>
    <PWGroup label="Diagnostics" footer="Takes effect after restarting MeetingPipe - the env var is set at daemon launch and inherited by every subprocess spawned afterwards.">
      <PWToggleRow first on={false} label="Verbose logging" sublabel="Emit extra detail to the unified log and pass MP_VERBOSE=1 to pipeline subprocesses."/>
    </PWGroup>
    <div style={{ fontSize: 11, color: "var(--mp-fg-faint)", textAlign: "center", marginTop: 4, lineHeight: 1.5 }}>
      MeetingPipe - config lives in ~/.config/meeting-pipe/. Workflows live in ~/.config/meeting-pipe/workflows/. Both are plain TOML, safe to edit by hand if you know what you're doing.
    </div>
  </div>
);

window.PreferencesWindow = PreferencesWindow;
