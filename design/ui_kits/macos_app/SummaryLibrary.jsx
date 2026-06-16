// SummaryLibrary - faithful recreation of the shipped Library window.
// Maps to LibraryWindow.swift + LibrarySidebar / LibraryListView / MeetingRow /
// MeetingDetailView + the Summary / Transcript / Audio tabs.
//
// Shipped structure: a custom 44pt toolbar strip over a 3-column
// NavigationSplitView (rail 200-260 / list 360-440 / detail 450+). Window is
// 1120x680, min 1024x480. Tabs are interactive here so a reviewer can switch
// Summary / Transcript / Audio; everything routes through colors_and_type.css.

const APP_GLYPH = {
  Zoom: "../../assets/app-glyphs/zoom.svg",
  Teams: "../../assets/app-glyphs/teams.svg",
  Meet: "../../assets/app-glyphs/meet.svg",
  Slack: "../../assets/app-glyphs/slack.svg",
};

// Approximation of MPColors.speakerPalette (the eight system colors, in order).
const SPEAKER_PALETTE = ["#0A84FF", "#AF52DE", "#FF2D55", "#FF9500", "#30B0C7", "#34C759", "#5856D6", "#A2845E"];

const SummaryLibrary = () => {
  const [tab, setTab] = React.useState("summary");
  return (
    <div style={{
      width: 1120, height: 680, background: "var(--mp-bg)",
      display: "flex", flexDirection: "column", overflow: "hidden",
      fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)",
      border: "1px solid var(--mp-border)", borderRadius: 10,
      boxShadow: "var(--mp-shadow-lg)",
    }}>
      <style>{`
        @keyframes mpLibPulse { 0%,100%{opacity:1} 50%{opacity:.35} }
        @keyframes mpLibSpin { to { transform: rotate(360deg) } }
      `}</style>
      <LibraryToolbar/>
      <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
        <LibrarySidebar/>
        <LibraryList/>
        <MeetingDetail tab={tab} setTab={setTab}/>
      </div>
    </div>
  );
};

/* ------------------------------------------------------------------ toolbar */
const LibraryToolbar = () => (
  <div style={{
    height: 44, flexShrink: 0, display: "flex", alignItems: "center", gap: 10,
    padding: "0 12px", background: "var(--mp-bg-sunk)",
    boxShadow: "inset 0 -0.5px 0 var(--mp-border)",
  }}>
    {/* Breadcrumb: Library > All meetings */}
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      <span style={{ fontSize: 12, fontWeight: 500, color: "var(--mp-fg-muted)" }}>Library</span>
      <span style={{ color: "var(--mp-fg-faint)", display: "flex" }}><Icon name="chevron-right" size={9}/></span>
      <span style={{ fontSize: 12, fontWeight: 500 }}>All meetings</span>
    </div>
    <div style={{ flex: 1 }}/>
    <StatePill state="recording"/>
    <RecordButton recording/>
    <button style={iconButton} title="Preferences…"><Icon name="settings" size={14}/></button>
  </div>
);

const iconButton = {
  width: 26, height: 26, display: "flex", alignItems: "center", justifyContent: "center",
  border: "none", background: "transparent", color: "var(--mp-fg-muted)",
  borderRadius: 6, cursor: "pointer",
};

const StatePill = ({ state }) => {
  const recording = state === "recording";
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 6, height: 22, padding: "0 9px",
      borderRadius: 999, border: "0.5px solid var(--mp-border-strong)",
      fontSize: 12, fontWeight: 500, color: "var(--mp-fg-muted)",
    }}>
      <span style={{
        width: 7, height: 7, borderRadius: "50%",
        background: recording ? "var(--mp-pulse-600)" : "var(--mp-ink-400)",
        opacity: recording ? 1 : 0.7,
        animation: recording ? "mpLibPulse 1.6s ease-in-out infinite" : "none",
      }}/>
      {recording ? "Recording" : "Idle"}
    </span>
  );
};

const RecordButton = ({ recording }) => (
  <button style={{
    display: "inline-flex", alignItems: "center", gap: 6, height: 26, padding: "0 12px",
    border: "none", borderRadius: 6, cursor: "pointer",
    fontFamily: "inherit", fontSize: 12, fontWeight: 500, color: "#fff",
    background: recording ? "var(--mp-pulse-600)" : "var(--mp-signal-600)",
  }}>
    {recording
      ? <Icon name="stop" size={10}/>
      : <span style={{ width: 8, height: 8, borderRadius: "50%", background: "#fff" }}/>}
    {recording ? "Stop" : "Record"}
  </button>
);

/* ------------------------------------------------------------------ sidebar */
const SCOPES = [
  { icon: "tray", label: "All meetings", count: 42, active: true },
  { icon: "calendar", label: "Today", count: 3 },
  { icon: "calendar", label: "Last 7 days", count: 11 },
  { icon: "calendar", label: "Last 30 days", count: 28 },
  { icon: "lock", label: "NDA only", count: 4 },
  { icon: "tag", label: "Untagged", count: 0 },
];

const WORKFLOWS = [
  { color: "var(--mp-signal-600)", emoji: "", name: "General", count: 18, isDefault: true },
  { color: "#0A6F67", emoji: "", name: "Engineering", count: 12 },
  { color: "#B27300", emoji: "", name: "Client work", count: 6 },
  { color: "#4A4F58", emoji: "", name: "Personal", count: 6 },
];

const LibrarySidebar = () => (
  <div style={{
    width: 220, flexShrink: 0, background: "var(--mp-bg-sunk)",
    borderRight: "1px solid var(--mp-border)", padding: "10px 8px",
    display: "flex", flexDirection: "column", gap: 2, overflow: "auto",
  }}>
    <RailHeader>Library</RailHeader>
    {SCOPES.map((s, i) => <ScopeRow key={i} {...s}/>)}
    <div style={{ height: 14 }}/>
    <RailHeader>Workflows</RailHeader>
    {WORKFLOWS.map((w, i) => <WorkflowRow key={i} {...w}/>)}
    <button style={{
      display: "flex", alignItems: "center", gap: 8, padding: "5px 8px", marginTop: 2,
      border: "none", background: "transparent", color: "var(--mp-fg-subtle)",
      fontFamily: "inherit", fontSize: 13, cursor: "pointer", borderRadius: 6,
    }}>
      <Icon name="plus" size={14}/> New workflow
    </button>
  </div>
);

const RailHeader = ({ children }) => (
  <div style={{
    fontSize: 10, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase",
    color: "var(--mp-fg-subtle)", padding: "6px 8px 4px",
  }}>{children}</div>
);

const ScopeRow = ({ icon, label, count, active }) => (
  <div style={{
    display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
    borderRadius: 6, cursor: "pointer", fontSize: 13,
    background: active ? "var(--mp-signal-600)" : "transparent",
    color: active ? "#fff" : "var(--mp-fg)",
  }}>
    <Icon name={icon} size={14}/>
    <span style={{ flex: 1 }}>{label}</span>
    <span style={{
      fontFamily: "var(--mp-font-mono)", fontSize: 11,
      color: active ? "rgba(255,255,255,0.85)" : (count === 0 ? "var(--mp-fg-faint)" : "var(--mp-fg-subtle)"),
    }}>{count}</span>
  </div>
);

const WorkflowRow = ({ color, emoji, name, count, isDefault }) => (
  <div style={{
    display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
    borderRadius: 6, cursor: "pointer", fontSize: 13, color: "var(--mp-fg)",
  }}>
    <span style={{ width: 8, height: 8, borderRadius: "50%", background: color, flexShrink: 0 }}/>
    {emoji && <span style={{ fontSize: 11 }}>{emoji}</span>}
    <span>{name}</span>
    {isDefault && <span style={{ fontSize: 10, color: "var(--mp-fg-faint)" }}>· default</span>}
    <span style={{ flex: 1 }}/>
    <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 11, color: count === 0 ? "var(--mp-fg-faint)" : "var(--mp-fg-subtle)" }}>{count}</span>
  </div>
);

/* --------------------------------------------------------------------- list */
const GROUPS = [
  { header: "Today", rows: [
    { title: "Weekly sync", source: "Zoom", dur: "12:07", wf: WORKFLOWS[0], when: "Today 14:30", status: "recording" },
    { title: "Release 3.2 validation review", source: "Zoom", dur: "47:21", wf: WORKFLOWS[1], when: "Today 11:02", status: "ready", selected: true },
    { title: "Standup", source: "Slack", dur: "18:04", wf: WORKFLOWS[0], when: "Today 10:00", status: "processing", stage: "Summarizing", elapsed: "1:24" },
  ]},
  { header: "Yesterday", rows: [
    { title: "Helix Diagnostics call", source: "Teams", dur: "1:12:48", wf: WORKFLOWS[2], when: "Yesterday 16:30", status: "nda", nda: true },
    { title: "Backlog refinement", source: "Meet", dur: "34:12", wf: WORKFLOWS[1], when: "Yesterday 09:30", status: "ready" },
  ]},
  { header: "This week", rows: [
    { title: "QMS audit prep", source: "Zoom", dur: "55:00", wf: WORKFLOWS[2], when: "Wed 15:00", status: "partial" },
    { title: "1:1 with Marko", source: "Meet", dur: "28:30", wf: WORKFLOWS[3], when: "Mon 09:30", status: "failed" },
  ]},
];

const LibraryList = () => (
  <div style={{ width: 440, flexShrink: 0, borderRight: "1px solid var(--mp-border)", display: "flex", flexDirection: "column", minHeight: 0 }}>
    {/* scope header */}
    <div style={{ padding: "12px 16px 10px" }}>
      <div style={{ fontSize: 17, fontWeight: 600 }}>All meetings</div>
      <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2 }}>42 meetings</div>
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <FilterBar/>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    {/* list body */}
    <div style={{ flex: 1, overflow: "auto" }}>
      {GROUPS.map((g, i) => (
        <div key={i}>
          <div style={{
            fontSize: 11, fontWeight: 600, color: "var(--mp-fg-subtle)",
            padding: "10px 16px 4px",
          }}>{g.header}</div>
          {g.rows.map((r, j) => <MeetingRow key={j} {...r}/>)}
        </div>
      ))}
    </div>
  </div>
);

const FilterBar = () => (
  <div style={{ height: 36, flexShrink: 0, display: "flex", alignItems: "center", gap: 8, padding: "0 14px" }}>
    <div style={{
      flex: 1, minWidth: 0, display: "flex", alignItems: "center", gap: 6, height: 24, padding: "0 8px",
      borderRadius: 6, border: "0.5px solid var(--mp-border)", background: "rgba(127,127,127,0.05)",
    }}>
      <span style={{ color: "var(--mp-fg-subtle)", display: "flex", flexShrink: 0 }}><Icon name="search" size={11}/></span>
      <span style={{ fontSize: 12, color: "var(--mp-fg-subtle)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Search titles, summaries, decisions…</span>
    </div>
    <RefChip label="Workflow"/>
    <RefChip label="App"/>
    <RefChip label="Status"/>
    <RefChip label="Date"/>
    <span style={{ fontSize: 11, color: "var(--mp-fg-faint)", cursor: "default", padding: "0 2px" }}>Clear</span>
  </div>
);

const RefChip = ({ label }) => (
  <span style={{
    display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 8px",
    borderRadius: 6, border: "0.5px solid var(--mp-border)",
    fontSize: 11, fontWeight: 500, color: "var(--mp-fg-muted)", whiteSpace: "nowrap", cursor: "pointer",
  }}>
    {label}<Icon name="chevron-down" size={8}/>
  </span>
);

const MeetingRow = ({ title, source, dur, wf, when, status, nda, stage, elapsed, selected }) => {
  const recording = status === "recording";
  return (
    <div style={{
      position: "relative", height: 44, display: "flex", alignItems: "center", gap: 10,
      padding: "0 14px", cursor: "pointer",
      background: selected ? "var(--mp-signal-100)" : (recording ? "rgba(229,72,77,0.06)" : "transparent"),
    }}>
      {recording && <span style={{ position: "absolute", left: 0, top: 6, bottom: 6, width: 2, borderRadius: 1, background: "var(--mp-signal-600)" }}/>}
      <RowGlyph source={source} nda={nda}/>
      <div style={{ minWidth: 0, display: "flex", flexDirection: "column", gap: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 500, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
          color: nda ? "var(--mp-fg-muted)" : "var(--mp-fg)",
        }}>{title}</div>
        <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, color: "var(--mp-fg-subtle)", whiteSpace: "nowrap" }}>
          <span>{source}</span>
          <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
          <span style={{ fontFamily: "var(--mp-font-mono)" }}>{dur}</span>
          <WorkflowChip wf={wf}/>
        </div>
      </div>
      <div style={{ flex: 1 }}/>
      {status === "failed" && <InlineButton>Retry</InlineButton>}
      {status === "processing" ? <ProcessingIndicator stage={stage} elapsed={elapsed}/> : <RowStatusPill status={status}/>}
      <span style={{ minWidth: 100, textAlign: "right", fontFamily: "var(--mp-font-mono)", fontSize: 11, color: "var(--mp-fg-muted)", whiteSpace: "nowrap" }}>{when}</span>
    </div>
  );
};

const RowGlyph = ({ source, nda }) => {
  const box = { width: 22, height: 22, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 };
  if (nda) return <span style={{ ...box, color: "var(--mp-fg-subtle)" }}><Icon name="lock" size={13}/></span>;
  if (APP_GLYPH[source]) return <span style={box}><img src={APP_GLYPH[source]} width={22} height={22} alt="" style={{ borderRadius: 5 }}/></span>;
  return <span style={{ ...box, color: "var(--mp-fg-muted)" }}><Icon name="waveform-circle" size={18}/></span>;
};

const InlineButton = ({ children }) => (
  <button style={{
    height: 20, padding: "0 8px", borderRadius: 5, fontSize: 11, fontFamily: "inherit",
    border: "0.5px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)",
    color: "var(--mp-fg)", cursor: "pointer",
  }}>{children}</button>
);

const ProcessingIndicator = ({ stage, elapsed }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
    <span style={{
      width: 12, height: 12, borderRadius: "50%",
      border: "1.5px solid var(--mp-border-faint)", borderTopColor: "var(--mp-signal-400)",
      animation: "mpLibSpin 0.8s linear infinite",
    }}/>
    <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: 11, color: "var(--mp-fg-subtle)" }}>{stage} {elapsed}</span>
  </div>
);

const PILL = {
  ready: { dot: "var(--mp-success-600)", label: "Ready" },
  recording: { dot: "var(--mp-pulse-500)", label: "Recording", pulse: true },
  processing: { dot: "var(--mp-signal-400)", label: "Processing" },
  paste: { dot: "var(--mp-signal-400)", label: "Paste pending" },
  failed: { dot: "var(--mp-pulse-500)", label: "Failed", stroke: "rgba(245,89,94,0.32)" },
  partial: { dot: "var(--mp-warning-600)", label: "Partial" },
  unpublished: { dot: "var(--mp-warning-600)", label: "Unpublished" },
  nda: { dot: "var(--mp-fg-subtle)", label: "Local only" },
  neutral: { dot: "var(--mp-fg-subtle)", label: "-" },
};

const RowStatusPill = ({ status }) => {
  const p = PILL[status] || PILL.neutral;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 5, height: 18, padding: "0 8px",
      borderRadius: 999, border: `0.5px solid ${p.stroke || "var(--mp-border-strong)"}`,
      fontSize: 11, fontWeight: 500, color: p.dot, whiteSpace: "nowrap",
    }}>
      <span style={{ width: 6, height: 6, borderRadius: "50%", background: p.dot, animation: p.pulse ? "mpLibPulse 1.6s ease-in-out infinite" : "none" }}/>
      {p.label}
    </span>
  );
};

const WorkflowChip = ({ wf }) => {
  if (!wf) return null;
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 18, padding: "0 7px", borderRadius: 999, background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
      <span style={{ width: 7, height: 7, borderRadius: "50%", background: wf.color }}/>
      <span style={{ fontSize: 11, color: "var(--mp-fg-muted)" }}>{wf.name}</span>
    </span>
  );
};

/* ------------------------------------------------------------------- detail */
const MeetingDetail = ({ tab, setTab }) => (
  <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0, background: "var(--mp-bg)" }}>
    {/* header */}
    <div style={{ padding: "14px 16px 12px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <WorkflowChip wf={WORKFLOWS[1]}/>
        <div style={{ flex: 1 }}/>
        <button style={ghostIcon} title="Open in Notion"><Icon name="external" size={15}/></button>
        <button style={ghostIcon} title="Open in Obsidian"><Icon name="book" size={15}/></button>
        <button style={ghostIcon} title="Show raw files in Finder"><Icon name="folder" size={15}/></button>
        <button style={ghostIcon} title="More actions"><Icon name="more-circle" size={16}/></button>
      </div>
      <div style={{ fontSize: 19, fontWeight: 600, marginTop: 6, letterSpacing: "-0.01em" }}>Release 3.2 validation review</div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 6, fontSize: 11, color: "var(--mp-fg-subtle)" }}>
        <span>May 14, 2025 at 11:02 AM</span>
        <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
        <span style={{ fontFamily: "var(--mp-font-mono)" }}>47:21</span>
        <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
        <span style={{ fontFamily: "var(--mp-font-mono)" }}>EN</span>
        <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
        <span>Zoom</span>
      </div>
    </div>
    {/* tab strip */}
    <div style={{ display: "flex", alignItems: "flex-end", padding: "0 16px" }}>
      {[["summary", "Summary"], ["transcript", "Transcript"], ["audio", "Audio"]].map(([id, label]) => {
        const active = tab === id;
        return (
          <button key={id} onClick={() => setTab(id)} style={{
            border: "none", background: "transparent", cursor: "pointer", fontFamily: "inherit",
            fontSize: 12, fontWeight: 500, padding: "0 16px 0 0",
            color: active ? "var(--mp-fg)" : "var(--mp-fg-muted)",
          }}>
            <div style={{ padding: "9px 0" }}>{label}</div>
            <div style={{ height: 1.5, borderRadius: 1, marginRight: 16, background: active ? "var(--mp-signal-600)" : "transparent" }}/>
          </button>
        );
      })}
    </div>
    <div style={{ height: 1, background: "var(--mp-border-faint)" }}/>
    <div style={{ flex: 1, overflow: "auto" }}>
      {tab === "summary" && <SummaryTab/>}
      {tab === "transcript" && <TranscriptTab/>}
      {tab === "audio" && <AudioTab/>}
    </div>
  </div>
);

const ghostIcon = {
  width: 26, height: 26, display: "flex", alignItems: "center", justifyContent: "center",
  border: "none", background: "transparent", color: "var(--mp-fg-muted)", borderRadius: 6, cursor: "pointer",
};

/* ----- Summary tab ----- */
const SummaryTab = () => (
  <div style={{ maxWidth: 640, padding: 20, display: "flex", flexDirection: "column", gap: 24 }}>
    <Section icon="file-text" title="Summary">
      <Bullets items={[
        "Release 3.2 cut moves to Friday once the validation review unblocks the remaining sign-off.",
        "Two flaky pipeline tests root-caused to clock skew on the staging runner.",
        "Customer-facing changelog draft to circulate before end of day.",
      ]}/>
    </Section>
    <Section icon="seal-check" title="Decisions">
      <Bullets numbered items={[
        "Defer the audit-log refactor to 3.3.",
        "Keep the staging runner pinned until the clock fix lands.",
      ]}/>
    </Section>
    <Section icon="checklist" title="Action items">
      <ActionItem task="Land the runner-clock fix and re-enable the skipped tests." owner="Anya" due="today" confidence="high"/>
      <ActionItem task="Send the Notion changelog draft for review." owner="Marko" due="today" confidence="medium"/>
    </Section>
    <Section icon="help-bubble" title="Open questions">
      <Bullets items={["Does the 3.2 cut need a second validation pass after the runner fix?"]}/>
    </Section>
    <Section icon="users" title="Attendees">
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
        {["Anya", "Marko", "Priya", "You"].map((n) => (
          <span key={n} style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 22, padding: "0 8px", borderRadius: 6, border: "0.5px solid var(--mp-border)", fontSize: 12, color: "var(--mp-fg-muted)" }}>
            <Icon name="user" size={11}/> {n}
          </span>
        ))}
      </div>
    </Section>
  </div>
);

const Section = ({ icon, title, children }) => (
  <div>
    <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}>
      <span style={{ color: "var(--mp-fg-subtle)", display: "flex" }}><Icon name={icon} size={14}/></span>
      <span style={{ fontSize: 13, fontWeight: 600 }}>{title}</span>
    </div>
    {children}
  </div>
);

const Bullets = ({ items, numbered }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
    {items.map((t, i) => (
      <div key={i} style={{ display: "flex", gap: 8, fontSize: 13, lineHeight: 1.55 }}>
        <span style={{ minWidth: 16, color: "var(--mp-fg-faint)", fontFamily: numbered ? "var(--mp-font-mono)" : "inherit" }}>{numbered ? `${i + 1}.` : "•"}</span>
        <span>{t}</span>
      </div>
    ))}
  </div>
);

const ActionItem = ({ task, owner, due, confidence }) => (
  <div style={{ marginBottom: 10 }}>
    <div style={{ display: "flex", gap: 8, fontSize: 13, lineHeight: 1.5 }}>
      <span style={{ color: "var(--mp-fg-faint)", marginTop: 2, display: "flex" }}><Icon name="circle" size={13}/></span>
      <span>{task}</span>
    </div>
    <div style={{ display: "flex", gap: 6, marginLeft: 21, marginTop: 4 }}>
      {owner && <MiniChip icon="user" tint="var(--mp-signal-600)">{owner}</MiniChip>}
      {due && <MiniChip icon="calendar" tint="var(--mp-warning-600)">{due}</MiniChip>}
      {confidence && confidence !== "medium" && <MiniChip icon="gauge" tint={confidence === "high" ? "var(--mp-success-600)" : "var(--mp-fg-subtle)"}>{confidence}</MiniChip>}
    </div>
  </div>
);

const MiniChip = ({ icon, tint, children }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 18, padding: "0 6px", borderRadius: 4, fontSize: 11, color: tint, background: "color-mix(in srgb, " + "transparent 88%, currentColor)" }}>
    <Icon name={icon} size={10}/> {children}
  </span>
);

/* ----- Transcript tab ----- */
const TRANSCRIPT = [
  { sp: 0, name: "Speaker 1", t: "0:03", body: "Alright, let's start with the validation review. Where are we on the remaining sign-offs?", active: true },
  { sp: 1, name: "Speaker 2", t: "0:11", body: "Two left. The runner clock skew was the blocker on both flaky tests, so once that fix lands we should be green." },
  { sp: 0, name: "Speaker 1", t: "0:24", body: "Good. Can we move the 3.2 cut to Friday then?" },
  { sp: 2, name: "Speaker 3", t: "0:31", body: "Friday works for me as long as the changelog draft goes out before end of day." },
  { sp: 1, name: "Speaker 2", t: "0:40", body: "I'll send the changelog for review this afternoon." },
];

const TranscriptTab = () => (
  <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
    <div style={{ flex: 1, overflow: "auto", padding: "10px 0" }}>
      <div style={{ fontSize: 12, color: "var(--mp-fg-faint)", padding: "0 16px 6px" }}>Language: en</div>
      {TRANSCRIPT.map((r, i) => (
        <div key={i} style={{
          display: "flex", gap: 10, padding: "6px 16px",
          background: r.active ? "var(--mp-signal-100)" : "transparent",
        }}>
          <span style={{ width: 8, height: 8, borderRadius: "50%", background: SPEAKER_PALETTE[r.sp], marginTop: 5, flexShrink: 0 }}/>
          <div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <span style={{ fontSize: 12, fontWeight: 600, color: SPEAKER_PALETTE[r.sp] }}>{r.name}</span>
              <span style={{ fontSize: 12, fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-faint)" }}>{r.t}</span>
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.5, marginTop: 1 }}>{r.body}</div>
          </div>
        </div>
      ))}
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <PlaybackBar/>
  </div>
);

const PlaybackBar = () => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 16px", flexShrink: 0 }}>
    <Icon name="play" size={14}/>
    <span style={{ fontSize: 12, fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)", width: 40, textAlign: "right" }}>0:24</span>
    <div style={{ flex: 1, height: 4, borderRadius: 2, background: "var(--mp-ink-200)", position: "relative" }}>
      <div style={{ width: "9%", height: "100%", borderRadius: 2, background: "var(--mp-signal-600)" }}/>
      <div style={{ position: "absolute", left: "9%", top: -5, width: 14, height: 14, marginLeft: -7, borderRadius: "50%", background: "#fff", border: "1px solid var(--mp-border-strong)", boxShadow: "0 1px 3px rgba(0,0,0,0.2)" }}/>
    </div>
    <span style={{ fontSize: 12, fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>47:21</span>
  </div>
);

/* ----- Audio tab ----- */
const bars = (n, seed) => Array.from({ length: n }, (_, i) => {
  const v = Math.abs(Math.sin((i + seed) * 0.7) * 0.6 + Math.sin((i + seed) * 0.23) * 0.4);
  return 0.12 + v * 0.85;
});

const AudioTab = () => (
  <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
    <div style={{ flex: 1, position: "relative", display: "flex", flexDirection: "column", minHeight: 220 }}>
      <Channel label="Mic" tint="var(--mp-signal-600)" seed={2}/>
      <Channel label="System" tint="var(--mp-fg-muted)" seed={9}/>
      {/* playhead */}
      <div style={{ position: "absolute", left: "40%", top: 0, bottom: 0, width: 1.5, background: "var(--mp-signal-600)" }}/>
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 16px", flexShrink: 0 }}>
      <Icon name="play" size={14}/>
      <span style={{ fontSize: 12, fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>18:56</span>
      <span style={{ color: "var(--mp-fg-faint)" }}>/</span>
      <span style={{ fontSize: 12, fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>47:21</span>
      <div style={{ flex: 1 }}/>
      <WaveSegmented options={["Mono", "Stereo"]} selected={1}/>
      <RefChip label="Zoom: Fit"/>
    </div>
  </div>
);

const Channel = ({ label, tint, seed }) => (
  <div style={{ flex: 1, position: "relative", borderBottom: "0.5px solid var(--mp-border-faint)", background: "color-mix(in srgb, transparent 95%, " + tint + ")" }}>
    <div style={{ position: "absolute", top: 6, left: 12, fontSize: 12, fontWeight: 600, color: tint }}>{label}</div>
    <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", gap: 1, padding: "0 12px" }}>
      {bars(160, seed).map((h, i) => (
        <div key={i} style={{ flex: 1, height: `${Math.round(h * 70)}%`, background: tint, opacity: 0.8, borderRadius: 0.5 }}/>
      ))}
    </div>
  </div>
);

const WaveSegmented = ({ options, selected }) => (
  <span style={{ display: "inline-flex", padding: 2, borderRadius: 6, background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
    {options.map((o, i) => (
      <span key={o} style={{
        fontSize: 11, padding: "2px 8px", borderRadius: 4, cursor: "pointer",
        background: i === selected ? "var(--mp-bg-raised)" : "transparent",
        color: i === selected ? "var(--mp-fg)" : "var(--mp-fg-muted)",
        boxShadow: i === selected ? "var(--mp-shadow-xs)" : "none",
      }}>{o}</span>
    ))}
  </span>
);

window.SummaryLibrary = SummaryLibrary;
