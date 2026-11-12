import XCTest
@testable import MeetingPipe

/// UX16: the pure FTS query builder. No database, so tokenisation is pinned deterministically.
final class SearchQueryTests: XCTestCase {

    func test_tokens_split_on_non_alphanumeric() {
        XCTAssertEqual(SearchQuery.tokens("Q3 budget!"), ["Q3", "budget"])
        XCTAssertEqual(SearchQuery.tokens("  hello, world  "), ["hello", "world"])
        XCTAssertEqual(SearchQuery.tokens("acme-corp/review"), ["acme", "corp", "review"])
    }

    func test_tokens_keep_unicode_letters() {
        // The unicode61 tokenizer the index uses is Cyrillic-aware; the query builder must match.
        XCTAssertEqual(SearchQuery.tokens("привіт світ"), ["привіт", "світ"])
    }

    func test_tokens_empty_for_blank_or_punctuation() {
        XCTAssertEqual(SearchQuery.tokens(""), [])
        XCTAssertEqual(SearchQuery.tokens("   "), [])
        XCTAssertEqual(SearchQuery.tokens("!@#$"), [])
    }

    func test_ftsMatch_builds_lowercased_prefix_terms() {
        XCTAssertEqual(SearchQuery.ftsMatch("Budget Q3"), "budget* q3*")
        XCTAssertEqual(SearchQuery.ftsMatch("deploy"), "deploy*")
    }

    func test_ftsMatch_nil_when_nothing_to_match() {
        XCTAssertNil(SearchQuery.ftsMatch(""))
        XCTAssertNil(SearchQuery.ftsMatch("   "))
        XCTAssertNil(SearchQuery.ftsMatch("!@#"))
    }

    /// PERF20: a query no token of which reaches two characters is not sent to the index.
    func test_indexMatch_skips_one_character_queries() {
        XCTAssertNil(SearchQuery.indexMatch("b"))
        XCTAssertNil(SearchQuery.indexMatch(" b "))
        XCTAssertNil(SearchQuery.indexMatch("a b"), "two one-letter terms are as broad as one")
        XCTAssertNil(SearchQuery.indexMatch(""))
        XCTAssertEqual(SearchQuery.indexMatch("bu"), "bu*")
        XCTAssertEqual(SearchQuery.indexMatch("q budget"), "q* budget*", "a longer token narrows it, so it goes")
        XCTAssertEqual(SearchQuery.indexMatch("бю"), "бю*")
    }
}
