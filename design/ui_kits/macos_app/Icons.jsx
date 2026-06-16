// Shared icon set for the Meeting Pipe macOS UI kit.
// Lucide-style: 1.5px stroke, rounded caps/joins, currentColor.
// SF Symbols is canonical in the Swift app; these are the web stand-ins
// (see design/README.md "Specific symbols mapped").
const Icon = ({ name, size = 16, ...rest }) => {
  const props = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.5, strokeLinecap: "round", strokeLinejoin: "round", ...rest };
  switch (name) {
    case "mic": return <svg {...props}><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><path d="M12 19v3"/></svg>;
    case "waveform": return <svg {...props}><path d="M3 12h2"/><path d="M7 8v8"/><path d="M11 4v16"/><path d="M15 8v8"/><path d="M19 12h2"/></svg>;
    case "waveform-circle": return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M8 10v4"/><path d="M12 8.5v7"/><path d="M16 10v4"/></svg>;
    case "settings": return <svg {...props}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>;
    case "sliders": return <svg {...props}><line x1="21" x2="14" y1="4" y2="4"/><line x1="10" x2="3" y1="4" y2="4"/><line x1="21" x2="12" y1="12" y2="12"/><line x1="8" x2="3" y1="12" y2="12"/><line x1="21" x2="16" y1="20" y2="20"/><line x1="12" x2="3" y1="20" y2="20"/><line x1="14" x2="14" y1="2" y2="6"/><line x1="8" x2="8" y1="10" y2="14"/><line x1="16" x2="16" y1="18" y2="22"/></svg>;
    case "cpu": return <svg {...props}><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M15 2v2"/><path d="M15 20v2"/><path d="M2 15h2"/><path d="M2 9h2"/><path d="M20 15h2"/><path d="M20 9h2"/><path d="M9 2v2"/><path d="M9 20v2"/></svg>;
    case "plug": return <svg {...props}><path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/></svg>;
    case "shield": return <svg {...props}><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1Z"/><path d="m9 12 2 2 4-4"/></svg>;
    case "command": return <svg {...props}><path d="M15 6a3 3 0 1 0 3 3h-3V6Z"/><path d="M9 6a3 3 0 1 1-3 3h3V6Z"/><path d="M15 18a3 3 0 1 0 3-3h-3v3Z"/><path d="M9 18a3 3 0 1 1-3-3h3v3Z"/><rect x="9" y="9" width="6" height="6"/></svg>;
    case "folder": return <svg {...props}><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>;
    case "file-text": return <svg {...props}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>;
    case "monitor": return <svg {...props}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 8h18"/></svg>;
    case "book": return <svg {...props}><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>;
    case "check-circle": return <svg {...props}><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>;
    case "circle": return <svg {...props}><circle cx="12" cy="12" r="9"/></svg>;
    case "seal-check": return <svg {...props}><path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"/><path d="m9 12 2 2 4-4"/></svg>;
    case "checklist": return <svg {...props}><path d="m3 17 2 2 4-4"/><path d="m3 7 2 2 4-4"/><path d="M13 6h8"/><path d="M13 12h8"/><path d="M13 18h8"/></svg>;
    case "help-bubble": return <svg {...props}><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/></svg>;
    case "message": return <svg {...props}><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><path d="M7 9h10"/><path d="M7 13h6"/></svg>;
    case "users": return <svg {...props}><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>;
    case "alert": return <svg {...props}><circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/></svg>;
    case "alert-triangle": return <svg {...props}><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>;
    case "search": return <svg {...props}><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>;
    case "play": return <svg {...props}><polygon points="5 3 19 12 5 21 5 3" fill="currentColor"/></svg>;
    case "pause": return <svg {...props}><rect x="6" y="4" width="4" height="16" rx="1" fill="currentColor" stroke="none"/><rect x="14" y="4" width="4" height="16" rx="1" fill="currentColor" stroke="none"/></svg>;
    case "stop": return <svg {...props}><rect x="5" y="5" width="14" height="14" rx="2.5" fill="currentColor" stroke="none"/></svg>;
    case "external": return <svg {...props}><path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>;
    case "chevron-right": return <svg {...props}><polyline points="9 18 15 12 9 6"/></svg>;
    case "chevron-down": return <svg {...props}><polyline points="6 9 12 15 18 9"/></svg>;
    case "lock": return <svg {...props}><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>;
    case "user": return <svg {...props}><circle cx="12" cy="12" r="10"/><circle cx="12" cy="10" r="3"/><path d="M7 20.6a8 8 0 0 1 10 0"/></svg>;
    case "tray": return <svg {...props}><path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></svg>;
    case "calendar": return <svg {...props}><rect x="3" y="4" width="18" height="18" rx="2"/><path d="M3 10h18"/><path d="M8 2v4"/><path d="M16 2v4"/></svg>;
    case "tag": return <svg {...props}><path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r="1.25" fill="currentColor" stroke="none"/></svg>;
    case "plus": return <svg {...props}><path d="M5 12h14"/><path d="M12 5v14"/></svg>;
    case "pencil": return <svg {...props}><path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/></svg>;
    case "more": return <svg {...props}><circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.2" fill="currentColor" stroke="none"/><circle cx="5" cy="12" r="1.2" fill="currentColor" stroke="none"/></svg>;
    case "more-circle": return <svg {...props}><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="1.1" fill="currentColor" stroke="none"/><circle cx="16" cy="12" r="1.1" fill="currentColor" stroke="none"/><circle cx="8" cy="12" r="1.1" fill="currentColor" stroke="none"/></svg>;
    case "gauge": return <svg {...props}><path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/></svg>;
    case "eye": return <svg {...props}><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>;
    case "eye-off": return <svg {...props}><path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" x2="22" y1="2" y2="22"/></svg>;
    case "stethoscope": return <svg {...props}><path d="M11 2v2"/><path d="M5 2v2"/><path d="M5 3H4a2 2 0 0 0-2 2v4a6 6 0 0 0 12 0V5a2 2 0 0 0-2-2h-1"/><path d="M8 15a6 6 0 0 0 12 0v-3"/><circle cx="20" cy="10" r="2"/></svg>;
    case "refresh": return <svg {...props}><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M3 21v-5h5"/></svg>;
    case "bell": return <svg {...props}><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>;
    case "trash": return <svg {...props}><path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>;
    case "x": return <svg {...props}><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>;
    case "logomark": return <svg width={size} height={size} viewBox="0 0 32 32" fill="none"><rect x="1" y="6" width="30" height="20" rx="6" stroke="currentColor" strokeWidth="2"/><rect x="6" y="13" width="2.5" height="6" rx="1.25" fill="currentColor"/><rect x="10" y="10" width="2.5" height="12" rx="1.25" fill="currentColor"/><rect x="14" y="8" width="2.5" height="16" rx="1.25" fill="currentColor"/><rect x="18" y="11" width="2.5" height="10" rx="1.25" fill="currentColor"/><rect x="22" y="14" width="2.5" height="4" rx="1.25" fill="currentColor"/><rect x="26" y="13" width="2.5" height="6" rx="1.25" fill="currentColor"/></svg>;
    default: return null;
  }
};

window.Icon = Icon;
