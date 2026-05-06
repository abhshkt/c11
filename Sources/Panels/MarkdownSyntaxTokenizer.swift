import Foundation

enum MarkdownTokenKind: Sendable, Equatable {
    case headingMarker(level: Int)
    case headingText(level: Int)
    case listMarker
    case blockquoteMarker
    case codeFence
    case codeFenceLang
    case codeBody(language: String?)
    case thematicBreak
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case escape
}

struct MarkdownToken: Sendable, Equatable {
    let range: NSRange
    let kind: MarkdownTokenKind
}

enum MarkdownSyntaxTokenizer {
    static func tokenize(_ source: NSString) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        let length = source.length
        guard length > 0 else { return tokens }

        var openFence: (char: Character, length: Int)? = nil
        var fenceLanguage: String?
        var cursor = 0

        while cursor < length {
            let lineEnd = findLineEnd(in: source, from: cursor, length: length)
            let lineRange = NSRange(location: cursor, length: lineEnd - cursor)
            if lineRange.length > 0 {
                processLine(
                    in: source,
                    lineRange: lineRange,
                    openFence: &openFence,
                    fenceLanguage: &fenceLanguage,
                    into: &tokens
                )
            }
            cursor = advancePastLineBreak(in: source, from: lineEnd, length: length)
        }

        return tokens
    }

    // MARK: - Line dispatch

    private static func processLine(
        in source: NSString,
        lineRange: NSRange,
        openFence: inout (char: Character, length: Int)?,
        fenceLanguage: inout String?,
        into tokens: inout [MarkdownToken]
    ) {
        let line = source.substring(with: lineRange) as NSString

        if let fence = matchFence(line: line) {
            if let open = openFence {
                // Inside an open fence: per CommonMark, a closing fence must
                // use the same character and be at least as long as the opener.
                // Anything else (different char, or shorter run of the same
                // char) is just code content — do NOT close the block.
                if fence.char == open.char && fence.length >= open.length {
                    tokens.append(MarkdownToken(range: lineRange, kind: .codeFence))
                    openFence = nil
                    fenceLanguage = nil
                } else {
                    tokens.append(MarkdownToken(range: lineRange, kind: .codeBody(language: fenceLanguage)))
                }
            } else {
                tokens.append(MarkdownToken(range: lineRange, kind: .codeFence))
                openFence = (char: fence.char, length: fence.length)
                if let langRange = fence.langRange {
                    let abs = NSRange(
                        location: lineRange.location + langRange.location,
                        length: langRange.length
                    )
                    tokens.append(MarkdownToken(range: abs, kind: .codeFenceLang))
                    fenceLanguage = line.substring(with: langRange)
                }
            }
            return
        }

        if openFence != nil {
            tokens.append(MarkdownToken(range: lineRange, kind: .codeBody(language: fenceLanguage)))
            return
        }

        if matchesThematicBreak(line: line) {
            tokens.append(MarkdownToken(range: lineRange, kind: .thematicBreak))
            return
        }

        if let heading = matchHeading(line: line) {
            let markerAbs = NSRange(
                location: lineRange.location + heading.markerRange.location,
                length: heading.markerRange.length
            )
            tokens.append(MarkdownToken(range: markerAbs, kind: .headingMarker(level: heading.level)))
            if let bodyRange = heading.bodyRange, bodyRange.length > 0 {
                let bodyAbs = NSRange(
                    location: lineRange.location + bodyRange.location,
                    length: bodyRange.length
                )
                tokens.append(MarkdownToken(range: bodyAbs, kind: .headingText(level: heading.level)))
                scanInline(in: source, range: bodyAbs, into: &tokens)
            }
            return
        }

        if let listRange = matchListMarker(line: line) {
            let abs = NSRange(
                location: lineRange.location + listRange.location,
                length: listRange.length
            )
            tokens.append(MarkdownToken(range: abs, kind: .listMarker))
            let restStart = listRange.location + listRange.length
            if restStart < lineRange.length {
                let restRange = NSRange(
                    location: lineRange.location + restStart,
                    length: lineRange.length - restStart
                )
                scanInline(in: source, range: restRange, into: &tokens)
            }
            return
        }

        if let bqRange = matchBlockquote(line: line) {
            let abs = NSRange(
                location: lineRange.location + bqRange.location,
                length: bqRange.length
            )
            tokens.append(MarkdownToken(range: abs, kind: .blockquoteMarker))
            let restStart = bqRange.location + bqRange.length
            if restStart < lineRange.length {
                let restRange = NSRange(
                    location: lineRange.location + restStart,
                    length: lineRange.length - restStart
                )
                scanInline(in: source, range: restRange, into: &tokens)
            }
            return
        }

        scanInline(in: source, range: lineRange, into: &tokens)
    }

    private static func scanInline(in source: NSString, range: NSRange, into tokens: inout [MarkdownToken]) {
        guard range.length > 0 else { return }
        let str = source as String
        for entry in inlineRegexes {
            entry.regex.enumerateMatches(in: str, options: [], range: range) { match, _, _ in
                guard let match else { return }
                for kind in entry.kinds {
                    tokens.append(MarkdownToken(range: match.range, kind: kind))
                }
            }
        }
    }

    // MARK: - Block matchers

    private struct FenceMatch {
        let char: Character
        let length: Int
        let langRange: NSRange?
    }

    private static func matchFence(line: NSString) -> FenceMatch? {
        guard let match = fenceRegex.firstMatch(
            in: line as String,
            options: [],
            range: NSRange(location: 0, length: line.length)
        ) else { return nil }
        let fenceRange = match.range(at: 1)
        guard fenceRange.location != NSNotFound, fenceRange.length > 0 else { return nil }
        let fenceSubstring = line.substring(with: fenceRange)
        guard let fenceChar = fenceSubstring.first else { return nil }
        let langRange = match.range(at: 2)
        let lang: NSRange? = (langRange.location != NSNotFound && langRange.length > 0) ? langRange : nil
        return FenceMatch(char: fenceChar, length: fenceRange.length, langRange: lang)
    }

    private static func matchesThematicBreak(line: NSString) -> Bool {
        thematicBreakRegex.firstMatch(
            in: line as String,
            options: [],
            range: NSRange(location: 0, length: line.length)
        ) != nil
    }

    private struct HeadingMatch {
        let level: Int
        let markerRange: NSRange
        let bodyRange: NSRange?
    }

    // Hand-rolled because CommonMark heading rules (≤3 leading spaces, 1-6 hashes,
    // mandatory space-or-EOL after, trailing-hash trimming) are easier to express
    // as a small state machine than as one regex.
    private static func matchHeading(line: NSString) -> HeadingMatch? {
        let len = line.length
        guard len > 0 else { return nil }
        var i = 0
        var leading = 0
        while i < len && leading < 4 {
            let ch = line.character(at: i)
            if ch == 0x20 || ch == 0x09 {
                i += 1
                leading += 1
            } else {
                break
            }
        }
        if leading >= 4 { return nil }
        let hashStart = i
        while i < len && line.character(at: i) == 0x23 { i += 1 }
        let hashCount = i - hashStart
        guard hashCount >= 1 && hashCount <= 6 else { return nil }
        if i < len {
            let ch = line.character(at: i)
            guard ch == 0x20 || ch == 0x09 else { return nil }
        }
        let markerEnd = i
        while i < len {
            let ch = line.character(at: i)
            if ch == 0x20 || ch == 0x09 { i += 1 } else { break }
        }
        let bodyStart = i
        var bodyEnd = len
        while bodyEnd > bodyStart {
            let ch = line.character(at: bodyEnd - 1)
            if ch == 0x20 || ch == 0x09 { bodyEnd -= 1 } else { break }
        }
        let bodyRange: NSRange? = bodyEnd > bodyStart
            ? NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            : nil
        return HeadingMatch(
            level: hashCount,
            markerRange: NSRange(location: hashStart, length: markerEnd - hashStart),
            bodyRange: bodyRange
        )
    }

    private static func matchListMarker(line: NSString) -> NSRange? {
        listMarkerRegex.firstMatch(
            in: line as String,
            options: [],
            range: NSRange(location: 0, length: line.length)
        )?.range
    }

    private static func matchBlockquote(line: NSString) -> NSRange? {
        blockquoteRegex.firstMatch(
            in: line as String,
            options: [],
            range: NSRange(location: 0, length: line.length)
        )?.range
    }

    // MARK: - Line stepping

    private static func findLineEnd(in source: NSString, from start: Int, length: Int) -> Int {
        var i = start
        while i < length {
            let ch = source.character(at: i)
            if ch == 0x0A || ch == 0x0D { return i }
            i += 1
        }
        return length
    }

    private static func advancePastLineBreak(in source: NSString, from index: Int, length: Int) -> Int {
        guard index < length else { return index }
        let ch = source.character(at: index)
        if ch == 0x0D {
            let next = index + 1
            if next < length && source.character(at: next) == 0x0A { return next + 1 }
            return next
        }
        return index + 1
    }

    // MARK: - Hoisted regexes

    private static let fenceRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^[ \t]{0,3}(```+|~~~+)[ \t]*([^\s`~]*)[ \t]*$"#,
            options: []
        )
    }()

    private static let thematicBreakRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^[ \t]{0,3}(?:[-*_])(?:[ \t]*[-*_]){2,}[ \t]*$"#,
            options: []
        )
    }()

    private static let listMarkerRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+"#,
            options: []
        )
    }()

    private static let blockquoteRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^[ \t]{0,3}>+[ \t]?"#,
            options: []
        )
    }()

    private struct InlineRegex {
        let regex: NSRegularExpression
        let kinds: [MarkdownTokenKind]
    }

    private static let inlineRegexes: [InlineRegex] = {
        // Triple-emphasis (`***word***` / `___word___`) is the classic markdown
        // corner case: it carries BOTH bold and italic semantics, so we emit
        // two tokens for the same range. The styler tolerates overlap, and the
        // regexes are anchored on three markers so they short-circuit fast on
        // lines without triple emphasis. These run first so callers don't have
        // to dedupe against the narrower `**…**` / `__…__` hits below.
        let entries: [(String, [MarkdownTokenKind])] = [
            (#"\*\*\*(?=\S)[\s\S]+?(?<=\S)\*\*\*"#, [.bold, .italic]),
            (#"___(?=\S)[\s\S]+?(?<=\S)___"#, [.bold, .italic]),
            (#"\*\*(?=\S)[\s\S]+?(?<=\S)\*\*"#, [.bold]),
            (#"__(?=\S)[\s\S]+?(?<=\S)__"#, [.bold]),
            (#"~~(?=\S)[\s\S]+?(?<=\S)~~"#, [.strikethrough]),
            (#"(?<![\w*])\*(?!\*)[^*\n]+?(?<!\*)\*(?![\w*])"#, [.italic]),
            (#"(?<![\w_])_(?!_)[^_\n]+?(?<!_)_(?![\w_])"#, [.italic]),
            (#"`+[^`\n]+?`+"#, [.inlineCode]),
            (#"\[[^\]\n]*\]\([^)\n]*\)"#, [.link]),
            (#"\\[\\`*_{}\[\]()#+\-.!~|<>]"#, [.escape]),
        ]
        return entries.map { pattern, kinds in
            InlineRegex(regex: try! NSRegularExpression(pattern: pattern, options: []), kinds: kinds)
        }
    }()
}
