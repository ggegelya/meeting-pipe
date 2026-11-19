import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// PIPE25: whether a run-all hand-off tries Apple Intelligence or goes straight to the local
/// model, decided before the first window so a language the system model refuses wastes none.
///
/// Apple Intelligence rejected every Ukrainian meeting on the assessment Mac (3 of 5 runs,
/// 2026-10-12 to 18), and on a long transcript the rejection can land on a late window after the
/// earlier ones already ran. When the meeting's language is known and the system model reports it
/// unsupported, the launcher skips Apple; anything unknown tries Apple, and a refusal there still
/// falls back (`PipelineLauncher.completeViaAppleIntelligence`). Pure; the reads are the caller's.
enum AppleLanguageRoute: Equatable, Sendable {
    case tryApple
    /// Skip Apple: the meeting is in `language` (an ISO 639 code), which it does not support.
    case skipToLocal(language: String)

    /// The ISO 639 language part of a code or locale identifier (`uk`, `en-US` -> `en`,
    /// `pt_BR` -> `pt`), or nil for nothing usable: empty, `auto`, or not letters.
    static func code(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let head = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard (2...3).contains(head.count), head != "auto",
              head.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return head
    }

    /// Unknown language, or no list of supported languages, tries Apple: the pre-check may only
    /// save a wasted call, never refuse a meeting the model would have taken.
    static func decide(language: String?, supported: Set<String>?) -> AppleLanguageRoute {
        guard let code = code(language), let supported, !supported.isEmpty else { return .tryApple }
        return supported.contains(code) ? .tryApple : .skipToLocal(language: code)
    }

    /// The meeting's language: a pinned `transcription.language` wins (the ASR ran in it), else
    /// the language the transcript JSON reports. Nil when neither says.
    static func meetingLanguage(pinned: String?, transcriptJSON: URL) -> String? {
        if let pinned = code(pinned) { return pinned }
        guard let data = try? Data(contentsOf: transcriptJSON),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return code(obj["language"] as? String)
    }

    /// The languages the on-device system model reports it supports, as ISO 639 codes, or nil
    /// where the framework is absent (the CI runner, macOS before 26).
    static func systemSupportedLanguages() -> Set<String>? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let codes = SystemLanguageModel.default.supportedLanguages
                .compactMap { code($0.languageCode?.identifier) }
            return codes.isEmpty ? nil : Set(codes)
        }
        #endif
        return nil
    }
}
