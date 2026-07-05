// MenuBarDropdown - recreates StatusBarController.swift's rebuildMenu()
// for the three primary states: idle, recording, prompting.
//
// DSN21 "Instrument" touches the recording/idle rows only: the coral recording
// dot is the recording colour (unchanged), and the mono filename is set in
// tabular numerals like every other capture-surface timecode. The dropdown has
// little else to instrument -- it is a native text menu, not a live surface.
const MenuBarDropdown = ({ state = "idle", source, file }) => {
  const wrapStyle = {
    width: 240,
    background: "var(--mp-hud-bg)",
    backdropFilter: "blur(24px) saturate(180%)",
    WebkitBackdropFilter: "blur(24px) saturate(180%)",
    border: "0.5px solid var(--mp-hud-stroke)",
    borderRadius: "var(--mp-radius-md)",
    boxShadow: "var(--mp-hud-shadow)",
    padding: 4,
    fontFamily: "var(--mp-font-sans)",
    fontSize: "var(--mp-text-base)",
    color: "var(--mp-fg)",
  };

  const header = {
    idle: "MeetingPipe: Idle",
    prompting: `MeetingPipe: Detected ${source?.displayName ?? "Zoom"}`,
    recording: "MeetingPipe: Recording",
    stopping: "MeetingPipe: Stopping…",
    handoff: "MeetingPipe: Processing…",
  }[state];

  return (
    <div style={wrapStyle}>
      <MenuItem header>{header}</MenuItem>
      <MenuSep/>
      {state === "idle" && <MenuItem>Start Recording</MenuItem>}
      {state === "recording" && <MenuItem><span style={{ color: "var(--mp-pulse-600)" }}>● </span>Stop Recording</MenuItem>}
      {state === "recording" && file && <MenuItem disabled mono>{file}</MenuItem>}
      <MenuSep/>
      <MenuItem>Open Logs Folder</MenuItem>
      <MenuItem>Open Recordings Folder</MenuItem>
      <MenuSep/>
      <MenuItem shortcut="⌘,">Preferences…</MenuItem>
      <MenuSep/>
      <MenuItem shortcut="⌘Q">Quit MeetingPipe</MenuItem>
    </div>
  );
};

const MenuItem = ({ children, shortcut, header, disabled, mono }) => (
  <div style={{
    display: "flex", justifyContent: "space-between", alignItems: "center",
    padding: "4px 10px", borderRadius: 4,
    color: header || disabled ? "var(--mp-fg-subtle)" : "var(--mp-fg)",
    fontWeight: header ? 600 : 400,
    fontFamily: mono ? "var(--mp-font-mono)" : "inherit",
    fontVariantNumeric: mono ? "tabular-nums" : "normal",
    fontSize: mono ? "var(--mp-text-sm)" : "var(--mp-text-base)",
    cursor: header || disabled ? "default" : "pointer",
  }}
  onMouseEnter={(e) => { if (!header && !disabled) { e.currentTarget.style.background = "var(--mp-signal-fill)"; e.currentTarget.style.color = "#fff"; } }}
  onMouseLeave={(e) => { if (!header && !disabled) { e.currentTarget.style.background = "transparent"; e.currentTarget.style.color = "var(--mp-fg)"; } }}>
    <span>{children}</span>
    {shortcut && <span style={{ opacity: 0.6, fontFamily: "var(--mp-font-mono)", fontSize: "var(--mp-text-sm)" }}>{shortcut}</span>}
  </div>
);

const MenuSep = () => <div style={{ height: 1, background: "var(--mp-border)", margin: "4px 6px" }}/>;

window.MenuBarDropdown = MenuBarDropdown;
