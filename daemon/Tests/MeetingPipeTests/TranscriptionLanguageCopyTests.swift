import XCTest
@testable import MeetingPipe

/// UX85: `transcription.language` is FluidAudio's script filter, not language
/// detection, and the Preferences row has to say so without changing a stored value.
final class TranscriptionLanguageCopyTests: XCTestCase {

    func test_copy_never_claims_detection() {
        // The old row said "Auto-detect chooses per meeting; a fixed code skips
        // detection". Parakeet v3 has no detection step to choose or skip.
        for text in [TranscriptionLanguageCopy.sublabel, TranscriptionLanguageCopy.anyTitle] {
            XCTAssertFalse(text.lowercased().contains("detect"), text)
        }
        for option in TranscriptionLanguageCopy.options {
            XCTAssertFalse(option.title.lowercased().contains("detect"), option.title)
        }
    }

    func test_sublabel_and_first_option_title() {
        XCTAssertEqual(TranscriptionLanguageCopy.anyTitle, "Any (no preference)")
        XCTAssertEqual(TranscriptionLanguageCopy.options.first?.tag, "auto")
        XCTAssertEqual(TranscriptionLanguageCopy.options.first?.title, "Any (no preference)")
        let sublabel = TranscriptionLanguageCopy.sublabel
        XCTAssertTrue(sublabel.hasPrefix("Which alphabet on-device transcription should prefer."))
        // The code-switch consequence is the one the owner's meetings hit.
        XCTAssertTrue(sublabel.contains("English words in the same meeting can come out in Cyrillic"))
        XCTAssertTrue(sublabel.hasSuffix("Applies on the next daemon launch."))
        // Plain words: no engine or model names in the Preferences copy (UX86 class).
        for name in ["FluidAudio", "Parakeet", "ASR", "TDT"] {
            XCTAssertFalse(sublabel.contains(name), name)
        }
    }

    /// The tags are what `config.toml` stores. A reordered or renamed tag would
    /// leave an existing `language = "uk"` selecting nothing.
    func test_stored_values_are_unchanged() {
        XCTAssertEqual(TranscriptionLanguageCopy.options.map(\.tag),
                       ["auto", "en", "uk", "ru", "de", "es", "fr", "it", "pt", "pl"])
    }

    /// Each row names the alphabet FluidAudio actually filters to for its code.
    func test_every_row_names_the_alphabet_the_filter_uses() {
        for option in TranscriptionLanguageCopy.options.dropFirst() {
            guard let language = FluidAudioRunner.resolveLanguage(hint: option.tag) else {
                return XCTFail("\(option.tag) must reach FluidAudio as a script filter")
            }
            let expected: String
            switch language.script {
            case .latin: expected = "Latin alphabet"
            case .cyrillic: expected = "Cyrillic alphabet"
            case .greek: expected = "Greek alphabet"
            }
            XCTAssertTrue(option.title.hasSuffix(expected), "\(option.title) vs \(expected)")
        }
        XCTAssertNil(FluidAudioRunner.resolveLanguage(hint: "auto"),
                     "Any (no preference) has to turn the filter off")
    }
}
