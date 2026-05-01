// Notification — UNUserNotification banner recreation.
const Notification = ({ kind = "done", title, body, action }) => {
  const titleText = title ?? ({
    started: "Recording started",
    processing: "Recording stopped",
    done: "Meeting published",
    error: "MeetingPipe error",
  }[kind]);
  const bodyText = body ?? ({
    started: "20260428-1430.wav",
    processing: "Processing 20260428-1430.wav…",
    done: "Open in Notion",
    error: "Notion publish failed (401)",
  }[kind]);
  const actionLabel = action ?? (kind === "done" ? "Open in Notion" : null);

  return (
    <div style={{
      width: 360,
      borderRadius: 12,
      background: "var(--mp-hud-bg)",
      backdropFilter: "blur(24px) saturate(180%)",
      WebkitBackdropFilter: "blur(24px) saturate(180%)",
      boxShadow: "var(--mp-hud-shadow)",
      border: "0.5px solid var(--mp-hud-stroke)",
      padding: "12px 14px",
      display: "flex", gap: 12, alignItems: "flex-start",
      fontFamily: "var(--mp-font-sans)",
      color: "var(--mp-fg)",
    }}>
      <div style={{ width: 36, height: 36, borderRadius: 8, background: "#FBFAF7", border: "1px solid var(--mp-border)", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
        <Icon name="logomark" size={22}/>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
          <div style={{ fontSize: "var(--mp-text-base)", fontWeight: 600 }}>{titleText}</div>
          <div style={{ fontSize: "var(--mp-text-sm)", color: "var(--mp-fg-subtle)" }}>now</div>
        </div>
        <div style={{ fontSize: "var(--mp-text-base)", color: "var(--mp-fg-muted)", marginTop: 2, fontFamily: kind === "started" || kind === "processing" ? "var(--mp-font-mono)" : "inherit", fontSize: kind === "started" || kind === "processing" ? "var(--mp-text-sm)" : "var(--mp-text-base)" }}>
          {bodyText}
        </div>
        {actionLabel && (
          <div style={{ marginTop: 8, display: "flex", gap: 8 }}>
            <button style={{
              height: 24, padding: "0 10px", fontSize: "var(--mp-text-sm)", fontWeight: 500,
              borderRadius: 6, border: "1px solid var(--mp-border-strong)",
              background: "var(--mp-bg-raised)", color: "var(--mp-fg)", cursor: "pointer",
            }}>{actionLabel}</button>
          </div>
        )}
      </div>
    </div>
  );
};

window.Notification = Notification;
