import Foundation

/// Fuzzy matching + scoring for the sidebar session search.
///
/// What "fuzzy" means here, in priority order:
///
/// 1. **Substring** — "budget" matches "Q2 Budget Review"
/// 2. **Subsequence** — "bgt" matches "budget" (Sublime-Text style)
/// 3. **Typo-tolerant** — "bduget" matches "budget" (Levenshtein ≤ 2)
///
/// Multi-word queries are split on whitespace and every token must hit
/// the candidate independently. So "review budget" matches both
/// "Q2 Budget Review" and "Budget — Q2 review" regardless of order.
///
/// We only run fuzzy matching against the session *title* from the
/// sidebar. Running subsequence/Levenshtein across a 10k-word transcript
/// would both be expensive and produce too many noisy matches (a
/// subsequence of three chars will hit nearly any paragraph).
/// Transcripts get a plain case-insensitive substring check in the
/// caller — that's what you want when you're looking for a phrase you
/// remember saying.
public enum FuzzyMatcher {

    /// Score `candidate` against `query`. Returns nil if there's no
    /// meaningful match; otherwise higher is better.
    ///
    /// Both strings are assumed to already be lowercased by the caller —
    /// we don't lowercase internally so repeated calls over a long list
    /// don't pay that cost per-candidate.
    public static func score(query: String, in candidate: String) -> Int? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return 0 }

        var total = 0
        for token in tokens {
            guard let s = tokenScore(String(token), in: candidate) else {
                return nil   // any token missing = no match
            }
            total += s
        }
        return total
    }

    // MARK: Per-token scoring

    private static func tokenScore(_ token: String, in candidate: String) -> Int? {
        guard !token.isEmpty else { return 0 }

        // 1. Substring — strongest signal.
        if candidate.contains(token) {
            // Bonus for prefix match (the user's query is the start of
            // the title), and for word-boundary match (they typed a
            // whole word that's in the title).
            if candidate.hasPrefix(token) {
                return 1000 + token.count * 4
            }
            if hasWordBoundaryMatch(token, in: candidate) {
                return 800 + token.count * 4
            }
            return 600 + token.count * 2
        }

        // 2. Subsequence — "bgt" → "budget". Wrapped in a tier base of
        // 200 so even a sparse subsequence match (score ~10) outranks
        // every typo match, which is the ordering the UX relies on.
        if let s = subsequenceScore(token, in: candidate) {
            return 200 + s
        }

        // 3. Typo tolerance — only for short-ish tokens where a single
        // edit is meaningful. Skips the expensive Levenshtein pass for
        // 1–2 char tokens (too permissive) and 13+ char tokens (too
        // slow and rarely needed). Flat 50 keeps this tier strictly
        // below any subsequence match.
        if token.count >= 3, token.count <= 12 {
            let maxDist = token.count <= 5 ? 1 : 2
            if hasNearMatch(token, in: candidate, maxDistance: maxDist) {
                return 50
            }
        }

        return nil
    }

    // MARK: Substring helpers

    private static func hasWordBoundaryMatch(_ token: String, in candidate: String) -> Bool {
        // Walk the candidate looking for `token` preceded by a word
        // boundary (start of string, whitespace, or punctuation). Regex
        // would be cleaner but also more expensive when called N times
        // per keystroke; manual scan is fine.
        let cc = Array(candidate)
        let tc = Array(token)
        guard tc.count <= cc.count else { return false }
        var i = 0
        while i <= cc.count - tc.count {
            let prevIsBoundary = i == 0 || (!cc[i - 1].isLetter && !cc[i - 1].isNumber)
            if prevIsBoundary {
                var match = true
                for j in 0..<tc.count where cc[i + j] != tc[j] {
                    match = false
                    break
                }
                if match { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: Subsequence

    private static func subsequenceScore(_ token: String, in candidate: String) -> Int? {
        let tc = Array(token)
        let cc = Array(candidate)
        guard !tc.isEmpty else { return 0 }

        var ti = 0
        var score = 0
        var lastMatchIdx = -1
        var prevChar: Character = " "

        for ci in 0..<cc.count {
            if ti < tc.count && cc[ci] == tc[ti] {
                // Base match credit.
                score += 3
                // Consecutive-chars bonus — tighter clusters rank higher.
                if ci == lastMatchIdx + 1 { score += 4 }
                // Word-boundary bonus — matching the first char of a word
                // is a much stronger signal than the middle of one.
                if !prevChar.isLetter && !prevChar.isNumber { score += 8 }
                lastMatchIdx = ci
                ti += 1
            }
            prevChar = cc[ci]
        }
        return ti == tc.count ? score : nil
    }

    // MARK: Typo tolerance

    private static func hasNearMatch(_ token: String, in candidate: String, maxDistance: Int) -> Bool {
        // Compare against each word in the candidate rather than the
        // whole string — Levenshtein(candidate, token) would blow up for
        // long titles and give meaningless distances.
        for word in candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if abs(word.count - token.count) > maxDistance { continue }
            if levenshtein(String(word), token) <= maxDistance { return true }
        }
        return false
    }

    /// Standard two-row Levenshtein. Only allocates two Int arrays the
    /// size of the shorter string — fine for the word-length inputs we
    /// feed it.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }

        var prev = Array(0...bc.count)
        var curr = Array(repeating: 0, count: bc.count + 1)

        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                if ac[i - 1] == bc[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], min(prev[j], curr[j - 1]))
                }
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }
}
