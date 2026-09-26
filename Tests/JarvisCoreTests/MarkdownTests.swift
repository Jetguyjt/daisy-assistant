import Foundation
import JarvisCore

/// Answers arrive as Markdown; these pin how they split into blocks for the transcript.
final class MarkdownTests {
    func testBlocksCoverTheCommonShapes() {
        let text = """
        ## Plan
        First line
        second line

        - one
        - two
        1. alpha
        2) beta

        ```swift
        let x = 1

        print(x)
        ```
        > quoted
        > still quoted

        | Name | Role |
        |---|:---:|
        | George | Voice |
        ---
        """
        expectEqual(MarkdownBlocks.parse(text), [
            .heading(level: 2, text: "Plan"),
            .paragraph("First line\nsecond line"),
            .list(ordered: false, items: ["one", "two"]),
            .list(ordered: true, items: ["alpha", "beta"]),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .quote("quoted\nstill quoted"),
            .table(rows: [["Name", "Role"], ["George", "Voice"]]),
            .rule
        ])
    }
    func testUnclosedFenceStreamsAsCode() {
        expectEqual(MarkdownBlocks.parse("Here:\n```python\nprint(1)"), [.paragraph("Here:"), .code(language: "python", text: "print(1)")])
    }
    func testListContinuationsAndYearsInProse() {
        expectEqual(MarkdownBlocks.parse("1. First\n   continued\n2. Second"), [.list(ordered: true, items: ["First continued", "Second"])])
        expectEqual(MarkdownBlocks.parse("In 2024. We went"), [.paragraph("In 2024. We went")])
        expectEqual(MarkdownBlocks.parse("#hashtag not a heading"), [.paragraph("#hashtag not a heading")])
    }
}
