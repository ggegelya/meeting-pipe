import Foundation

/// PIPE27: the tokens a run's metered model calls spent, from `<stem>.run.json`'s `usage`
/// (written by `mp.usage`). Present only when a per-token call ran, so its absence never reads
/// as a free cloud run. Tokens, never a price: prices change and tokens do not.
struct TokenUsage: Hashable {
    var input: Int
    var output: Int

    /// Nil unless `json` is an object carrying both counts as non-negative integers.
    init?(json: Any?) {
        guard let obj = json as? [String: Any],
              let input = (obj["input_tokens"] as? NSNumber)?.intValue,
              let output = (obj["output_tokens"] as? NSNumber)?.intValue,
              input >= 0, output >= 0 else { return nil }
        self.input = input
        self.output = output
    }

    init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    /// The quiet clause the detail header's provenance line carries ("12,345 tokens in,
    /// 1,234 out"), or nil when the run recorded none.
    static func label(_ usage: TokenUsage?, locale: Locale = .current) -> String? {
        guard let usage else { return nil }
        let format: (Int) -> String = { $0.formatted(.number.locale(locale)) }
        return "\(format(usage.input)) tokens in, \(format(usage.output)) out"
    }
}
