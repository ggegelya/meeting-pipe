// Shared icon set for the Meeting Pipe macOS UI kit.
// Lucide-style: 1.5px stroke, rounded caps/joins, currentColor.
const Icon = ({ name, size = 16, ...rest }) => {
  const props = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.5, strokeLinecap: "round", strokeLinejoin: "round", ...rest };
  switch (name) {
    case "mic": return <svg {...props}><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><path d="M12 19v3"/></svg>;
    case "waveform": return <svg {...props}><path d="M3 12h2"/><path d="M7 8v8"/><path d="M11 4v16"/><path d="M15 8v8"/><path d="M19 12h2"/></svg>;
    case "settings": return <svg {...props}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>;
    case "folder": return <svg {...props}><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>;
    case "file-text": return <svg {...props}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>;
    case "monitor": return <svg {...props}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 8h18"/></svg>;
    case "check-circle": return <svg {...props}><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>;
    case "alert": return <svg {...props}><circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/></svg>;
    case "search": return <svg {...props}><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>;
    case "play": return <svg {...props}><polygon points="5 3 19 12 5 21 5 3" fill="currentColor"/></svg>;
    case "external": return <svg {...props}><path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>;
    case "chevron-right": return <svg {...props}><polyline points="9 18 15 12 9 6"/></svg>;
    case "lock": return <svg {...props}><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>;
    case "user": return <svg {...props}><circle cx="12" cy="12" r="10"/><circle cx="12" cy="10" r="3"/><path d="M7 20.6a8 8 0 0 1 10 0"/></svg>;
    case "logomark": return <svg width={size} height={size} viewBox="0 0 32 32" fill="none"><rect x="1" y="6" width="30" height="20" rx="6" stroke="currentColor" strokeWidth="2"/><rect x="6" y="13" width="2.5" height="6" rx="1.25" fill="currentColor"/><rect x="10" y="10" width="2.5" height="12" rx="1.25" fill="currentColor"/><rect x="14" y="8" width="2.5" height="16" rx="1.25" fill="currentColor"/><rect x="18" y="11" width="2.5" height="10" rx="1.25" fill="currentColor"/><rect x="22" y="14" width="2.5" height="4" rx="1.25" fill="currentColor"/><rect x="26" y="13" width="2.5" height="6" rx="1.25" fill="currentColor"/></svg>;
    default: return null;
  }
};

window.Icon = Icon;
