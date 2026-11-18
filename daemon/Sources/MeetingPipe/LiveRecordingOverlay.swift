import Foundation

/// UX101: the one place a live recording reads as `.recording`.
///
/// No scan assigns `Meeting.Status.recording`: on disk a meeting being written looks like one
/// waiting for the pipeline, and the recorder is what knows the difference. The overlay used to
/// live only in `MeetingRow`'s pill, so every other reader saw the scan's answer: the Status:
/// Recording chip and a saved folder holding it never matched, and two hours in, the age rule
/// turned the live row `.failed` for Needs you, Status: Failed and the row's Reprocess. The
/// Library applies this to its corpus before any scope, filter, folder or count reads it, and
/// the row's pill asks the same rule.
enum LiveRecordingOverlay {
    /// The status a row shows: `.recording` while it is the live stem, else what the scan said.
    static func status(of meeting: Meeting, isLive: Bool) -> Meeting.Status {
        isLive ? .recording : meeting.status
    }

    /// `meetings` with the live stem, if any, marked `.recording`. Returns the input untouched
    /// when nothing records, so the idle Library pays nothing.
    static func apply(_ meetings: [Meeting], live: String?) -> [Meeting] {
        guard let live, let index = meetings.firstIndex(where: { $0.stem == live }) else { return meetings }
        var out = meetings
        out[index].status = status(of: out[index], isLive: true)
        return out
    }
}
