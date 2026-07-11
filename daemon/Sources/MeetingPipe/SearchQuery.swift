import Foundation

/// Turns a user's free-text search box into a safe SQLite FTS5 `MATCH` expression (UX16). Pure and
/// dependency-free so the tokenisation is unit-tested without a live database.
///
/// The user types plain words; FTS5's query syntax has operators (`"`, `*`, `(`, `NOT`, `AND`, ...)
/// that a raw string would either error on or misinterpret. So we extract Unicode-aware alphanumeric
/// tokens (dropping punctuation) and emit each as a prefix term (`token*`), implicitly ANDed. Prefix
/// matching gives search-as-you-type ("bud" finds "budget"); the `unicode61` tokenizer the index
/// uses folds case and handles Cyrillic word boundaries, matching the pre-FTS in-memory behaviour.
enum SearchQuery {

    /// Split into alphanumeric tokens, Unicode-aware. Punctuation and whitespace are separators, so
    /// "Q3 budget!" -> ["Q3", "budget"] and Cyrillic runs stay intact.
    static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// The FTS5 MATCH expression for `text`, or nil when there is nothing to match on (empty or
    /// punctuation-only). Each token becomes a lowercased prefix term joined by spaces (implicit AND).
    static func ftsMatch(_ text: String) -> String? {
        let terms = tokens(text).map { "\($0.lowercased())*" }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }
}
