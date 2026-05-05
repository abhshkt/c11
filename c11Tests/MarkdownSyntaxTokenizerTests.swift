import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-function tokenizer behaviour. The tokenizer drives the markdown editor's
/// syntax styling pass, so these tests assert observable token output rather
/// than implementation shape.
final class MarkdownSyntaxTokenizerTests: XCTestCase {
    private func tokens(_ input: String) -> [MarkdownToken] {
        MarkdownSyntaxTokenizer.tokenize(input as NSString)
    }

    func testEmptyInput() {
        XCTAssertEqual(tokens(""), [])
    }

    func testPlainTextProducesNoTokens() {
        XCTAssertEqual(tokens("just some prose with no syntax"), [])
    }

    func testHeadingLevelsOneThroughSix() {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            let result = tokens("\(prefix) Heading\n")
            let kinds = result.map(\.kind)
            XCTAssertTrue(
                kinds.contains(.headingMarker(level: level)),
                "expected headingMarker(level: \(level)) in \(kinds)"
            )
            XCTAssertTrue(
                kinds.contains(.headingText(level: level)),
                "expected headingText(level: \(level)) in \(kinds)"
            )
        }
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertEqual(tokens("####### too many"), [])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(tokens("#hashtag"), [])
    }

    func testListMarkers() {
        for marker in ["- item", "* item", "+ item", "1. item", "12) item"] {
            let result = tokens(marker)
            XCTAssertTrue(
                result.contains(where: { $0.kind == .listMarker }),
                "expected listMarker for \(marker)"
            )
        }
    }

    func testBlockquoteMarker() {
        let result = tokens("> a quote")
        XCTAssertTrue(result.contains(where: { $0.kind == .blockquoteMarker }))
    }

    func testThematicBreakVariants() {
        for line in ["---", "***", "___", " - - -", "* * *"] {
            let result = tokens(line)
            XCTAssertTrue(
                result.contains(where: { $0.kind == .thematicBreak }),
                "expected thematicBreak for \(line)"
            )
        }
    }

    func testFencedCodeWithLanguage() {
        let input = """
        ```swift
        let x = 1
        ```
        """
        let result = tokens(input)
        let kinds = result.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .codeFence }.count, 2)
        XCTAssertTrue(kinds.contains(.codeFenceLang))
        XCTAssertTrue(kinds.contains(.codeBody(language: "swift")))
    }

    func testFencedCodeWithoutLanguage() {
        let input = """
        ```
        plain code
        ```
        """
        let result = tokens(input)
        let kinds = result.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .codeFence }.count, 2)
        XCTAssertFalse(kinds.contains(.codeFenceLang))
        XCTAssertTrue(kinds.contains(.codeBody(language: nil)))
    }

    func testFencedCodeMasksInlineScan() {
        let input = """
        ```
        **not bold**
        `not code`
        ```
        """
        let result = tokens(input)
        let kinds = result.map(\.kind)
        XCTAssertFalse(kinds.contains(.bold), "bold inside fenced code should not tokenize")
        XCTAssertFalse(kinds.contains(.inlineCode), "inline code inside fenced code should not tokenize")
    }

    func testBoldAsterisks() {
        let result = tokens("a **bold** word")
        XCTAssertTrue(result.contains(where: { $0.kind == .bold }))
    }

    func testBoldUnderscores() {
        let result = tokens("__bold__")
        XCTAssertTrue(result.contains(where: { $0.kind == .bold }))
    }

    func testItalicAsterisk() {
        let result = tokens("an *italic* word")
        XCTAssertTrue(result.contains(where: { $0.kind == .italic }))
    }

    func testItalicUnderscore() {
        let result = tokens("an _italic_ word")
        XCTAssertTrue(result.contains(where: { $0.kind == .italic }))
    }

    func testStrikethrough() {
        let result = tokens("~~struck~~")
        XCTAssertTrue(result.contains(where: { $0.kind == .strikethrough }))
    }

    func testInlineCode() {
        let result = tokens("call `foo()` here")
        XCTAssertTrue(result.contains(where: { $0.kind == .inlineCode }))
    }

    func testLink() {
        let result = tokens("see [docs](https://example.com)")
        XCTAssertTrue(result.contains(where: { $0.kind == .link }))
    }

    func testEscape() {
        let result = tokens(#"a \* literal asterisk"#)
        XCTAssertTrue(result.contains(where: { $0.kind == .escape }))
    }

    func testNestedEmphasis() {
        // ***word*** should at minimum produce one bold and one italic candidate;
        // the styler tolerates overlap.
        let result = tokens("***word***")
        let kinds = result.map(\.kind)
        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.italic))
    }

    func testCRLFLineEndingsAreRespected() {
        let input = "# h1\r\n\r\n## h2\r\n"
        let result = tokens(input)
        let kinds = result.map(\.kind)
        XCTAssertTrue(kinds.contains(.headingMarker(level: 1)))
        XCTAssertTrue(kinds.contains(.headingMarker(level: 2)))
    }

    func testHeadingRangesPointToSourcePositions() throws {
        let input = "## Hello\n"
        let nsInput = input as NSString
        let result = tokens(input)
        let marker = try XCTUnwrap(result.first(where: {
            if case .headingMarker = $0.kind { return true } else { return false }
        }))
        let body = try XCTUnwrap(result.first(where: {
            if case .headingText = $0.kind { return true } else { return false }
        }))
        XCTAssertEqual(nsInput.substring(with: marker.range), "##")
        XCTAssertEqual(nsInput.substring(with: body.range), "Hello")
    }

    func testInlineRangesPointToSourcePositions() throws {
        let input = "leading **bold** trailing"
        let nsInput = input as NSString
        let result = tokens(input)
        let bold = try XCTUnwrap(result.first(where: { $0.kind == .bold }))
        XCTAssertEqual(nsInput.substring(with: bold.range), "**bold**")
    }

    func testFencedCodeBodyCarriesLanguage() throws {
        let input = """
        ```python
        x = 1
        y = 2
        ```
        """
        let result = tokens(input)
        let bodies = result.compactMap { token -> String? in
            if case .codeBody(let lang) = token.kind { return lang } else { return nil }
        }
        XCTAssertEqual(bodies, ["python", "python"])
    }

    func testMultipleInlineTokensOnOneLine() {
        let result = tokens("**bold** and *italic* and `code` and [link](url)")
        let kinds = result.map(\.kind)
        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.italic))
        XCTAssertTrue(kinds.contains(.inlineCode))
        XCTAssertTrue(kinds.contains(.link))
    }

    /// CommonMark §4.5: a fenced code block opened with backticks must be
    /// closed by backticks. A `~~~` line inside a backtick fence is just
    /// code content — it must not terminate the block.
    func testFenceMismatchTildeDoesNotCloseBacktick() {
        let input = "```\nlet x = 1\n~~~\nfunction()\n```\n"
        let nsInput = input as NSString
        let result = tokens(input)

        let fences = result.filter { $0.kind == .codeFence }
        XCTAssertEqual(
            fences.count, 2,
            "only opener and final closer should be .codeFence; got \(result.map(\.kind))"
        )

        let bodies = result.filter {
            if case .codeBody = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(
            bodies.count, 3,
            "all 3 interior lines (incl. ~~~) should be .codeBody"
        )

        // The tilde line specifically must be code body, not a fence.
        let tildeLine = bodies.first(where: {
            nsInput.substring(with: $0.range) == "~~~"
        })
        XCTAssertNotNil(
            tildeLine,
            "~~~ inside a backtick fence must be tokenized as .codeBody"
        )

        // And the function() line must also be body, not stray inline.
        let funcLine = bodies.first(where: {
            nsInput.substring(with: $0.range) == "function()"
        })
        XCTAssertNotNil(funcLine, "function() should remain inside the fence as .codeBody")
    }

    /// CommonMark §4.5: a closing fence must use the same character AND have
    /// at least as many of that character as the opener. A 3-backtick line
    /// inside a 4-backtick fence is just code content.
    func testFenceMustMatchOpeningLength() {
        let input = "````\nlet x = 1\n```\nfunction()\n````\n"
        let nsInput = input as NSString
        let result = tokens(input)

        let fences = result.filter { $0.kind == .codeFence }
        XCTAssertEqual(
            fences.count, 2,
            "only the 4-backtick opener and 4-backtick closer should be .codeFence; got \(result.map(\.kind))"
        )

        let bodies = result.filter {
            if case .codeBody = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(
            bodies.count, 3,
            "all 3 interior lines (incl. the inner ```) should be .codeBody"
        )

        // The shorter inner fence must be body, not a fence.
        let innerLine = bodies.first(where: {
            nsInput.substring(with: $0.range) == "```"
        })
        XCTAssertNotNil(
            innerLine,
            "an inner ``` (shorter than the ```` opener) must not close the fence"
        )

        // The two real fence lines should bracket the body content.
        XCTAssertEqual(nsInput.substring(with: fences[0].range), "````")
        XCTAssertEqual(nsInput.substring(with: fences[1].range), "````")
    }
}
