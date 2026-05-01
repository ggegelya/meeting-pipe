// SummaryLibrary — anticipated surface (no code yet).
// Browse local meeting recordings + their summaries; re-publish, search.
const SummaryLibrary = () => (
  <div style={{
    width: 880, height: 560, background: "var(--mp-bg)", display: "flex",
    fontFamily: "var(--mp-font-sans)", color: "var(--mp-fg)",
    border: "1px solid var(--mp-border)", borderRadius: 10, overflow: "hidden",
    boxShadow: "var(--mp-shadow-lg)",
  }}>
    {/* Sidebar */}
    <div style={{ width: 220, background: "var(--mp-bg-sunk)", borderRight: "1px solid var(--mp-border)", padding: "16px 10px", display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "0 6px" }}>
        <Icon name="logomark" size={20}/>
        <span style={{ fontWeight: 600, fontSize: 14 }}>Meeting Pipe</span>
      </div>
      <div style={{ position: "relative" }}>
        <input placeholder="Search meetings" style={{ width: "100%", height: 26, padding: "0 8px 0 26px", border: "1px solid var(--mp-border-strong)", borderRadius: 6, fontSize: 12, fontFamily: "inherit", background: "var(--mp-bg-raised)" }}/>
        <span style={{ position: "absolute", left: 7, top: 5, color: "var(--mp-fg-subtle)" }}><Icon name="search" size={14}/></span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
        <SidebarItem icon="file-text" label="All meetings" count={42} active/>
        <SidebarItem icon="check-circle" label="Published" count={36}/>
        <SidebarItem icon="alert" label="Ready for manual" count={4}/>
        <SidebarItem icon="lock" label="Regulated" count={2}/>
      </div>
      <div style={{ marginTop: "auto", fontSize: 11, color: "var(--mp-fg-subtle)", padding: "0 6px" }}>
        2.4 GB · ~/Documents/Meetings
      </div>
    </div>
    {/* List + detail */}
    <div style={{ width: 280, borderRight: "1px solid var(--mp-border)", display: "flex", flexDirection: "column" }}>
      <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--mp-border)" }}>
        <div style={{ fontSize: 16, fontWeight: 600 }}>All meetings</div>
        <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2 }}>42 recordings</div>
      </div>
      <div style={{ flex: 1, overflow: "auto" }}>
        {[
          { date: "Today · 14:30", title: "Validation review — release 3.2", source: "Zoom", dur: "00:47:21", state: "published" },
          { date: "Today · 10:00", title: "Standup", source: "Slack huddle", dur: "00:18:04", state: "published", active: true },
          { date: "Yesterday · 16:30", title: "Customer call — Helix Diagnostics", source: "Teams", dur: "01:12:48", state: "manual" },
          { date: "Yesterday · 09:30", title: "Backlog refinement", source: "Meet", dur: "00:34:12", state: "published" },
          { date: "Mon · 15:00", title: "QMS audit prep", source: "Zoom", dur: "00:55:00", state: "regulated" },
        ].map((m, i) => <ListItem key={i} {...m}/>)}
      </div>
    </div>
    <div style={{ flex: 1, padding: 24, overflow: "auto" }}>
      <DetailView/>
    </div>
  </div>
);

const SidebarItem = ({ icon, label, count, active }) => (
  <div style={{
    display: "flex", alignItems: "center", gap: 8, padding: "5px 8px", borderRadius: 6,
    background: active ? "var(--mp-signal-600)" : "transparent",
    color: active ? "#fff" : "var(--mp-fg)",
    fontSize: 13, cursor: "pointer",
  }}>
    <Icon name={icon} size={14}/>
    <span style={{ flex: 1 }}>{label}</span>
    <span style={{ fontSize: 11, opacity: active ? 0.85 : 0.55 }}>{count}</span>
  </div>
);

const ListItem = ({ date, title, source, dur, state, active }) => (
  <div style={{
    padding: "10px 16px",
    borderBottom: "1px solid var(--mp-border-faint)",
    background: active ? "var(--mp-signal-100)" : "transparent",
    cursor: "pointer",
  }}>
    <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)" }}>{date}</div>
    <div style={{ fontSize: 13, fontWeight: 500, marginTop: 2 }}>{title}</div>
    <div style={{ display: "flex", gap: 8, marginTop: 4, fontSize: 11, color: "var(--mp-fg-muted)" }}>
      <span>{source}</span>
      <span>·</span>
      <span style={{ fontFamily: "var(--mp-font-mono)" }}>{dur}</span>
      {state === "manual" && <span style={{ marginLeft: "auto", color: "var(--mp-warning-600)" }}>READY_FOR_MANUAL</span>}
      {state === "regulated" && <span style={{ marginLeft: "auto", color: "var(--mp-fg-subtle)" }}>local only</span>}
    </div>
  </div>
);

const DetailView = () => (
  <div>
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
      <div>
        <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", textTransform: "uppercase", letterSpacing: ".08em", fontWeight: 600 }}>Today · 10:00 · Slack huddle · 18:04</div>
        <div style={{ fontSize: 24, fontWeight: 600, marginTop: 4, fontFamily: "var(--mp-font-display)", letterSpacing: "-0.02em" }}>Standup</div>
      </div>
      <button style={{ height: 28, padding: "0 12px", background: "var(--mp-signal-600)", color: "#fff", border: "none", borderRadius: 6, fontSize: 13, fontWeight: 500, cursor: "pointer", display: "flex", alignItems: "center", gap: 6, fontFamily: "inherit" }}>
        <Icon name="external" size={14}/> Open in Notion
      </button>
    </div>

    <div style={{ display: "flex", gap: 6, marginTop: 12, flexWrap: "wrap" }}>
      <Pill state="success">Published</Pill>
      <Pill>3 attendees</Pill>
      <Pill>en</Pill>
      <Pill>2 actions</Pill>
    </div>

    <Section title="Summary">
      <ul style={{ margin: 0, paddingLeft: 18, color: "var(--mp-fg)", fontSize: 13, lineHeight: 1.55 }}>
        <li>Release 3.2 cut moved to Friday after the validation review unblocks.</li>
        <li>Two flaky pipeline tests root-caused to a clock skew on the staging runner.</li>
        <li>Customer-facing changelog draft to circulate before EOD.</li>
      </ul>
    </Section>

    <Section title="Action items">
      <Action owner="Anya" task="Land the runner-clock fix and re-enable the skipped tests." due="today"/>
      <Action owner="Marko" task="Send Notion changelog draft for review." due="today" confidence="medium"/>
    </Section>

    <Section title="Decisions">
      <ul style={{ margin: 0, paddingLeft: 18, color: "var(--mp-fg)", fontSize: 13, lineHeight: 1.55 }}>
        <li>Defer the audit-log refactor to 3.3.</li>
      </ul>
    </Section>

    <Section title="Files" subtle>
      <FileRow icon="file-text" name="20260430-1000.md" hint="transcript · 14 KB"/>
      <FileRow icon="file-text" name="20260430-1000.summary.md" hint="summary · 2.1 KB"/>
      <FileRow icon="play" name="20260430-1000.wav" hint="18:04 · 16 kHz mono · 34 MB"/>
    </Section>
  </div>
);

const Section = ({ title, children, subtle }) => (
  <div style={{ marginTop: 18 }}>
    <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", textTransform: "uppercase", letterSpacing: ".08em", fontWeight: 600, marginBottom: 6 }}>{title}</div>
    {children}
  </div>
);

const Pill = ({ children, state }) => {
  const colors = state === "success"
    ? { bg: "var(--mp-success-100)", fg: "var(--mp-success-600)", bd: "rgba(31,143,78,0.25)" }
    : { bg: "var(--mp-ink-100)", fg: "var(--mp-fg-muted)", bd: "var(--mp-border)" };
  return <span style={{ height: 20, padding: "0 8px", borderRadius: 999, background: colors.bg, color: colors.fg, border: `1px solid ${colors.bd}`, fontSize: 11, fontWeight: 500, display: "inline-flex", alignItems: "center" }}>{children}</span>;
};

const Action = ({ owner, task, due, confidence = "high" }) => (
  <div style={{ display: "flex", gap: 10, padding: "8px 0", borderBottom: "1px solid var(--mp-border-faint)" }}>
    <div style={{ width: 22, height: 22, borderRadius: "50%", background: "var(--mp-ink-100)", color: "var(--mp-fg)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 11, fontWeight: 600, flexShrink: 0 }}>
      {owner[0]}
    </div>
    <div style={{ flex: 1 }}>
      <div style={{ fontSize: 13 }}><span style={{ fontWeight: 500 }}>{owner}</span> — {task}</div>
      <div style={{ fontSize: 11, color: "var(--mp-fg-subtle)", marginTop: 2, display: "flex", gap: 8 }}>
        <span>{due}</span>
        {confidence !== "high" && <span>· confidence: {confidence}</span>}
      </div>
    </div>
  </div>
);

const FileRow = ({ icon, name, hint }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 8px", borderRadius: 6, fontSize: 12, color: "var(--mp-fg)", cursor: "pointer" }}>
    <Icon name={icon} size={14}/>
    <span style={{ fontFamily: "var(--mp-font-mono)" }}>{name}</span>
    <span style={{ marginLeft: "auto", color: "var(--mp-fg-subtle)" }}>{hint}</span>
  </div>
);

window.SummaryLibrary = SummaryLibrary;
