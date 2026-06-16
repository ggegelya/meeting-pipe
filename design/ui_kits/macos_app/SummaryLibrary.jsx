// SummaryLibrary - the redesigned Library window (target for TECH-DSN17, mockup
// refresh tracked as TECH-DSN16). Maps to LibraryWindow.swift + LibrarySidebar /
// LibraryListView / MeetingRow / MeetingDetailView + the Summary / Transcript /
// Audio tabs.
//
// What this renders: a labelled STATE GALLERY so index.html is a complete visual
// spec. The first frame is the live 3-pane window (tabs are clickable); the rest
// are frozen states a reviewer and the SwiftUI implementer can read off directly:
// the reader modes (transcript, audio, edit, edit-with-save-error, reprocess
// compare, batch), the triage states (needs-you scope, multi-select, empty
// search), the first-run empty Library, and the narrow rail-collapsed fallback.
//
// Ground rules honoured here:
//  - Every colour, space, type and radius value routes through colors_and_type.css
//    (--mp-* tokens). Layout dimensions are literal px (mac windows are fixed-size).
//  - Accent is unified to signal-teal end-state (TECH-DSN10/11/12): selection,
//    toggles, primary action, playhead, waveform and focus rings are all teal,
//    never system blue. Focus rings use the --mp-focus-ring token directly.
//  - Workflow dots are the curated tonal set only: teal / deep-teal / amber / ink.
//    Coral (--mp-pulse-*) is reserved for the recording dot.
//  - No side-stripe row accents. No em-dashes in any copy. Sentence case, second
//    person, ellipsis only for in-flight or "opens another surface".
//
// All top-level names are SL-prefixed: the kit shares one global lexical scope.

const SL_APP_GLYPH = {
  Zoom: "../../assets/app-glyphs/zoom.svg",
  Teams: "../../assets/app-glyphs/teams.svg",
  Meet: "../../assets/app-glyphs/meet.svg",
  Slack: "../../assets/app-glyphs/slack.svg",
};

// Diarization speakers need distinguishable hues. The shipped app keeps
// MPColors.speakerPalette; on-palette unification curates it to the tonal set.
// The mockup shows three on-token speakers (teal / amber / ink), no arbitrary hex.
const SL_SPEAKER = ["var(--mp-signal-600)", "var(--mp-warning-600)", "var(--mp-ink-600)"];

const SL_WF = {
  general:  { name: "General",     dot: "var(--mp-signal-600)", isDefault: true },
  eng:      { name: "Engineering", dot: "var(--mp-signal-700)" },
  client:   { name: "Client work", dot: "var(--mp-warning-600)" },
  personal: { name: "Personal",    dot: "var(--mp-ink-600)" },
};

// status -> tint + label + marker. Every state carries a label, never colour alone.
const SL_STATUS = {
  ready:       { tint: "var(--mp-success-600)", label: "Ready",         icon: "check-circle" },
  recording:   { tint: "var(--mp-pulse-500)",   label: "Recording",     pulse: true },
  processing:  { tint: "var(--mp-signal-500)",  label: "Processing",    spin: true },
  paste:       { tint: "var(--mp-warning-600)", label: "Paste pending", icon: "alert" },
  failed:      { tint: "var(--mp-danger-600)",  label: "Failed",        icon: "alert-triangle" },
  partial:     { tint: "var(--mp-warning-600)", label: "Partial",       icon: "alert-triangle" },
  unpublished: { tint: "var(--mp-warning-600)", label: "Unpublished" },
  local:       { tint: "var(--mp-fg-subtle)",   label: "Local only",    icon: "lock" },
};

const SL_MEETINGS = {
  weekly:   { id: "weekly",   title: "Weekly sync",                  source: "Zoom",  dur: "12:07",   wf: SL_WF.general,  when: "Today 14:30",     status: "recording" },
  standup:  { id: "standup",  title: "Standup",                      source: "Slack", dur: "18:04",   wf: SL_WF.general,  when: "Today 10:00",     status: "processing", stage: "Summarizing", elapsed: "1:24" },
  release:  { id: "release",  title: "Release 3.2 validation review", source: "Zoom", dur: "47:21",   wf: SL_WF.eng,      when: "Today 11:02",     status: "ready" },
  qms:      { id: "qms",      title: "QMS audit prep",               source: "Teams", dur: "55:00",   wf: SL_WF.client,   when: "Today 09:15",     status: "partial" },
  helix:    { id: "helix",    title: "Helix Diagnostics call",       source: "Teams", dur: "1:12:48", wf: SL_WF.client,   when: "Yesterday 16:30", status: "local", nda: true },
  backlog:  { id: "backlog",  title: "Backlog refinement",           source: "Meet",  dur: "34:12",   wf: SL_WF.eng,      when: "Yesterday 09:30", status: "ready" },
  vendor:   { id: "vendor",   title: "Vendor onboarding",            source: "Zoom",  dur: "41:09",   wf: SL_WF.client,   when: "Wed 13:00",       status: "unpublished" },
  marko:    { id: "marko",    title: "1:1 with Marko",               source: "Meet",  dur: "28:30",   wf: SL_WF.personal, when: "Mon 09:30",       status: "failed" },
  board:    { id: "board",    title: "Board pre-read",               source: "Teams", dur: "1:34:20", wf: SL_WF.client,   when: "Mon 16:00",       status: "paste" },
};

const SL_SCOPES = [
  { icon: "tray",     label: "All meetings", count: 42, key: "all" },
  { icon: "calendar", label: "Today",        count: 4,  key: "today" },
  { icon: "calendar", label: "Last 7 days",  count: 11, key: "7d" },
  { icon: "bell",     label: "Needs you",    count: 3,  key: "needs", attention: true },
  { icon: "lock",     label: "NDA only",     count: 4,  key: "nda" },
];

/* =============================================================== shared chrome */

const SL_iconBtn = {
  width: 26, height: 26, display: "flex", alignItems: "center", justifyContent: "center",
  border: "none", background: "transparent", color: "var(--mp-fg-muted)",
  borderRadius: "var(--mp-radius-sm)", cursor: "pointer",
};

const SL_ghostBtn = {
  ...SL_iconBtn, width: 28, height: 28,
};

const SLWindow = ({ w = 1120, h = 680, children }) => (
  <div style={{
    width: w, height: h, background: "var(--mp-bg)", color: "var(--mp-fg)",
    display: "flex", flexDirection: "column", overflow: "hidden",
    fontFamily: "var(--mp-font-sans)", fontSize: "var(--mp-text-base)",
    border: "1px solid var(--mp-border)", borderRadius: "var(--mp-radius-md)",
    boxShadow: "var(--mp-shadow-lg)",
  }}>{children}</div>
);

const SLToolbar = ({ recording, railCollapsed }) => (
  <div style={{
    height: 44, flexShrink: 0, display: "flex", alignItems: "center", gap: 10,
    padding: "0 12px", background: "var(--mp-bg-sunk)",
    boxShadow: "inset 0 -0.5px 0 var(--mp-border)",
  }}>
    <button style={{ ...SL_iconBtn, color: railCollapsed ? "var(--mp-signal-600)" : "var(--mp-fg-muted)" }} title="Toggle sidebar">
      <Icon name="sliders" size={15}/>
    </button>
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      <span style={{ color: "var(--mp-fg-muted)", fontWeight: 500 }}>Library</span>
      <span style={{ color: "var(--mp-fg-faint)", display: "flex" }}><Icon name="chevron-right" size={9}/></span>
      <span style={{ fontWeight: 500 }}>All meetings</span>
    </div>
    <div style={{ flex: 1 }}/>
    <SLStatePill recording={recording}/>
    <SLRecordButton recording={recording}/>
    <button style={SL_iconBtn} title="Preferences…"><Icon name="settings" size={15}/></button>
  </div>
);

const SLStatePill = ({ recording }) => (
  <span style={{
    display: "inline-flex", alignItems: "center", gap: 6, height: 22, padding: "0 9px",
    borderRadius: "var(--mp-radius-full)", border: "0.5px solid var(--mp-border-strong)",
    fontSize: "var(--mp-text-sm)", fontWeight: 500, color: "var(--mp-fg-muted)",
  }}>
    <span style={{
      width: 7, height: 7, borderRadius: "var(--mp-radius-full)",
      background: recording ? "var(--mp-pulse-500)" : "var(--mp-ink-400)",
      animation: recording ? "slPulse 1.6s ease-in-out infinite" : "none",
    }}/>
    {recording ? "Recording" : "Idle"}
  </span>
);

// Idle -> teal primary Record. Recording -> a quiet surface Stop; the coral lives
// in the state pill's dot, so the button stays calm (coral is reserved for the dot).
const SLRecordButton = ({ recording }) => (
  recording ? (
    <button style={{
      display: "inline-flex", alignItems: "center", gap: 6, height: 26, padding: "0 11px",
      borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontFamily: "inherit",
      fontSize: "var(--mp-text-sm)", fontWeight: 500, color: "var(--mp-fg)",
      background: "var(--mp-bg-raised)", border: "0.5px solid var(--mp-border-strong)",
    }}>
      <span style={{ color: "var(--mp-pulse-600)", display: "flex" }}><Icon name="stop" size={11}/></span>
      Stop
    </button>
  ) : (
    <button style={{
      display: "inline-flex", alignItems: "center", gap: 6, height: 26, padding: "0 12px",
      border: "none", borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontFamily: "inherit",
      fontSize: "var(--mp-text-sm)", fontWeight: 500, color: "var(--mp-fg-on-signal)",
      background: "var(--mp-signal-600)",
    }}>
      <span style={{ width: 8, height: 8, borderRadius: "var(--mp-radius-full)", background: "var(--mp-fg-on-signal)" }}/>
      Record
    </button>
  )
);

/* ===================================================================== sidebar */

const SLSidebar = ({ activeScope = "all", firstRun }) => (
  <div style={{
    width: 220, flexShrink: 0, background: "var(--mp-bg-sunk)",
    borderRight: "1px solid var(--mp-border)", padding: "10px 8px",
    display: "flex", flexDirection: "column", gap: 2, overflow: "auto",
  }}>
    <SLRailHeader>Library</SLRailHeader>
    {SL_SCOPES.map((s) => <SLScopeRow key={s.key} {...s} count={firstRun ? 0 : s.count} active={s.key === activeScope}/>)}
    <div style={{ height: 14 }}/>
    <SLRailHeader>Workflows</SLRailHeader>
    {Object.values(SL_WF).map((w) => <SLWorkflowRow key={w.name} {...w}/>)}
    <button style={{
      display: "flex", alignItems: "center", gap: 8, padding: "5px 8px", marginTop: 2,
      border: "none", background: "transparent", color: "var(--mp-fg-subtle)",
      fontFamily: "inherit", fontSize: "var(--mp-text-base)", cursor: "pointer", borderRadius: "var(--mp-radius-sm)",
    }}>
      <Icon name="plus" size={14}/> New workflow
    </button>
  </div>
);

const SLRailHeader = ({ children }) => (
  <div style={{
    fontSize: "var(--mp-text-xs)", fontWeight: 600, letterSpacing: "var(--mp-tracking-caps)",
    textTransform: "uppercase", color: "var(--mp-fg-subtle)", padding: "6px 8px 4px",
  }}>{children}</div>
);

const SLScopeRow = ({ icon, label, count, active, attention }) => {
  const showBadge = attention && count > 0;
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
      borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontSize: "var(--mp-text-base)",
      background: active ? "var(--mp-signal-600)" : "transparent",
      color: active ? "var(--mp-fg-on-signal)" : "var(--mp-fg)",
    }}>
      <Icon name={icon} size={14}/>
      <span style={{ flex: 1 }}>{label}</span>
      {showBadge ? (
        <span style={{
          minWidth: 16, height: 16, padding: "0 5px", borderRadius: "var(--mp-radius-full)",
          display: "inline-flex", alignItems: "center", justifyContent: "center",
          fontSize: "var(--mp-text-xs)", fontWeight: 600, fontFamily: "var(--mp-font-mono)",
          color: active ? "var(--mp-signal-700)" : "#fff",
          background: active ? "var(--mp-fg-on-signal)" : "var(--mp-warning-600)",
        }}>{count}</span>
      ) : (
        <span style={{
          fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-xs)",
          color: active ? "color-mix(in srgb, var(--mp-fg-on-signal) 85%, transparent)"
                         : (count === 0 ? "var(--mp-fg-faint)" : "var(--mp-fg-subtle)"),
        }}>{count}</span>
      )}
    </div>
  );
};

const SLWorkflowRow = ({ dot, name, count = 0, isDefault }) => (
  <div style={{
    display: "flex", alignItems: "center", gap: 8, height: 28, padding: "0 8px",
    borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontSize: "var(--mp-text-base)", color: "var(--mp-fg)",
  }}>
    <span style={{ width: 8, height: 8, borderRadius: "var(--mp-radius-full)", background: dot, flexShrink: 0 }}/>
    <span>{name}</span>
    {isDefault && <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-faint)" }}>· default</span>}
    <span style={{ flex: 1 }}/>
    <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)" }}>{count || ""}</span>
  </div>
);

/* ======================================================================== list */

const SLList = ({ title, count, scope = "all", selectedId, multiSelect, checkedIds = [], empty }) => (
  <div style={{ width: 440, flexShrink: 0, borderRight: "1px solid var(--mp-border)", display: "flex", flexDirection: "column", minHeight: 0, background: "var(--mp-bg)" }}>
    <div style={{ padding: "12px 16px 10px", display: "flex", alignItems: "baseline", gap: 8 }}>
      <div style={{ fontSize: "var(--mp-text-lg)", fontWeight: 600 }}>{title}</div>
      <div style={{ flex: 1 }}/>
      <div style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", fontFamily: "var(--mp-font-mono)" }}>{count}</div>
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <SLFilterBar query={empty === "search" ? "audit log" : ""}/>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <div style={{ flex: 1, overflow: "auto" }}>
      {empty === "search" ? (
        <SLEmpty icon="search" title="No meetings match" body="Try a different search, or clear the filters." action="Clear filters"/>
      ) : empty === "needs-none" ? (
        <SLEmpty icon="check-circle" title="Nothing needs you" body="Failed, unpublished and paste-pending meetings show up here."/>
      ) : scope === "needs" ? (
        <SLNeedsList/>
      ) : (
        <SLAllList selectedId={selectedId} multiSelect={multiSelect} checkedIds={checkedIds}/>
      )}
    </div>
    {multiSelect && <SLSelectionFooter count={checkedIds.length}/>}
  </div>
);

const SLFilterBar = ({ query }) => (
  <div style={{ height: 38, flexShrink: 0, display: "flex", alignItems: "center", gap: 8, padding: "0 14px" }}>
    <div style={{
      flex: 1, minWidth: 0, display: "flex", alignItems: "center", gap: 6, height: 25, padding: "0 8px",
      borderRadius: "var(--mp-radius-sm)", border: "0.5px solid var(--mp-border)",
      background: "color-mix(in srgb, transparent 95%, var(--mp-ink-500))",
    }}>
      <span style={{ color: "var(--mp-fg-subtle)", display: "flex", flexShrink: 0 }}><Icon name="search" size={11}/></span>
      <span style={{
        fontSize: "var(--mp-text-sm)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
        color: query ? "var(--mp-fg)" : "var(--mp-fg-subtle)",
      }}>{query || "Search titles, summaries, decisions…"}</span>
    </div>
    <SLFilterChip label="Workflow"/>
    <SLFilterChip label="Status"/>
    <SLFilterChip label="App"/>
    <SLFilterChip label="Date"/>
  </div>
);

const SLFilterChip = ({ label }) => (
  <span style={{
    display: "inline-flex", alignItems: "center", gap: 4, height: 22, padding: "0 8px",
    borderRadius: "var(--mp-radius-sm)", border: "0.5px solid var(--mp-border)",
    fontSize: "var(--mp-text-xs)", fontWeight: 500, color: "var(--mp-fg-muted)", whiteSpace: "nowrap", cursor: "pointer",
  }}>
    {label}<Icon name="chevron-down" size={8}/>
  </span>
);

const SLGroupHeader = ({ children }) => (
  <div style={{ fontSize: "var(--mp-text-xs)", fontWeight: 600, color: "var(--mp-fg-subtle)", padding: "10px 16px 4px" }}>{children}</div>
);

// The default scope: a quiet "In progress" pinned block (live recording +
// processing), then chronological groups. Attention items (failed / unpublished /
// paste-pending) roll up into the rail "Needs you" scope, but still appear here.
const SLAllList = ({ selectedId, multiSelect, checkedIds }) => {
  const groups = [
    { header: "Today",     ids: ["release", "qms"] },
    { header: "Yesterday", ids: ["helix", "backlog"] },
    { header: "This week", ids: ["vendor", "marko", "board"] },
  ];
  const rowProps = (id) => ({ m: SL_MEETINGS[id], selected: id === selectedId, multiSelect, checked: checkedIds.includes(id) });
  return (
    <div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "10px 16px 4px" }}>
        <span style={{ fontSize: "var(--mp-text-xs)", fontWeight: 600, color: "var(--mp-fg-subtle)" }}>In progress</span>
        <span style={{ flex: 1, height: 1, background: "var(--mp-border-faint)" }}/>
      </div>
      <SLRow {...rowProps("weekly")}/>
      <SLRow {...rowProps("standup")}/>
      {groups.map((g) => (
        <div key={g.header}>
          <SLGroupHeader>{g.header}</SLGroupHeader>
          {g.ids.map((id) => <SLRow key={id} {...rowProps(id)}/>)}
        </div>
      ))}
    </div>
  );
};

// "Needs you" scope: only the items that want an action, each with its inline fix.
const SLNeedsList = () => (
  <div>
    <SLRow m={SL_MEETINGS.marko}  action="Retry"/>
    <SLRow m={SL_MEETINGS.board}  action="Reveal"/>
    <SLRow m={SL_MEETINGS.vendor} action="Publish"/>
  </div>
);

const SLRow = ({ m, selected, multiSelect, checked, action }) => {
  const recording = m.status === "recording";
  return (
    <div style={{
      position: "relative", height: 46, display: "flex", alignItems: "center", gap: 10,
      padding: "0 14px", cursor: "pointer",
      background: (selected || (multiSelect && checked)) ? "var(--mp-signal-100)" : "transparent",
    }}>
      {multiSelect && <SLCheck checked={checked}/>}
      <SLRowGlyph source={m.source} nda={m.nda}/>
      <div style={{ minWidth: 0, display: "flex", flexDirection: "column", gap: 1, flex: 1 }}>
        <div style={{
          fontSize: "var(--mp-text-base)", fontWeight: 500, whiteSpace: "nowrap",
          overflow: "hidden", textOverflow: "ellipsis", color: "var(--mp-fg)",
        }}>{m.title}</div>
        <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", whiteSpace: "nowrap" }}>
          <span>{m.source}</span>
          <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
          <span style={{ fontFamily: "var(--mp-font-mono)" }}>{m.dur}</span>
          <SLWorkflowChip wf={m.wf}/>
        </div>
      </div>
      {action && <SLInlineBtn primary={action === "Publish"}>{action}</SLInlineBtn>}
      {m.status === "processing"
        ? <SLProcessing stage={m.stage} elapsed={m.elapsed}/>
        : <SLStatusPill status={m.status}/>}
      <span style={{ minWidth: 92, textAlign: "right", fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-muted)", whiteSpace: "nowrap" }}>{recording ? "now" : m.when}</span>
    </div>
  );
};

const SLCheck = ({ checked }) => (
  <span style={{
    width: 16, height: 16, flexShrink: 0, borderRadius: "var(--mp-radius-xs)",
    display: "flex", alignItems: "center", justifyContent: "center",
    border: checked ? "none" : "1px solid var(--mp-border-strong)",
    background: checked ? "var(--mp-signal-600)" : "transparent",
    color: "var(--mp-fg-on-signal)",
  }}>
    {checked && <Icon name="check-circle" size={11}/>}
  </span>
);

const SLRowGlyph = ({ source, nda }) => {
  const box = { width: 22, height: 22, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 };
  if (nda) return <span style={{ ...box, color: "var(--mp-fg-subtle)" }}><Icon name="lock" size={14}/></span>;
  if (SL_APP_GLYPH[source]) return <span style={box}><img src={SL_APP_GLYPH[source]} width={22} height={22} alt="" style={{ borderRadius: 5 }}/></span>;
  return <span style={{ ...box, color: "var(--mp-fg-muted)" }}><Icon name="waveform-circle" size={18}/></span>;
};

const SLInlineBtn = ({ children, primary }) => (
  <button style={{
    height: 20, padding: "0 9px", borderRadius: "var(--mp-radius-xs)", fontSize: "var(--mp-text-xs)",
    fontFamily: "inherit", fontWeight: 500, cursor: "pointer",
    border: primary ? "none" : "0.5px solid var(--mp-border-strong)",
    background: primary ? "var(--mp-signal-600)" : "var(--mp-bg-raised)",
    color: primary ? "var(--mp-fg-on-signal)" : "var(--mp-fg)",
  }}>{children}</button>
);

const SLProcessing = ({ stage, elapsed }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
    <span style={{
      width: 12, height: 12, borderRadius: "var(--mp-radius-full)",
      border: "1.5px solid var(--mp-border-faint)", borderTopColor: "var(--mp-signal-500)",
      animation: "slSpin 0.8s linear infinite",
    }}/>
    <span style={{ fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)" }}>{stage} {elapsed}</span>
  </div>
);

const SLStatusPill = ({ status }) => {
  const s = SL_STATUS[status] || SL_STATUS.local;
  let marker;
  if (s.icon) marker = <span style={{ display: "flex", color: s.tint }}><Icon name={s.icon} size={11}/></span>;
  else marker = <span style={{ width: 6, height: 6, borderRadius: "var(--mp-radius-full)", background: s.tint, animation: s.pulse ? "slPulse 1.6s ease-in-out infinite" : "none" }}/>;
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 5, height: 19, padding: "0 8px",
      borderRadius: "var(--mp-radius-full)", border: "0.5px solid var(--mp-border-strong)",
      fontSize: "var(--mp-text-xs)", fontWeight: 500, color: s.tint, whiteSpace: "nowrap",
    }}>
      {marker}{s.label}
    </span>
  );
};

const SLWorkflowChip = ({ wf }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 18, padding: "0 7px", borderRadius: "var(--mp-radius-full)", background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
    <span style={{ width: 7, height: 7, borderRadius: "var(--mp-radius-full)", background: wf.dot }}/>
    <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-muted)" }}>{wf.name}</span>
  </span>
);

const SLSelectionFooter = ({ count }) => (
  <div style={{ height: 30, flexShrink: 0, borderTop: "1px solid var(--mp-border)", background: "var(--mp-bg-sunk)", display: "flex", alignItems: "center", padding: "0 14px", gap: 8, fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-muted)" }}>
    <span>{count} selected</span>
    <span style={{ flex: 1 }}/>
    <span style={{ color: "var(--mp-signal-600)", cursor: "pointer" }}>Select all</span>
    <span style={{ color: "var(--mp-fg-subtle)", cursor: "pointer" }}>Done</span>
  </div>
);

/* ====================================================================== detail */

const SLDetail = ({ id = "release", tab = "summary", setTab, mode = "read" }) => {
  const m = SL_MEETINGS[id];
  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0, background: "var(--mp-bg)" }}>
      <SLDetailHeader m={m} mode={mode}/>
      <SLTabStrip tab={tab} setTab={setTab} editing={mode === "edit"}/>
      <div style={{ height: 1, background: "var(--mp-border-faint)" }}/>
      <div style={{ flex: 1, overflow: "auto" }}>
        {tab === "summary" && mode === "read"      && <SLSummary/>}
        {tab === "summary" && mode === "edit"      && <SLEditForm/>}
        {tab === "summary" && mode === "editError" && <SLEditForm error/>}
        {tab === "summary" && mode === "reprocess" && <SLReprocess/>}
        {tab === "transcript" && <SLTranscript/>}
        {tab === "audio" && <SLAudio/>}
      </div>
    </div>
  );
};

const SLDetailHeader = ({ m, mode }) => (
  <div style={{ padding: "14px 16px 10px" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <SLWorkflowChip wf={m.wf}/>
      <div style={{ flex: 1 }}/>
      {mode === "edit" || mode === "editError" ? (
        <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", display: "inline-flex", alignItems: "center", gap: 5 }}>
          <Icon name="pencil" size={12}/> Editing summary
        </span>
      ) : (
        <React.Fragment>
          <SLPrimaryAction status={m.status}/>
          <button style={SL_ghostBtn} title="Open in Notion"><Icon name="external" size={15}/></button>
          <button style={SL_ghostBtn} title="Open in Obsidian"><Icon name="book" size={15}/></button>
          <button style={SL_ghostBtn} title="Reveal raw files in Finder"><Icon name="folder" size={15}/></button>
          <button style={SL_ghostBtn} title="More actions"><Icon name="more" size={16}/></button>
        </React.Fragment>
      )}
    </div>
    <div style={{ fontSize: "var(--mp-text-xl)", fontWeight: 600, marginTop: 8, letterSpacing: "var(--mp-tracking-snug)" }}>{m.title}</div>
    <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 6, fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", flexWrap: "wrap" }}>
      <span>Jun 16, 2026 at 11:02</span>
      <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
      <span style={{ fontFamily: "var(--mp-font-mono)" }}>{m.dur}</span>
      <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
      <span style={{ fontFamily: "var(--mp-font-mono)" }}>EN</span>
      <span style={{ color: "var(--mp-fg-faint)" }}>·</span>
      <span>{m.source}</span>
    </div>
    <SLProvenance kind={m.nda ? "local" : "cloud"}/>
    <SLPublishState status={m.status} nda={m.nda}/>
  </div>
);

// Re-publish is the payoff action: teal primary, and it is the same control across
// the surface. Hidden for NDA (handled by the publish-state line below instead).
const SLPrimaryAction = ({ status }) => {
  if (status === "failed") return <SLHeaderBtn icon="refresh" tone="danger">Retry publish</SLHeaderBtn>;
  if (status === "unpublished") return <SLHeaderBtn icon="external" primary>Publish</SLHeaderBtn>;
  if (status === "paste") return <SLHeaderBtn icon="folder">Reveal bundle</SLHeaderBtn>;
  if (status === "local") return null;
  return <SLHeaderBtn icon="refresh" primary>Re-publish</SLHeaderBtn>;
};

const SLHeaderBtn = ({ icon, children, primary, tone }) => (
  <button style={{
    display: "inline-flex", alignItems: "center", gap: 5, height: 26, padding: "0 10px",
    borderRadius: "var(--mp-radius-sm)", cursor: "pointer", fontFamily: "inherit",
    fontSize: "var(--mp-text-sm)", fontWeight: 500,
    border: primary ? "none" : "0.5px solid var(--mp-border-strong)",
    background: primary ? "var(--mp-signal-600)" : "var(--mp-bg-raised)",
    color: primary ? "var(--mp-fg-on-signal)" : (tone === "danger" ? "var(--mp-danger-600)" : "var(--mp-fg)"),
  }}>
    <Icon name={icon} size={13}/> {children}
  </button>
);

// FEAT6: quiet backend provenance. Grey, never celebrated, no sparkle.
const SLProvenance = ({ kind }) => {
  const label = kind === "local" ? "Summarized on-device, MLX" : "Summarized by Claude Opus 4.8, cloud";
  return (
    <div style={{ display: "inline-flex", alignItems: "center", gap: 5, marginTop: 6, fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-faint)" }}>
      <Icon name={kind === "local" ? "cpu" : "external"} size={11}/>
      <span>{label}</span>
    </div>
  );
};

const SLPublishState = ({ status, nda }) => {
  let icon, tint, text;
  if (nda)                         { icon = "lock";          tint = "var(--mp-fg-subtle)";  text = "Local only. Kept on this Mac by design."; }
  else if (status === "failed")    { icon = "alert-triangle"; tint = "var(--mp-danger-600)"; text = "Last publish to Notion failed."; }
  else if (status === "unpublished"){ icon = "alert";        tint = "var(--mp-warning-600)"; text = "Not published yet."; }
  else if (status === "paste")     { icon = "alert";         tint = "var(--mp-warning-600)"; text = "Too long for an automatic summary. The transcript bundle is ready to paste into Claude Code."; }
  else                             { icon = "check-circle";  tint = "var(--mp-success-600)"; text = "Published to Notion, Obsidian."; }
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 7, marginTop: 10, padding: "7px 10px",
      borderRadius: "var(--mp-radius-sm)", border: "0.5px solid var(--mp-border)",
      background: "var(--mp-bg-sunk)", fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-muted)",
    }}>
      <span style={{ color: tint, display: "flex", flexShrink: 0 }}><Icon name={icon} size={13}/></span>
      <span style={{ flex: 1 }}>{text}</span>
      {nda && <span style={{ color: "var(--mp-fg-subtle)", cursor: "pointer", whiteSpace: "nowrap" }}>Publish anyway…</span>}
    </div>
  );
};

const SLTabStrip = ({ tab, setTab, editing }) => (
  <div style={{ display: "flex", alignItems: "flex-end", padding: "0 16px", opacity: editing ? 0.4 : 1, pointerEvents: editing ? "none" : "auto" }}>
    {[["summary", "Summary"], ["transcript", "Transcript"], ["audio", "Audio"]].map(([id, label]) => {
      const active = tab === id;
      return (
        <button key={id} onClick={() => setTab && setTab(id)} style={{
          border: "none", background: "transparent", cursor: "pointer", fontFamily: "inherit",
          fontSize: "var(--mp-text-sm)", fontWeight: 500, padding: "0 16px 0 0",
          color: active ? "var(--mp-fg)" : "var(--mp-fg-muted)",
        }}>
          <div style={{ padding: "9px 0" }}>{label}</div>
          <div style={{ height: 2, borderRadius: 1, marginRight: 16, background: active ? "var(--mp-signal-600)" : "transparent" }}/>
        </button>
      );
    })}
  </div>
);

/* --------------------------------------------------------------- summary (read) */

const SLSummary = () => (
  <div style={{ maxWidth: 660, padding: 20, display: "flex", flexDirection: "column", gap: 22 }}>
    <SLSection icon="file-text" title="Summary">
      <SLBullets items={[
        "Release 3.2 cut moves to Friday once the validation review unblocks the remaining sign-off.",
        "Two flaky pipeline tests root-caused to clock skew on the staging runner.",
        "Customer-facing changelog draft to circulate before end of day.",
      ]}/>
    </SLSection>
    <SLSection icon="seal-check" title="Decisions">
      <SLBullets numbered items={[
        "Defer the audit-log refactor to 3.3.",
        "Keep the staging runner pinned until the clock fix lands.",
      ]}/>
    </SLSection>
    <SLSection icon="checklist" title="Action items">
      <SLActionItem task="Land the runner-clock fix and re-enable the skipped tests." owner="Anya" due="today" confidence="high"/>
      <SLActionItem task="Send the Notion changelog draft for review." owner="Marko" due="today"/>
    </SLSection>
    <SLSection icon="help-bubble" title="Open questions">
      <SLBullets items={["Does the 3.2 cut need a second validation pass after the runner fix?"]}/>
    </SLSection>
    <SLSection icon="users" title="Attendees">
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
        {["Anya", "Marko", "Priya", "You"].map((n) => (
          <span key={n} style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 22, padding: "0 8px", borderRadius: "var(--mp-radius-sm)", border: "0.5px solid var(--mp-border)", fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-muted)" }}>
            <Icon name="user" size={11}/> {n}
          </span>
        ))}
      </div>
    </SLSection>
    {/* FEAT7 entry point: quiet, lives at the foot of the reader. */}
    <SLReprocessBar/>
  </div>
);

const SLSection = ({ icon, title, children, right }) => (
  <div>
    <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}>
      <span style={{ color: "var(--mp-fg-subtle)", display: "flex" }}><Icon name={icon} size={14}/></span>
      <span style={{ fontSize: "var(--mp-text-base)", fontWeight: 600 }}>{title}</span>
      <span style={{ flex: 1 }}/>
      {right}
    </div>
    {children}
  </div>
);

const SLBullets = ({ items, numbered }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
    {items.map((t, i) => (
      <div key={i} style={{ display: "flex", gap: 8, fontSize: "var(--mp-text-base)", lineHeight: "var(--mp-leading-normal)" }}>
        <span style={{ minWidth: 16, color: "var(--mp-fg-faint)", fontFamily: numbered ? "var(--mp-font-mono)" : "inherit" }}>{numbered ? `${i + 1}.` : "•"}</span>
        <span>{t}</span>
      </div>
    ))}
  </div>
);

const SLActionItem = ({ task, owner, due, confidence }) => (
  <div style={{ marginBottom: 10 }}>
    <div style={{ display: "flex", gap: 8, fontSize: "var(--mp-text-base)", lineHeight: "var(--mp-leading-normal)" }}>
      <span style={{ color: "var(--mp-fg-faint)", marginTop: 2, display: "flex" }}><Icon name="circle" size={13}/></span>
      <span>{task}</span>
    </div>
    <div style={{ display: "flex", gap: 6, marginLeft: 21, marginTop: 4 }}>
      {owner && <SLMiniChip icon="user" tint="var(--mp-signal-600)">{owner}</SLMiniChip>}
      {due && <SLMiniChip icon="calendar" tint="var(--mp-warning-600)">{due}</SLMiniChip>}
      {confidence === "high" && <SLMiniChip icon="gauge" tint="var(--mp-success-600)">high</SLMiniChip>}
    </div>
  </div>
);

const SLMiniChip = ({ icon, tint, children }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, height: 18, padding: "0 6px", borderRadius: "var(--mp-radius-xs)", fontSize: "var(--mp-text-xs)", color: tint, background: "color-mix(in srgb, transparent 88%, currentColor)" }}>
    <Icon name={icon} size={10}/> {children}
  </span>
);

const SLReprocessBar = () => (
  <div style={{
    display: "flex", alignItems: "center", gap: 8, marginTop: 4, padding: "10px 12px",
    borderRadius: "var(--mp-radius-sm)", border: "0.5px dashed var(--mp-border-strong)", background: "transparent",
  }}>
    <span style={{ color: "var(--mp-fg-subtle)", display: "flex" }}><Icon name="refresh" size={14}/></span>
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontSize: "var(--mp-text-sm)", fontWeight: 500 }}>Not quite right?</div>
      <div style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)" }}>Edit the prompt and reprocess. You can compare before keeping it.</div>
    </div>
    <button style={{
      height: 24, padding: "0 10px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit",
      fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer",
      border: "0.5px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
    }}>Reprocess…</button>
  </div>
);

/* ----------------------------------------------------------------- summary (edit) */

// First-class structured editing (surfaced from "..." today). Fixes the shipped
// rough edges: the read<->edit swap crossfades (slFade, 180ms) rather than hard-
// cutting; inline markup renders as formatting, not literal asterisks; and a failed
// save is shown inline (never swallowed into a fake success).
const SLEditForm = ({ error }) => (
  <div style={{ maxWidth: 660, padding: 20, display: "flex", flexDirection: "column", gap: 16, animation: "slFade var(--mp-dur-base) var(--mp-ease-out)" }}>
    {error && (
      <div style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "9px 11px", borderRadius: "var(--mp-radius-sm)", background: "var(--mp-danger-100)", border: "0.5px solid color-mix(in srgb, var(--mp-danger-600) 28%, transparent)" }}>
        <span style={{ color: "var(--mp-danger-600)", display: "flex", marginTop: 1 }}><Icon name="alert-triangle" size={14}/></span>
        <div style={{ flex: 1, fontSize: "var(--mp-text-sm)", color: "var(--mp-fg)" }}>
          <div style={{ fontWeight: 500 }}>Could not save to the summary file.</div>
          <div style={{ color: "var(--mp-fg-muted)", marginTop: 1 }}>Your edits are kept here. Check the file permissions and try again.</div>
        </div>
        <button style={{ height: 22, padding: "0 9px", borderRadius: "var(--mp-radius-xs)", fontFamily: "inherit", fontSize: "var(--mp-text-xs)", fontWeight: 500, cursor: "pointer", border: "none", background: "var(--mp-danger-600)", color: "#fff" }}>Try again</button>
      </div>
    )}
    <SLFieldLabel>Summary</SLFieldLabel>
    <SLTextField rows={3} focused markdown
      lines={[["Release 3.2 cut moves to ", ["b", "Friday"], " once validation unblocks sign-off."], ["Two flaky tests root-caused to clock skew on ", ["code", "staging-runner-2"], "."]]}/>
    <SLFieldLabel>Decisions</SLFieldLabel>
    <SLTextField rows={2}
      lines={[["Defer the audit-log refactor to 3.3."], ["Keep the staging runner pinned until the clock fix lands."]]}/>
    <SLFieldLabel>Action items</SLFieldLabel>
    <SLEditAction task="Land the runner-clock fix and re-enable the skipped tests." owner="Anya" due="today"/>
    <SLEditAction task="Send the Notion changelog draft for review." owner="Marko" due="today"/>
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 4 }}>
      <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-faint)" }}>Markdown supported. Saves to the summary sidecar.</span>
      <span style={{ flex: 1 }}/>
      <button style={{ height: 26, padding: "0 12px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "0.5px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)" }}>Cancel</button>
      <button style={{ height: 26, padding: "0 14px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "none", background: "var(--mp-signal-600)", color: "var(--mp-fg-on-signal)" }}>Save</button>
    </div>
  </div>
);

const SLFieldLabel = ({ children }) => (
  <div style={{ fontSize: "var(--mp-text-xs)", fontWeight: 600, color: "var(--mp-fg-muted)", letterSpacing: "var(--mp-tracking-wide)" }}>{children}</div>
);

// Renders inline markup as real formatting (bold / code), the fix for "literal
// asterisks in the field". A focused field shows the teal a11y focus ring.
const SLTextField = ({ lines, rows = 2, focused, markdown }) => (
  <div style={{
    minHeight: rows * 22 + 14, padding: "8px 10px", borderRadius: "var(--mp-radius-sm)",
    background: "var(--mp-bg-raised)",
    border: focused ? "1px solid var(--mp-signal-600)" : "1px solid var(--mp-border-strong)",
    boxShadow: focused ? "var(--mp-focus-ring)" : "none",
    fontSize: "var(--mp-text-base)", lineHeight: "var(--mp-leading-normal)",
    display: "flex", flexDirection: "column", gap: 4,
  }}>
    {lines.map((parts, i) => (
      <div key={i}>{parts.map((p, j) => {
        if (typeof p === "string") return <span key={j}>{p}</span>;
        const [kind, text] = p;
        if (kind === "b") return <strong key={j} style={{ fontWeight: 600 }}>{text}</strong>;
        if (kind === "code") return <code key={j} style={{ fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-sm)", background: "var(--mp-bg-sunk)", padding: "0 4px", borderRadius: "var(--mp-radius-xs)" }}>{text}</code>;
        return <span key={j}>{text}</span>;
      })}</div>
    ))}
  </div>
);

const SLEditAction = ({ task, owner, due }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "7px 10px", borderRadius: "var(--mp-radius-sm)", border: "1px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)" }}>
    <Icon name="circle" size={13}/>
    <span style={{ flex: 1, fontSize: "var(--mp-text-base)" }}>{task}</span>
    <SLMiniChip icon="user" tint="var(--mp-signal-600)">{owner}</SLMiniChip>
    <SLMiniChip icon="calendar" tint="var(--mp-warning-600)">{due}</SLMiniChip>
    <span style={{ color: "var(--mp-fg-faint)", display: "flex", cursor: "pointer" }}><Icon name="x" size={13}/></span>
  </div>
);

/* ------------------------------------------------------------ reprocess compare */

// FEAT7: edit the prompt, generate a candidate, compare side by side, then keep one.
const SLReprocess = () => (
  <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 12, height: "100%", animation: "slFade var(--mp-dur-base) var(--mp-ease-out)" }}>
    <SLFieldLabel>Prompt</SLFieldLabel>
    <div style={{ padding: "8px 10px", borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-raised)", border: "1px solid var(--mp-border-strong)", fontSize: "var(--mp-text-sm)", lineHeight: "var(--mp-leading-normal)", color: "var(--mp-fg-muted)" }}>
      Summarize this engineering meeting. Lead with decisions and their owners, then risks. Keep action items terse and assign each one.
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <SLProvenance kind="cloud"/>
      <span style={{ flex: 1 }}/>
      <button style={{ height: 26, padding: "0 12px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "none", background: "var(--mp-signal-600)", color: "var(--mp-fg-on-signal)", display: "inline-flex", alignItems: "center", gap: 5 }}>
        <Icon name="refresh" size={13}/> Generate candidate
      </button>
    </div>
    <div style={{ flex: 1, minHeight: 0, display: "flex", gap: 12 }}>
      <SLCompareCol title="Current" muted body={[
        "Cut moves to Friday once validation unblocks sign-off.",
        "Two flaky tests traced to staging clock skew.",
        "Changelog draft to circulate today.",
      ]}/>
      <SLCompareCol title="Candidate" accent body={[
        "Decision: ship 3.2 Friday, gated on the runner-clock fix landing first (owner: Anya).",
        "Risk: staging clock skew still flakes two tests; runner stays pinned until fixed.",
        "Action: Marko circulates the changelog draft before end of day.",
      ]}/>
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-faint)" }}>The candidate replaces the current summary only when you keep it.</span>
      <span style={{ flex: 1 }}/>
      <button style={{ height: 26, padding: "0 12px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "0.5px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)" }}>Keep current</button>
      <button style={{ height: 26, padding: "0 14px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "none", background: "var(--mp-signal-600)", color: "var(--mp-fg-on-signal)" }}>Use candidate</button>
    </div>
  </div>
);

const SLCompareCol = ({ title, body, accent, muted }) => (
  <div style={{
    flex: 1, minWidth: 0, borderRadius: "var(--mp-radius-md)", padding: 14, overflow: "auto",
    border: accent ? "1px solid color-mix(in srgb, var(--mp-signal-600) 45%, transparent)" : "1px solid var(--mp-border)",
    background: accent ? "var(--mp-signal-100)" : "var(--mp-bg-sunk)",
  }}>
    <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}>
      <span style={{ fontSize: "var(--mp-text-xs)", fontWeight: 600, letterSpacing: "var(--mp-tracking-wide)", textTransform: "uppercase", color: accent ? "var(--mp-signal-700)" : "var(--mp-fg-subtle)" }}>{title}</span>
    </div>
    <div style={{ display: "flex", flexDirection: "column", gap: 8, opacity: muted ? 0.75 : 1 }}>
      {body.map((t, i) => (
        <div key={i} style={{ display: "flex", gap: 8, fontSize: "var(--mp-text-sm)", lineHeight: "var(--mp-leading-normal)" }}>
          <span style={{ color: accent ? "var(--mp-signal-600)" : "var(--mp-fg-faint)" }}>•</span>
          <span>{t}</span>
        </div>
      ))}
    </div>
  </div>
);

/* -------------------------------------------------------------------- transcript */

const SL_TRANSCRIPT = [
  { sp: 0, name: "Anya",  t: "0:03", body: "Alright, let's start with the validation review. Where are we on the remaining sign-offs?" },
  { sp: 1, name: "Marko", t: "0:11", body: "Two left. The runner clock skew was the blocker on both flaky tests, so once that fix lands we should be green.", active: true },
  { sp: 0, name: "Anya",  t: "0:24", body: "Good. Can we move the 3.2 cut to Friday then?" },
  { sp: 2, name: "Priya", t: "0:31", body: "Friday works for me as long as the changelog draft goes out before end of day." },
  { sp: 1, name: "Marko", t: "0:40", body: "I'll send the changelog for review this afternoon." },
];

const SLTranscript = () => (
  <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
    <div style={{ flex: 1, overflow: "auto", padding: "10px 0" }}>
      <div style={{ fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-faint)", padding: "0 16px 6px", fontFamily: "var(--mp-font-mono)" }}>Language: en · 3 speakers</div>
      {SL_TRANSCRIPT.map((r, i) => (
        <div key={i} className="sl-tline" style={{
          position: "relative", display: "flex", gap: 10, padding: "7px 16px",
          background: r.active ? "var(--mp-signal-100)" : "transparent",
        }}>
          <span style={{ width: 8, height: 8, borderRadius: "var(--mp-radius-full)", background: SL_SPEAKER[r.sp], marginTop: 6, flexShrink: 0 }}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <span style={{ fontSize: "var(--mp-text-sm)", fontWeight: 600, color: SL_SPEAKER[r.sp] }}>{r.name}</span>
              <span style={{ fontSize: "var(--mp-text-sm)", fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-faint)" }}>{r.t}</span>
            </div>
            <div style={{ fontSize: "var(--mp-text-base)", lineHeight: "var(--mp-leading-normal)", marginTop: 1 }}>{r.body}</div>
          </div>
          {/* Honest per-line editing (TECH-UX12): hover reveals the pencil; right-click also works. No false "Edit transcript" menu item. */}
          <span className="sl-tedit" style={{ color: "var(--mp-fg-faint)", display: "flex", alignItems: "flex-start", marginTop: 2, cursor: "pointer", opacity: r.active ? 1 : 0 }}>
            <Icon name="pencil" size={13}/>
          </span>
        </div>
      ))}
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <SLPlayback at="9%" cur="0:24" total="47:21"/>
  </div>
);

const SLPlayback = ({ at, cur, total }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 16px", flexShrink: 0 }}>
    <span style={{ color: "var(--mp-fg-muted)", display: "flex", cursor: "pointer" }}><Icon name="play" size={14}/></span>
    <span style={{ fontSize: "var(--mp-text-sm)", fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)", width: 40, textAlign: "right" }}>{cur}</span>
    <div style={{ flex: 1, height: 4, borderRadius: "var(--mp-radius-full)", background: "var(--mp-ink-200)", position: "relative" }}>
      <div style={{ width: at, height: "100%", borderRadius: "var(--mp-radius-full)", background: "var(--mp-signal-600)" }}/>
      <div style={{ position: "absolute", left: at, top: -5, width: 14, height: 14, marginLeft: -7, borderRadius: "var(--mp-radius-full)", background: "var(--mp-bg-raised)", border: "1px solid var(--mp-signal-600)", boxShadow: "var(--mp-shadow-xs)" }}/>
    </div>
    <span style={{ fontSize: "var(--mp-text-sm)", fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>{total}</span>
  </div>
);

/* ------------------------------------------------------------------------- audio */

const SL_bars = (n, seed) => Array.from({ length: n }, (_, i) => {
  const v = Math.abs(Math.sin((i + seed) * 0.7) * 0.6 + Math.sin((i + seed) * 0.23) * 0.4);
  return 0.12 + v * 0.85;
});

const SLAudio = () => (
  <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
    <div style={{ flex: 1, position: "relative", display: "flex", flexDirection: "column", minHeight: 220 }}>
      <SLChannel label="Mic" tint="var(--mp-signal-600)" seed={2}/>
      <SLChannel label="System" tint="var(--mp-ink-500)" seed={9}/>
      {/* on-palette teal playhead */}
      <div style={{ position: "absolute", left: "40%", top: 0, bottom: 0, width: 1.5, background: "var(--mp-signal-600)" }}/>
      <div style={{ position: "absolute", left: "40%", top: 0, width: 9, height: 9, marginLeft: -4.5, borderRadius: "var(--mp-radius-full)", background: "var(--mp-signal-600)" }}/>
    </div>
    <div style={{ height: 1, background: "var(--mp-border)" }}/>
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 16px", flexShrink: 0 }}>
      <span style={{ color: "var(--mp-fg-muted)", display: "flex", cursor: "pointer" }}><Icon name="play" size={14}/></span>
      <span style={{ fontSize: "var(--mp-text-sm)", fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>18:56</span>
      <span style={{ color: "var(--mp-fg-faint)" }}>/</span>
      <span style={{ fontSize: "var(--mp-text-sm)", fontFamily: "var(--mp-font-mono)", color: "var(--mp-fg-muted)" }}>47:21</span>
      <div style={{ flex: 1 }}/>
      <SLSegmented options={["Mono", "Stereo"]} selected={1}/>
      <SLFilterChip label="Zoom: Fit"/>
    </div>
  </div>
);

const SLChannel = ({ label, tint, seed }) => (
  <div style={{ flex: 1, position: "relative", borderBottom: "0.5px solid var(--mp-border-faint)", background: "color-mix(in srgb, transparent 95%, " + tint + ")" }}>
    <div style={{ position: "absolute", top: 6, left: 12, fontSize: "var(--mp-text-sm)", fontWeight: 600, color: tint }}>{label}</div>
    <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", gap: 1, padding: "0 12px" }}>
      {SL_bars(160, seed).map((h, i) => (
        <div key={i} style={{ flex: 1, height: `${Math.round(h * 70)}%`, background: tint, opacity: 0.8, borderRadius: 0.5 }}/>
      ))}
    </div>
  </div>
);

const SLSegmented = ({ options, selected }) => (
  <span style={{ display: "inline-flex", padding: 2, borderRadius: "var(--mp-radius-sm)", background: "var(--mp-bg-sunk)", border: "0.5px solid var(--mp-border)" }}>
    {options.map((o, i) => (
      <span key={o} style={{
        fontSize: "var(--mp-text-xs)", padding: "2px 8px", borderRadius: "var(--mp-radius-xs)", cursor: "pointer",
        background: i === selected ? "var(--mp-bg-raised)" : "transparent",
        color: i === selected ? "var(--mp-fg)" : "var(--mp-fg-muted)",
        boxShadow: i === selected ? "var(--mp-shadow-xs)" : "none",
      }}>{o}</span>
    ))}
  </span>
);

/* ============================================================= batch + empties */

const SLBatchPane = ({ count = 3 }) => (
  <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0, background: "var(--mp-bg)", padding: 24 }}>
    <div style={{ maxWidth: 460, margin: "0 auto", width: "100%", display: "flex", flexDirection: "column", gap: 18, paddingTop: 24 }}>
      <div>
        <div style={{ fontSize: "var(--mp-text-xl)", fontWeight: 600 }}>{count} meetings selected</div>
        <div style={{ fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-subtle)", marginTop: 4 }}>2 published, 1 not published. Workflows: Engineering, Client work.</div>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <SLBatchAction icon="refresh" title="Re-publish all" sub="Send each to its configured sinks again." primary/>
        <SLBatchAction icon="tag" title="Change workflow…" sub="Move the selection to one workflow."/>
        <SLBatchAction icon="external" title="Open all in Notion" sub="Skips the meeting kept local only."/>
        <SLBatchAction icon="trash" title="Delete…" sub="Removes audio, transcript and summary from this Mac." danger/>
      </div>
    </div>
  </div>
);

const SLBatchAction = ({ icon, title, sub, primary, danger }) => {
  const tint = danger ? "var(--mp-danger-600)" : (primary ? "var(--mp-signal-600)" : "var(--mp-fg-muted)");
  return (
    <button style={{
      display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
      padding: "11px 14px", borderRadius: "var(--mp-radius-md)", cursor: "pointer", fontFamily: "inherit",
      border: "1px solid " + (danger ? "color-mix(in srgb, var(--mp-danger-600) 24%, transparent)" : "var(--mp-border)"),
      background: "var(--mp-bg-raised)", color: "var(--mp-fg)",
    }}>
      <span style={{ width: 30, height: 30, borderRadius: "var(--mp-radius-sm)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, color: tint, background: "color-mix(in srgb, transparent 90%, currentColor)" }}>
        <Icon name={icon} size={15}/>
      </span>
      <span style={{ flex: 1 }}>
        <span style={{ display: "block", fontSize: "var(--mp-text-base)", fontWeight: 500, color: danger ? "var(--mp-danger-600)" : "var(--mp-fg)" }}>{title}</span>
        <span style={{ display: "block", fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", marginTop: 1 }}>{sub}</span>
      </span>
      <Icon name="chevron-right" size={14}/>
    </button>
  );
};

const SLEmpty = ({ icon, title, body, action }) => (
  <div style={{ height: "100%", minHeight: 280, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", textAlign: "center", padding: "40px 32px", gap: 4 }}>
    <span style={{ color: "var(--mp-fg-faint)", marginBottom: 6, display: "flex" }}><Icon name={icon} size={26}/></span>
    <div style={{ fontSize: "var(--mp-text-md)", fontWeight: 600 }}>{title}</div>
    <div style={{ fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-subtle)", maxWidth: 320, lineHeight: "var(--mp-leading-normal)" }}>{body}</div>
    {action && <button style={{ marginTop: 10, height: 26, padding: "0 12px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "0.5px solid var(--mp-border-strong)", background: "var(--mp-bg-raised)", color: "var(--mp-fg)" }}>{action}</button>}
  </div>
);

// First-run: the whole window teaches what the Library is for. Quiet, no illustration clutter.
const SLEmptyLibrary = () => (
  <div style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", textAlign: "center", gap: 6, padding: 40, background: "var(--mp-bg)" }}>
    <span style={{ color: "var(--mp-fg-faint)", marginBottom: 8, display: "flex" }}><Icon name="waveform-circle" size={40}/></span>
    <div style={{ fontSize: "var(--mp-text-lg)", fontWeight: 600 }}>No meetings yet</div>
    <div style={{ fontSize: "var(--mp-text-base)", color: "var(--mp-fg-subtle)", maxWidth: 380, lineHeight: "var(--mp-leading-normal)" }}>
      Meetings appear here after you record one. meeting-pipe detects calls in the background, or you can start one yourself.
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 14 }}>
      <button style={{ height: 28, padding: "0 14px", borderRadius: "var(--mp-radius-sm)", fontFamily: "inherit", fontSize: "var(--mp-text-sm)", fontWeight: 500, cursor: "pointer", border: "none", background: "var(--mp-signal-600)", color: "var(--mp-fg-on-signal)", display: "inline-flex", alignItems: "center", gap: 6 }}>
        <span style={{ width: 8, height: 8, borderRadius: "var(--mp-radius-full)", background: "var(--mp-fg-on-signal)" }}/> Record now
      </button>
      <span style={{ fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-subtle)" }}>or press</span>
      <span className="mp-kbd">⌃⌥M</span>
    </div>
  </div>
);

/* ===================================================================== gallery */

const SLGalleryLabel = ({ children, sub }) => (
  <div style={{ display: "flex", alignItems: "baseline", gap: 8, margin: "26px 2px 10px" }}>
    <span style={{ fontSize: "var(--mp-text-sm)", fontWeight: 600, color: "var(--mp-fg)" }}>{children}</span>
    {sub && <span style={{ fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)" }}>{sub}</span>}
  </div>
);

const SLDetailCrop = ({ w = 552, h = 560, bg = "var(--mp-bg)", children }) => (
  <div style={{ width: w, height: h, border: "1px solid var(--mp-border)", borderRadius: "var(--mp-radius-md)", overflow: "hidden", display: "flex", flexDirection: "column", background: bg, boxShadow: "var(--mp-shadow-sm)" }}>{children}</div>
);

const SLListCrop = ({ children }) => (
  <div style={{ width: 440, height: 520, border: "1px solid var(--mp-border)", borderRadius: "var(--mp-radius-md)", overflow: "hidden", display: "flex", boxShadow: "var(--mp-shadow-sm)" }}>{children}</div>
);

const SummaryLibrary = () => {
  const [tab, setTab] = React.useState("summary");
  return (
    <div style={{ fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)" }}>
      <style>{`
        @keyframes slPulse { 0%,100%{opacity:1} 50%{opacity:.35} }
        @keyframes slSpin  { to { transform: rotate(360deg) } }
        @keyframes slFade  { from { opacity: 0 } to { opacity: 1 } }
        .sl-tline:hover { background: var(--mp-bg-sunk) !important; }
        .sl-tline:hover .sl-tedit { opacity: 1 !important; }
        @media (prefers-reduced-motion: reduce) {
          [style*="slPulse"], [style*="slSpin"], [style*="slFade"] { animation: none !important; }
        }
      `}</style>

      <SLGalleryLabel sub="live window · click the tabs">Library · default (Summary)</SLGalleryLabel>
      <SLWindow>
        <SLToolbar recording/>
        <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
          <SLSidebar activeScope="all"/>
          <SLList title="All meetings" count="42 meetings" selectedId="release"/>
          <SLDetail id="release" tab={tab} setTab={setTab} mode="read"/>
        </div>
      </SLWindow>

      <SLGalleryLabel sub="the third column, one mode each">Reader modes</SLGalleryLabel>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 16 }}>
        <div>
          <div style={SL_cropCap}>Transcript · per-line edit on hover</div>
          <SLDetailCrop><SLDetail id="release" tab="transcript" mode="read" setTab={() => {}}/></SLDetailCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Audio · two channels, teal playhead</div>
          <SLDetailCrop><SLDetail id="release" tab="audio" mode="read" setTab={() => {}}/></SLDetailCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Edit summary · first-class, markup renders</div>
          <SLDetailCrop><SLDetail id="release" tab="summary" mode="edit" setTab={() => {}}/></SLDetailCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Edit summary · save failure surfaced</div>
          <SLDetailCrop><SLDetail id="release" tab="summary" mode="editError" setTab={() => {}}/></SLDetailCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Reprocess · edit prompt, compare candidate</div>
          <SLDetailCrop w={620}><SLDetail id="release" tab="summary" mode="reprocess" setTab={() => {}}/></SLDetailCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Multi-select · batch actions replace the reader</div>
          <SLDetailCrop><SLBatchPane count={3}/></SLDetailCrop>
        </div>
      </div>

      <SLGalleryLabel sub="the list column">Triage states</SLGalleryLabel>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 16 }}>
        <div>
          <div style={SL_cropCap}>Needs you · each item carries its fix</div>
          <SLListCrop><SLList title="Needs you" count="3 meetings" scope="needs"/></SLListCrop>
        </div>
        <div>
          <div style={SL_cropCap}>Multi-select · checkboxes + footer</div>
          <SLListCrop><SLList title="All meetings" count="42 meetings" multiSelect checkedIds={["release", "backlog", "vendor"]}/></SLListCrop>
        </div>
        <div>
          <div style={SL_cropCap}>No search results</div>
          <SLListCrop><SLList title="All meetings" count="0 of 42" empty="search"/></SLListCrop>
        </div>
      </div>

      <SLGalleryLabel sub="first run, before any meeting exists">Empty Library</SLGalleryLabel>
      <SLWindow h={520}>
        <SLToolbar recording={false}/>
        <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
          <SLSidebar activeScope="all" firstRun/>
          <SLEmptyLibrary/>
        </div>
      </SLWindow>

      <SLGalleryLabel sub="below the width threshold the rail collapses to a 2-pane">Narrow · rail collapsed</SLGalleryLabel>
      <SLWindow w={840} h={520}>
        <SLToolbar recording railCollapsed/>
        <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
          <SLList title="All meetings" count="42" selectedId="release"/>
          <SLDetail id="release" tab="summary" mode="read" setTab={() => {}}/>
        </div>
      </SLWindow>
    </div>
  );
};

const SL_cropCap = { fontSize: "var(--mp-text-xs)", color: "var(--mp-fg-subtle)", margin: "0 2px 6px" };

window.SummaryLibrary = SummaryLibrary;
