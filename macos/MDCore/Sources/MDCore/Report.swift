// HTML 보고서와 문서 통계.
// - buildReportHtml: 제목·날짜·목차·본문·꼬리말이 있는 HTML 파일 한 장 (src/output.js buildReportHtml과 같은 구조, CSS는 원본 그대로)
// - stats: 글자 수·단어 수·줄 수 (src/convert.js stats와 같은 규칙)
// 의존성: Foundation
import Foundation

/// 보고서 옵션
public struct ReportOptions: Equatable, Sendable {
    /// 보고서 제목. 비어 있으면 "문서"
    public var title: String
    /// 소제목(h2·h3)이 3개 이상일 때 목차 넣기
    public var includeToc: Bool
    /// 제목 아래에 작성 날짜 넣기
    public var includeDate: Bool
    /// 줄바꿈 옵션
    public var render: MDOptions

    public init(title: String, includeToc: Bool = true, includeDate: Bool = true, render: MDOptions = MDOptions()) {
        self.title = title
        self.includeToc = includeToc
        self.includeDate = includeDate
        self.render = render
    }
}

/// 문서 통계
public struct DocStats: Equatable, Sendable {
    /// 공백을 뺀 글자 수
    public var chars: Int
    /// 공백으로 나눈 단어 수
    public var words: Int
    /// 줄 수 (빈 문서는 0)
    public var lines: Int
}

extension MDConverter {
    /// 날짜를 "2026년 10월 26일" 형식으로 쓴다.
    public static func koreanDate(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var cal = calendar
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)년 \(c.month ?? 0)월 \(c.day ?? 0)일"
    }

    /// HTML 보고서 파일 내용을 만든다.
    ///
    /// - Parameters:
    ///   - markdown: 마크다운 원문
    ///   - options: 제목, 목차·날짜 여부, 줄바꿈 옵션
    ///   - date: 보고서에 넣을 날짜 (기본: 지금)
    /// - Returns: `<!doctype html>`로 시작하는 완성된 HTML 문서
    public static func buildReportHtml(_ markdown: String, options: ReportOptions, date: Date = Date()) -> String {
        MDLog.measure("report", inputLength: markdown.utf8.count) {
            var blocks = MarkdownTree.parse(markdown)
            var renderer = DocHTMLRenderer(mode: .report, options: options.render)
            let title = options.title
            // 본문 첫 제목이 보고서 제목과 같으면 중복이므로 뺀다. (id 번호는 원본처럼 먼저 차지해 둔다)
            if case .heading(1, let content)? = blocks.first,
               TextUtils.jsTrim(PlainRenderer.inlineText(content, inCell: false)) == TextUtils.jsTrim(title) {
                _ = renderer.slug(for: TextUtils.jsTrim(PlainRenderer.inlineText(content, inCell: false)))
                blocks.removeFirst()
            }
            let body = renderer.blocks(blocks)

            var toc = ""
            let heads = renderer.headings.filter { $0.level == 2 || $0.level == 3 }
            if options.includeToc && heads.count >= 3 {
                let items = heads.map { h in
                    "<li class=\"lv\(h.level)\"><a href=\"#\(TextUtils.escapeDecodedText(h.id))\">\(TextUtils.escapeDecodedText(h.text))</a></li>"
                }.joined()
                toc = "<nav class=\"toc\"><div class=\"toc-title\">목차</div><ol>\(items)</ol></nav>"
            }
            let dateStr = koreanDate(date)
            let meta = options.includeDate ? "<div class=\"report-meta\">\(dateStr)</div>" : ""
            let safeTitle = TextUtils.escapeDecodedText(title.isEmpty ? "문서" : title)

            return """
            <!doctype html>
            <html lang="ko">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(safeTitle)</title>
            <style>
            \(WebStyles.reportCSS)
            </style>
            </head>
            <body>
            <main class="page">
            <header class="report-header"><h1>\(safeTitle)</h1>\(meta)</header>
            \(toc)
            <article class="content">
            \(body)
            </article>
            <footer class="report-footer">MD Studio에서 생성 · \(dateStr)</footer>
            </main>
            </body>
            </html>

            """
        }
    }

    /// 글자 수·단어 수·줄 수. 글자 수는 원본(JavaScript)처럼 UTF-16 단위로 센다.
    public static func stats(_ markdown: String) -> DocStats {
        var chars = 0
        var words = 0
        var inWord = false
        for unit in markdown.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(unit) || unit == "\u{FEFF}"
            if isSpace {
                inWord = false
            } else {
                chars += unit.utf16.count
                if !inWord { words += 1 }
                inWord = true
            }
        }
        let lines = markdown.isEmpty ? 0 : markdown.components(separatedBy: "\n").count
        return DocStats(chars: chars, words: words, lines: lines)
    }
}
