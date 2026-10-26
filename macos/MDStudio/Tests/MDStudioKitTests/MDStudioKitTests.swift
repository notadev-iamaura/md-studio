// 앱 기능 단위 테스트: 서식 명령, 목록 이어 쓰기, 색칠, 파일 저장, 임시본, 설정, 클립보드, PDF, 미리보기
// 환경 변수 MDSTUDIO_SNAPSHOT_DIR을 주면 미리보기를 PNG로 저장한다(디자인 눈 확인용).
import AppKit
import XCTest
@testable import MDStudioKit
import MDCore

final class EditorCommandTests: XCTestCase {
    private func run(_ cmd: FormatCommand, _ text: String, _ sel: NSRange) -> (String, NSRange) {
        let r = EditorCommands.run(cmd, text: text, selections: [sel])
        return (r.apply(to: text), r.selection)
    }

    func testWrapToggles() {
        XCTAssertEqual(run(.bold, "abc", NSRange(location: 0, length: 3)).0, "**abc**")
        XCTAssertEqual(run(.bold, "**abc**", NSRange(location: 2, length: 3)).0, "abc")
        XCTAssertEqual(run(.bold, "**abc**", NSRange(location: 0, length: 7)).0, "abc")
        let (t, s) = run(.italic, "", NSRange(location: 0, length: 0))
        XCTAssertEqual(t, "*기울임*")
        XCTAssertEqual(s, NSRange(location: 1, length: 3))
        XCTAssertEqual(run(.strike, "x", NSRange(location: 0, length: 1)).0, "~~x~~")
        XCTAssertEqual(run(.code, "한글", NSRange(location: 0, length: 2)).0, "`한글`")
    }

    func testLinePrefixes() {
        XCTAssertEqual(run(.h1, "제목", NSRange(location: 0, length: 0)).0, "# 제목")
        XCTAssertEqual(run(.h1, "# 제목", NSRange(location: 0, length: 0)).0, "제목")
        XCTAssertEqual(run(.h2, "# 제목", NSRange(location: 0, length: 0)).0, "## 제목")
        XCTAssertEqual(run(.ul, "a\nb", NSRange(location: 0, length: 3)).0, "- a\n- b")
        XCTAssertEqual(run(.ul, "- a\n- b", NSRange(location: 0, length: 7)).0, "a\nb")
        XCTAssertEqual(run(.ol, "a\nb\nc", NSRange(location: 0, length: 5)).0, "1. a\n2. b\n3. c")
        XCTAssertEqual(run(.task, "  일", NSRange(location: 3, length: 0)).0, "  - [ ] 일")
        XCTAssertEqual(run(.quote, "- a", NSRange(location: 0, length: 0)).0, "> a")
        // 빈 줄에서 목록을 켜면 커서는 기호 뒤
        let (t, s) = run(.ul, "", NSRange(location: 0, length: 0))
        XCTAssertEqual(t, "- ")
        XCTAssertEqual(s, NSRange(location: 2, length: 0))
    }

    func testBlocksAndLink() {
        XCTAssertEqual(run(.hr, "", NSRange(location: 0, length: 0)).0, "---\n")
        XCTAssertEqual(run(.hr, "글", NSRange(location: 1, length: 0)).0, "글\n\n---\n")
        let (code, cs) = run(.codeBlock, "", NSRange(location: 0, length: 0))
        XCTAssertEqual(code, "```\n\n```\n")
        XCTAssertEqual(cs.location, 4)
        XCTAssertEqual(run(.codeBlock, "a\nb", NSRange(location: 0, length: 3)).0, "```\na\nb\n```")
        let (l1, s1) = run(.link, "문서", NSRange(location: 0, length: 2))
        XCTAssertEqual(l1, "[문서](https://)")
        XCTAssertEqual((l1 as NSString).substring(with: s1), "https://")
        let (l2, s2) = run(.link, "https://a.com", NSRange(location: 0, length: 13))
        XCTAssertEqual(l2, "[링크 텍스트](https://a.com)")
        XCTAssertEqual((l2 as NSString).substring(with: s2), "링크 텍스트")
    }

    func testContinueList() {
        func enter(_ text: String) -> String? {
            EditorCommands.continueList(text: text, selection: NSRange(location: (text as NSString).length, length: 0))?.apply(to: text)
        }
        XCTAssertEqual(enter("- a"), "- a\n- ")
        XCTAssertEqual(enter("  * a"), "  * a\n  * ")
        XCTAssertEqual(enter("9. a"), "9. a\n10. ")
        XCTAssertEqual(enter("- [x] 끝"), "- [x] 끝\n- [ ] ")
        XCTAssertEqual(enter("> 인용"), "> 인용\n> ")
        XCTAssertEqual(enter("- "), "")
        XCTAssertNil(enter("그냥 글"))
        XCTAssertNil(enter("```\n- 코드 안"))
    }

    func testIndent() {
        let r = EditorCommands.indent(text: "- a\n- b", selections: [NSRange(location: 4, length: 0)], outdent: false)
        XCTAssertEqual(r.apply(to: "- a\n- b"), "- a\n  - b")
        XCTAssertEqual(r.selection.location, 6)
        let o = EditorCommands.indent(text: "  - b", selections: [NSRange(location: 3, length: 0)], outdent: true)
        XCTAssertEqual(o.apply(to: "  - b"), "- b")
    }
}

final class HighlighterTests: XCTestCase {
    private func styles(_ text: String) -> [String: HighlightStyle] {
        var out: [String: HighlightStyle] = [:]
        for s in MarkdownHighlighter.spans(for: text) where out[(text as NSString).substring(with: s.range)] == nil {
            out[(text as NSString).substring(with: s.range)] = s.style
        }
        return out
    }

    func testBasicSpans() {
        let s = styles("## 제목\n**굵게** 와 [링크](https://a.com)\n```\n# 코드 안\n```\n> 인용")
        XCTAssertEqual(s["##"], .syntax)
        XCTAssertEqual(s["제목"], .heading(2))
        XCTAssertEqual(s["굵게"], .strong)
        XCTAssertEqual(s["링크"], .link)
        XCTAssertEqual(s["https://a.com"], .url)
        XCTAssertEqual(s["# 코드 안"], .code)
        XCTAssertEqual(s["인용"], .quote)
    }
}

final class FileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdstudio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testListingRules() throws {
        let fm = FileManager.default
        for p in ["가.md", "나/다.markdown", "나/라.txt", "그림.png", ".숨김.md", "node_modules/x.md", ".git/y.md",
                  "1/2/3/4/깊이4.md", "1/2/3/4/5/깊이5.md"] {
            let url = dir.appendingPathComponent(p)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let paths = try FileStore.listMarkdownFiles(in: dir).entries.map(\.path)
        XCTAssertEqual(paths, ["1/2/3/4/깊이4.md", "가.md", "나/다.markdown", "나/라.txt"])
    }

    func testSafeWriteAndUniqueNames() throws {
        let url = dir.appendingPathComponent("문서.md")
        try FileStore.writeSafely("하나", to: url)
        try FileStore.writeSafely("둘", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "둘")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".문서.md.mdstudio-tmp").path))
        let second = try FileStore.createFile(in: dir, name: "문서.md")
        XCTAssertEqual(second.lastPathComponent, "문서 2.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "둘", "기존 파일을 덮어쓰면 안 됩니다")
    }

    func testCleanFileName() {
        XCTAssertEqual(FileStore.cleanFileName("a/b:c*?\"<>|"), "abc.md")
        XCTAssertEqual(FileStore.cleanFileName("  "), "새 문서.md")
        XCTAssertEqual(FileStore.cleanFileName("메모.markdown"), "메모.markdown")
        XCTAssertEqual(FileStore.cleanFileName("보고서", ext: "pdf"), "보고서.pdf")
        XCTAssertEqual(FileStore.cleanFileName(".숨김"), "숨김.md")
    }

    func testReadStripsBOM() throws {
        let url = dir.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("# 제목".utf8)).write(to: url)
        XCTAssertEqual(try FileStore.read(url).text, "# 제목")
    }

    func testDrafts() {
        let store = DraftStore(directory: dir.appendingPathComponent("drafts"))
        XCTAssertNil(store.load("untitled"))
        store.save("임시", for: "untitled")
        XCTAssertEqual(store.load("untitled")?.text, "임시")
        store.save("파일", for: "file:/a/b.md")
        XCTAssertEqual(store.load("file:/a/b.md")?.text, "파일")
        store.clear("untitled")
        XCTAssertNil(store.load("untitled"))
        XCTAssertEqual(store.load("file:/a/b.md")?.text, "파일")
    }

    func testSettingsDefaultsAndTolerantDecoding() throws {
        let suite = "mdstudio.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let d = store.load()
        XCTAssertEqual(d.tableMode, "title")
        XCTAssertTrue(d.breaks && d.pasteConvert && d.autosave && d.syncScroll && d.lineWrap)
        XCTAssertEqual(d.editorFont, .sans)
        XCTAssertEqual(d.editorFontSize, 15)
        XCTAssertEqual(d.theme, .system)
        // 일부만 있거나 모르는 값이 있어도 나머지는 살린다.
        defaults.set(Data(#"{"tableMode":"grid","theme":"purple","editorFontSize":18}"#.utf8), forKey: "md-studio.settings")
        let s = store.load()
        XCTAssertEqual(s.tableMode, "grid")
        XCTAssertEqual(s.theme, .system)
        XCTAssertEqual(s.editorFontSize, 18)
        XCTAssertTrue(s.autosave)
    }

    func testSampleDocMatchesWebVersion() throws {
        // src/sample.js의 예제 문서와 글자 하나까지 같아야 한다.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try String(contentsOf: repo.appendingPathComponent("src/sample.js"), encoding: .utf8)
        let start = try XCTUnwrap(js.range(of: "export const SAMPLE_DOC = `"))
        let end = try XCTUnwrap(js.range(of: "`;", options: .backwards))
        let raw = String(js[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "\\`", with: "`")
        XCTAssertEqual(SampleDoc.text, raw)
    }
}

final class OutputTests: XCTestCase {
    func testClipboardHoldsAllFormatsInOneItem() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("mdstudio.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rtf = Clipboard.richRTF("# 제목\n\n| a | b |\n|---|---|\n| 1 | 2 |", options: MDOptions())
        XCTAssertNotNil(rtf)
        try Clipboard.write(ClipboardPayload(html: "<b>굵게</b>", text: "굵게", rtf: rtf), to: pb)
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertEqual(pb.string(forType: .html), "<b>굵게</b>")
        XCTAssertEqual(pb.string(forType: .string), "굵게")
        let attr = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(pb.data(forType: .rtf)), documentAttributes: nil))
        XCTAssertTrue(attr.string.contains("제목"))
        // RTF에 표가 표 구조로 들어갔는지
        let ps = attr.attribute(.paragraphStyle, at: (attr.string as NSString).range(of: "a").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(ps?.textBlocks.first is NSTextTableBlock, "RTF 표가 표가 아닙니다")
    }

    func testPDFIsA4() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdstudio-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReportExporter.writePDF(SampleDoc.text, options: ReportOptions(title: "테스트"), to: url)
        let data = try Data(contentsOf: url)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertGreaterThanOrEqual(pdf.numberOfPages, 1)
        let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 595.28, accuracy: 1)
        XCTAssertEqual(box.height, 841.89, accuracy: 1)
    }

    func testDocRendererStructure() {
        let attr = DocRenderer.render("# 제목\n\n- [x] 끝\n\n| a | b |\n|:-|-:|\n| 1 | 2 |\n\n```\ncode\n```\n\n> 인용",
                                      style: PreviewStyle(palette: .light), options: MDOptions())
        let s = attr.string as NSString
        XCTAssertTrue(attr.string.contains("☑\t끝"))
        let cell = attr.attribute(.paragraphStyle, at: s.range(of: "2").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(cell?.textBlocks.last is NSTextTableBlock)
        XCTAssertEqual(cell?.alignment, .right)
        let code = attr.attribute(.font, at: s.range(of: "code").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(code?.isFixedPitch == true)
        let quote = attr.attribute(.paragraphStyle, at: s.range(of: "인용").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(quote?.textBlocks.count, 1)
    }

    /// 미리보기를 PNG로 저장한다(MDSTUDIO_SNAPSHOT_DIR이 있을 때만).
    func testWriteSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["MDSTUDIO_SNAPSHOT_DIR"] else { throw XCTSkip("스냅숏 폴더 없음") }
        let docs: [(String, NSAttributedString)] = [
            ("doc-light", DocRenderer.render(SampleDoc.text, style: PreviewStyle(palette: .light), options: MDOptions())),
            ("doc-dark", DocRenderer.render(SampleDoc.text, style: PreviewStyle(palette: .dark), options: MDOptions())),
            ("slack-light", SlackPreviewRenderer.renderMock(slackHTML: MDConverter.toSlackHtml(SampleDoc.text), palette: .light)),
            ("plain-light", PlainPreviewRenderer.render(MDConverter.toPlainText(SampleDoc.text), palette: .light)),
            ("report-light", ReportExporter.reportAttributed(SampleDoc.text, options: ReportOptions(title: "보고서"))),
        ]
        for (name, attr) in docs {
            let (scroll, view) = PreviewTextView.make()
            view.appearance = NSAppearance(named: name.hasSuffix("dark") ? .darkAqua : .aqua)
            view.backgroundColor = name.hasSuffix("dark") ? Palette.dark.bg : Palette.light.bg
            scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
            view.textStorage?.setAttributedString(attr)
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

final class EditorPerformanceTests: XCTestCase {
    /// 긴 문서(약 5,000줄)에서 글자 하나 입력에 걸리는 시간을 단계별로 잰다.
    func testTypingInLongDocument() {
        var big = ""
        for i in 0..<1000 { big += "## 절 \(i)\n\n본문 **굵게** 와 [링크](https://e.com/\(i)) 그리고 `코드`.\n\n- 항목\n\n" }
        let (scroll, editor) = EditorTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        editor.setText(big, keepHistory: false)
        window.displayIfNeeded()
        var times: [Double] = []
        for i in 0..<5 {
            let t = Date()
            editor.insertText("가", replacementRange: NSRange(location: i * 3, length: 0))
            window.displayIfNeeded()
            times.append(Date().timeIntervalSince(t) * 1000)
        }
        let t2 = Date()
        _ = MDConverter.stats(editor.string)
        let statsMs = Date().timeIntervalSince(t2) * 1000
        print("입력 ms: \(times.map { Int($0) }), 통계 ms: \(Int(statsMs)), 글자 수: \(editor.string.utf16.count)")
        XCTAssertLessThan(times.dropFirst().max() ?? 0, 50, "글자 하나 입력이 느립니다")
    }
}
