import Foundation

/// Filesystem half of STOR1's audio retention: enumerate `raw/`, build candidates,
/// hand them to `AudioRetention.decide`, and execute what it returns.
///
/// Scheduled alongside `OriginalsReaper` from `Coordinator.reapStorage()` (launch,
/// and after every pipeline job), on the same background task and under the same
/// `coordinator` event category.
///
/// Off-main callers only: blocking filesystem IO and an ffmpeg subprocess.
enum AudioRetentionSweep {

    /// What one sweep reclaimed. Returned so the caller can log it and so tests can
    /// assert without reading the event log.
    struct Outcome: Equatable {
        var compressed = 0
        var dropped = 0
        var bytesFreed = 0
        var failed = 0

        var didSomething: Bool { compressed > 0 || dropped > 0 }
    }

    @discardableResult
    static func sweep(
        in directory: URL,
        policies: [UUID: WorkflowRetention],
        now: Date = Date(),
        liveStem: String? = nil
    ) -> Outcome {
        // Every workflow on keep-forever is the default state; skip the directory
        // walk entirely rather than stat a whole library to decide nothing.
        guard policies.values.contains(where: { $0.policy != .keep }) else {
            return Outcome()
        }
        let candidates = self.candidates(in: directory)
        let actions = AudioRetention.decide(
            candidates: candidates, policies: policies, now: now, liveStem: liveStem
        )
        guard !actions.isEmpty else { return Outcome() }

        var outcome = Outcome()
        for action in actions {
            switch action {
            case .compress(let wav):
                let before = fileSize(of: wav)
                do {
                    let flac = try AudioTranscoder.compressToFLAC(wav: wav)
                    outcome.compressed += 1
                    outcome.bytesFreed += max(0, before - fileSize(of: flac))
                    Log.event(category: "coordinator", action: "audio_compressed", attributes: [
                        "stem": MeetingStore.stem(of: wav),
                        "bytes_before": before,
                        "bytes_after": fileSize(of: flac),
                    ])
                } catch {
                    outcome.failed += 1
                    Log.writeLine("daemon", "WARN: could not compress \(wav.lastPathComponent): \(error)")
                }
            case .drop(let audio):
                let before = fileSize(of: audio)
                let stem = MeetingStore.stem(of: audio)
                do {
                    try FileManager.default.removeItem(at: audio)
                    // Nothing will ever re-derive the peaks for audio that is gone.
                    try? FileManager.default.removeItem(at: WaveformPeaksLoader.cachePath(stem: stem))
                    outcome.dropped += 1
                    outcome.bytesFreed += before
                    Log.event(category: "coordinator", action: "audio_dropped", attributes: [
                        "stem": stem,
                        "bytes_freed": before,
                    ])
                } catch {
                    outcome.failed += 1
                    Log.writeLine("daemon", "WARN: could not drop \(audio.lastPathComponent): \(error)")
                }
            }
        }
        if outcome.didSomething {
            Log.event(category: "coordinator", action: "audio_retention_swept", attributes: [
                "compressed": outcome.compressed,
                "dropped": outcome.dropped,
                "bytes_freed": outcome.bytesFreed,
                "failed": outcome.failed,
            ])
            Log.writeLine(
                "daemon",
                "audio retention: compressed \(outcome.compressed), dropped \(outcome.dropped), "
                    + "freed \(outcome.bytesFreed / (1024 * 1024)) MB"
            )
        }
        return outcome
    }

    /// Build the candidate set from disk. Only a stem carrying `<stem>.summary.json`
    /// is considered: that sidecar is what makes `buildMeeting` call a meeting
    /// `.done`, and `AudioRetention.isSettled` requires `.done`. Filtering on the
    /// filename first means the two small JSON reads below happen for settled
    /// meetings only, not for the whole library on every sweep.
    static func candidates(in directory: URL) -> [AudioRetention.Candidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var audioByStem: [String: URL] = [:]
        var summarizedStems: Set<String> = []
        for url in entries {
            let stem = MeetingStore.stem(of: url)
            if MeetingStore.isFinalRecording(url) {
                audioByStem[stem] = url
            } else if url.lastPathComponent == "\(stem).summary.json" {
                summarizedStems.insert(stem)
            }
        }

        var out: [AudioRetention.Candidate] = []
        for (stem, audioURL) in audioByStem where summarizedStems.contains(stem) {
            guard let startedAt = MeetingStore.parseStem(stem) else { continue }
            let meta = readJSON(at: directory.appendingPathComponent("\(stem).meta.json"))
            let run = readJSON(at: directory.appendingPathComponent("\(stem).run.json"))
            out.append(AudioRetention.Candidate(
                stem: stem,
                audioURL: audioURL,
                startedAt: startedAt,
                workflowID: (meta?["workflow_id"] as? String).flatMap(UUID.init(uuidString:)),
                status: .done,
                publishState: run?["publish_state"] as? String
            ))
        }
        return out
    }

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
