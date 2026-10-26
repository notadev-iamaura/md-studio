// 붙여넣기 변환, 서식 복사 HTML, 보고서, 통계 테스트.
// 붙여넣기 기대값은 웹 버전 화면 테스트(test/e2e.mjs의 '붙여넣기' 단계)와 같은 조건을 쓴다.
import Foundation
import XCTest
@testable import MDCore

final class PasteTests: XCTestCase {
    func testGoogleDocsHtmlBecomesMarkdown() throws {
        // test/e2e.mjs와 같은 입력: Docs의 감싸기 <b>, span 굵게, 목록, 표
        let html = """
        <b id="docs-internal-guid-1" style="font-weight:normal"><h2>회의록</h2><p>오늘은 <span style="font-weight:700">중요</span>합니다.</p><ul><li>하나</li></ul><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table></b>
        """
        let md = try XCTUnwrap(try PasteConverter.convertPaste(html: html, text: "회의록 오늘은 중요합니다."))
        XCTAssertTrue(md.contains("## 회의록"), md)
        XCTAssertTrue(md.contains("**중요**"), md)
        XCTAssertTrue(md.contains("- 하나"), md)
        XCTAssertTrue(md.contains("| a | b |"), md)
        XCTAssertFalse(md.hasPrefix("**"), "Google Docs 감싸기 태그가 굵게로 바뀌면 안 됩니다:\n\(md)")
        // 만든 마크다운이 다시 올바르게 읽히는지
        XCTAssertEqual(MDConverter.toPlainText(md), "■ 회의록\n오늘은 중요합니다.\n\n• 하나\n\n• 1: 2\n")
    }

    func testMarkdownTextIsKept() throws {
        XCTAssertNil(try PasteConverter.convertPaste(html: "<p><strong>제목</strong></p>", text: "## 제목\n\n- 이미 마크다운"))
    }

    func testPlainHtmlWithoutFormattingIsKept() throws {
        XCTAssertNil(try PasteConverter.convertPaste(html: "<p>그냥 글자</p>", text: "그냥 글자"))
        XCTAssertNil(try PasteConverter.convertPaste(html: nil, text: "글자"))
    }

    func testListsLinksCodeQuoteAndEscapes() throws {
        let html = """
        <h1>제목</h1><ol start="3"><li>셋<ul><li>하위 <a href="https://a.com/x y">링크</a></li></ul></li><li>넷</li></ol>
        <p>코드 <code>a`b</code> 와 <em>기울임</em>, 별표 * 와 밑줄_</p>
        <pre><code class="language-js">const a = 1;
          indent();</code></pre>
        <blockquote><p>인용 첫 줄</p><p>둘째</p></blockquote>
        <p>줄<br>바꿈</p><hr><ul><li><input type="checkbox" checked>끝</li><li><input type="checkbox">남음</li></ul>
        <img src="https://e.com/a.png" alt="로고"><a href="javascript:alert(1)">위험</a>
        """
        let md = try XCTUnwrap(try PasteConverter.convertPaste(html: html, text: ""))
        let expected = """
        # 제목

        3. 셋
           - 하위 [링크](https://a.com/x%20y)
        4. 넷

        코드 ``a`b`` 와 *기울임*, 별표 \\* 와 밑줄\\_

        ```js
        const a = 1;
          indent();
        ```

        > 인용 첫 줄
        >
        > 둘째

        줄\u{20}\u{20}
        바꿈

        ---

        - [x] 끝
        - [ ] 남음

        ![로고](https://e.com/a.png)위험
        """
        XCTAssertEqual(md, expected)
    }

    func testDetectionRules() {
        XCTAssertTrue(PasteConverter.looksLikeMarkdown("# 제목"))
        XCTAssertTrue(PasteConverter.looksLikeMarkdown("앞\n- 항목"))
        XCTAssertTrue(PasteConverter.looksLikeMarkdown("아주 **굵게** 글"))
        XCTAssertTrue(PasteConverter.looksLikeMarkdown("[a](https://b)"))
        XCTAssertFalse(PasteConverter.looksLikeMarkdown("평범한 문장입니다."))
        XCTAssertTrue(PasteConverter.hasSemanticHTML("<span style=\"font-weight: 700\">x</span>"))
        XCTAssertFalse(PasteConverter.hasSemanticHTML("<span>x</span>"))
    }
}

final class RichCopyTests: XCTestCase {
    func testInlineStylesAndCheckboxes() {
        let html = MDConverter.toRichCopyHtml("# 제목\n\n- [x] 끝\n- [ ] 남음\n\n| a | b |\n|:-|-:|\n| 1 | 2 |\n\n```\n<a>\n```\n\n`c` [링크](https://a.com)")
        XCTAssertTrue(html.hasPrefix("<div style=\"font-family:-apple-system"), html)
        XCTAssertFalse(html.contains("<style"), "서식 복사 HTML에 <style> 블록이 있으면 붙여넣는 앱이 버립니다")
        XCTAssertFalse(html.contains(" id=\""), "id는 지워야 합니다")
        XCTAssertTrue(html.contains("<h1 style=\"font-size:24px;font-weight:700;"), html)
        XCTAssertTrue(html.contains("☑ 끝") && html.contains("☐ 남음"), html)
        XCTAssertTrue(html.contains("list-style-type: none;"), html)
        XCTAssertFalse(html.contains("<input"), "체크박스는 문자로 바꿔야 합니다")
        XCTAssertTrue(html.contains("text-align:left;") && html.contains("text-align:right;"), html)
        XCTAssertTrue(html.contains("<pre style=") && html.contains("<code style=\"font-family:inherit;\">&lt;a&gt;"), html)
        XCTAssertTrue(html.contains("<a style=\"color:#0969da;text-decoration:underline;\" href=\"https://a.com\">링크</a>")
            || html.contains("<a href=\"https://a.com\" style=\"color:#0969da;text-decoration:underline;\">링크</a>"), html)
    }

    func testDangerousLinksAndRawHtmlAreRemoved() {
        let html = MDConverter.toRichCopyHtml("[x](javascript:alert(1)) <script>alert(1)</script>")
        XCTAssertFalse(html.contains("javascript:"), html)
        XCTAssertFalse(html.contains("<script"), html)
    }
}

final class ReportTests: XCTestCase {
    private let date: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 5
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func testReportStructure() {
        let md = "# 분기 보고\n\n## 요약\n본문\n\n## 요약\n\n### 세부\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let html = MDConverter.buildReportHtml(md, options: ReportOptions(title: "분기 보고"), date: date)
        XCTAssertTrue(html.hasPrefix("<!doctype html>\n<html lang=\"ko\">"), html)
        XCTAssertTrue(html.contains("<title>분기 보고</title>"))
        XCTAssertTrue(html.contains("<style>\n" + WebStyles.reportCSS + "\n</style>"), "CSS는 원본 그대로여야 합니다")
        XCTAssertTrue(html.contains("<div class=\"report-meta\">2026년 3월 5일</div>"))
        XCTAssertTrue(html.contains("<footer class=\"report-footer\">MD Studio에서 생성 · 2026년 3월 5일</footer>"))
        // 제목과 같은 첫 h1은 본문에서 뺀다
        XCTAssertFalse(html.contains("<h1 id="), html)
        // 소제목 3개 → 목차, 같은 이름은 -1
        XCTAssertTrue(html.contains("<nav class=\"toc\"><div class=\"toc-title\">목차</div><ol><li class=\"lv2\"><a href=\"#요약\">요약</a></li><li class=\"lv2\"><a href=\"#요약-1\">요약</a></li><li class=\"lv3\"><a href=\"#세부\">세부</a></li></ol></nav>"), html)
        XCTAssertTrue(html.contains("<div class=\"table-wrap\"><table>"), html)
    }

    func testReportOptionsOff() {
        let md = "## 하나\n\n## 둘\n\n## 셋"
        let html = MDConverter.buildReportHtml(md, options: ReportOptions(title: "", includeToc: false, includeDate: false), date: date)
        XCTAssertFalse(html.contains("<nav class=\"toc\">"))
        XCTAssertFalse(html.contains("<div class=\"report-meta\">"))
        XCTAssertTrue(html.contains("<title>문서</title>"))
    }
}

final class StatsTests: XCTestCase {
    // 기대값은 웹 버전 stats()로 계산했다.
    func testMatchesWebVersion() {
        XCTAssertEqual(MDConverter.stats(""), DocStats(chars: 0, words: 0, lines: 0))
        XCTAssertEqual(MDConverter.stats("a"), DocStats(chars: 1, words: 1, lines: 1))
        XCTAssertEqual(MDConverter.stats("한글 두 단어\n둘째 줄"), DocStats(chars: 8, words: 5, lines: 2))
        XCTAssertEqual(MDConverter.stats("😀 emoji\n\n"), DocStats(chars: 7, words: 2, lines: 3))
        XCTAssertEqual(MDConverter.stats("  공백  \t탭\n"), DocStats(chars: 3, words: 2, lines: 2))
    }

    func testSlugify() {
        XCTAssertEqual(DocHTMLRenderer.slugify("  Hello, World! 안녕 "), "hello-world-안녕")
        XCTAssertEqual(DocHTMLRenderer.slugify("!!!"), "section")
    }
}
