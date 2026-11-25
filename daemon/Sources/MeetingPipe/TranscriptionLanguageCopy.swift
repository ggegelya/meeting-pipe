import Foundation

/// Copy for Preferences ▸ Pipeline ▸ Languages ▸ Transcription, over
/// `transcription.language` (UX85).
///
/// **What the setting actually does.** The code reaches `AsrManager.transcribe` as
/// FluidAudio's `language:` argument (`FluidAudioRunner.resolveLanguage`), which is a
/// script filter on the decoder's top-K token candidates and nothing more: a set code
/// keeps the highest-scoring candidate written in that language's alphabet, and falls
/// back to the unfiltered best when none of the top-K is. `"auto"` just turns the
/// filter off. Parakeet v3 has no language-detection step, so there is nothing for
/// a pin to skip and nothing for "auto" to choose per meeting, which is what this
/// row used to say. Two consequences the copy has to carry: every Latin-alphabet
/// code behaves identically, and a Cyrillic code rejects ASCII letters, so an English
/// name spoken in a Ukrainian meeting can come out spelled in Cyrillic.
///
/// The tags are the stored values and must not change: an existing
/// `transcription.language = "uk"` has to keep loading and selecting its row.
enum TranscriptionLanguageCopy {

    /// The row's sublabel. Plain words: no engine or model names (the UX86 class).
    static let sublabel = """
        Which alphabet on-device transcription should prefer. Any lets it write Latin \
        or Cyrillic as it hears them. Picking a language makes it prefer that \
        language's alphabet: every Latin-alphabet language here does the same thing, \
        and with Ukrainian or Russian, English words in the same meeting can come out \
        in Cyrillic. Applies on the next daemon launch.
        """

    /// Title of the picker's `"auto"` option: no script preference.
    static let anyTitle = "Any (no preference)"

    /// Picker options in display order, as (stored value, title). The alphabet each
    /// code names is the one FluidAudio 0.14.8's `Language.script` filters to.
    static let options: [(tag: String, title: String)] = [
        ("auto", anyTitle),
        ("en", "English (en), Latin alphabet"),
        ("uk", "Українська (uk), Cyrillic alphabet"),
        ("ru", "Русский (ru), Cyrillic alphabet"),
        ("de", "Deutsch (de), Latin alphabet"),
        ("es", "Español (es), Latin alphabet"),
        ("fr", "Français (fr), Latin alphabet"),
        ("it", "Italiano (it), Latin alphabet"),
        ("pt", "Português (pt), Latin alphabet"),
        ("pl", "Polski (pl), Latin alphabet"),
    ]
}
