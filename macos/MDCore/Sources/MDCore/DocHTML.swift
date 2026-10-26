// 문서용 HTML 만들기: 서식 복사(Google Docs·Word·메일)와 HTML 보고서의 본문으로 쓴다.
// - 원본은 marked로 HTML을 만든 뒤 DOMPurify로 정제했다. 여기서는 처음부터 안전한 태그만 만든다.
//   마크다운 안에 직접 쓴 HTML 태그는 글자만 남긴다(<br>은 줄바꿈). 위험한 링크는 버린다.
// - 서식 복사 모드: 붙여넣는 앱이 <style>을 버리므로 모든 스타일을 태그에 직접 넣는다(src/output.js toRichCopyHtml).
// - 보고서 모드: 제목에 앵커 id를 붙이고, 표를 가로 스크롤 영역으로 감싼다(src/output.js buildReportHtml).
// 의존성: 없음 (MDCore 내부)
import Foundation

/// 보고서 목차에 쓰는 제목 정보
struct HeadingRef: Equatable {
    var level: Int
    var id: String
    var text: String
}

struct DocHTMLRenderer {
    enum Mode {
        /// 서식 복사: 인라인 스타일, id 없음, 체크박스는 ☑/☐ 문자
        case richCopy
        /// 보고서: 제목 id, 표 감싸기, 체크박스는 input
        case report
    }

    let mode: Mode
    let options: MDOptions
    /// 만든 제목 목록(목차용). render 후에 채워진다.
    private(set) var headings: [HeadingRef] = []
    private var usedSlugs: [String: Int] = [:]

    init(mode: Mode, options: MDOptions) {
        self.mode = mode
        self.options = options
    }

    // MARK: - 공통 도구

    private var inlineStyled: Bool { mode == .richCopy }

    /// 여는 태그. 서식 복사 모드면 표에 정해진 스타일을 붙인다.
    private func open(_ tag: String, attrs: String = "", extraStyle: String = "", replaceStyle: String? = nil) -> String {
        guard inlineStyled else { return "<\(tag)\(attrs)>" }
        let style = (replaceStyle ?? (WebStyles.inlineStyles[tag] ?? "")) + extraStyle
        return style.isEmpty ? "<\(tag)\(attrs)>" : "<\(tag)\(attrs) style=\"\(style)\">"
    }

    private static func attr(_ s: String) -> String {
        TextUtils.escapeDecodedText(s).replacingOccurrences(of: "'", with: "&#39;")
    }

    /// 제목 글자로 앵커 id를 만든다. 같은 이름이 있으면 -1, -2를 붙인다(원본 slugify와 같음).
    mutating func slug(for text: String) -> String {
        let base = Self.slugify(text)
        let n = usedSlugs[base] ?? 0
        usedSlugs[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }

    static func slugify(_ text: String) -> String {
        let lowered = TextUtils.jsTrim(text).lowercased()
        var kept = ""
        for ch in lowered where ch.isLetter || ch.isNumber || ch.isWhitespace || ch == "-" {
            kept.append(ch)
        }
        var out = ""
        var inSpace = false
        for ch in kept {
            if ch.isWhitespace {
                if !inSpace { out.append("-") }
                inSpace = true
            } else {
                out.append(ch)
                inSpace = false
            }
        }
        return out.isEmpty ? "section" : out
    }

    // MARK: - 한 줄 서식

    func inline(_ items: [Inline]) -> String {
        var out = ""
        for item in items {
            switch item {
            case .text(let s):
                out += TextUtils.escapeDecodedText(s)
            case .strong(let c):
                out += "\(open("strong"))\(inline(c))</strong>"
            case .emphasis(let c):
                out += "\(open("em"))\(inline(c))</em>"
            case .strikethrough(let c):
                out += "\(open("del"))\(inline(c))</del>"
            case .code(let s):
                out += "\(open("code"))\(TextUtils.escapeDecodedText(s))</code>"
            case .softBreak:
                out += options.breaks ? "<br>" : "\n"
            case .lineBreak:
                out += "<br>"
            case .link(let href, let children):
                let safe = TextUtils.safeHref(href)
                let label = inline(children)
                out += safe.isEmpty ? label : "\(open("a", attrs: " href=\"\(Self.attr(safe))\""))\(label)</a>"
            case .image(let source, let alt):
                let safe = TextUtils.safeHref(source)
                if safe.isEmpty {
                    out += TextUtils.escapeDecodedText(alt)
                } else {
                    out += open("img", attrs: " src=\"\(Self.attr(safe))\" alt=\"\(Self.attr(alt))\"")
                }
            case .html(let raw):
                out += TextUtils.isBrHtml(raw) ? "<br>" : TextUtils.escapeDecodedText(TextUtils.stripTags(raw))
            }
        }
        return out
    }

    // MARK: - 덩어리

    mutating func blocks(_ list: [Block]) -> String {
        list.map { block($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private mutating func block(_ b: Block) -> String {
        switch b {
        case .heading(let level, let content):
            let lv = min(max(level, 1), 6)
            let html = inline(content)
            if inlineStyled { return "\(open("h\(lv)"))\(html)</h\(lv)>" }
            let text = TextUtils.jsTrim(PlainRenderer.inlineText(content, inCell: false))
            let id = slug(for: text)
            headings.append(HeadingRef(level: lv, id: id, text: text))
            return "<h\(lv) id=\"\(Self.attr(id))\">\(html)</h\(lv)>"
        case .paragraph(let content):
            return "\(open("p"))\(inline(content))</p>"
        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items)
        case .table(let t):
            let html = table(t)
            return mode == .report ? "<div class=\"table-wrap\">\(html)</div>" : html
        case .code(let s):
            let codeOpen = inlineStyled ? open("code", replaceStyle: "font-family:inherit;") : "<code>"
            return "\(open("pre"))\(codeOpen)\(TextUtils.escapeDecodedText(s))\n</code></pre>"
        case .blockquote(let children):
            return "\(open("blockquote"))\n\(blocks(children))\n</blockquote>"
        case .thematicBreak:
            return open("hr")
        case .html(let raw):
            let text = TextUtils.jsTrim(TextUtils.stripTags(raw))
            return text.isEmpty ? "" : "\(open("p"))\(TextUtils.escapeDecodedText(text))</p>"
        }
    }

    private mutating func list(ordered: Bool, start rawStart: Int, items: [ListItemNode]) -> String {
        let tag = ordered ? "ol" : "ul"
        let start = rawStart == 0 ? 1 : rawStart
        let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
        var lis = ""
        for item in items {
            var body = ""
            var liExtra = ""
            if let checked = item.checked {
                if inlineStyled {
                    // 체크박스는 대부분의 앱에서 사라지므로 문자로 바꾸고 글머리 기호를 없앤다.
                    body += checked ? "☑ " : "☐ "
                    liExtra = "list-style-type: none;"
                } else {
                    body += checked ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> "
                }
            }
            // 문단 하나(+하위 목록)뿐인 항목은 <p> 없이 쓴다. marked의 "촘촘한 목록"과 같은 모양이다.
            let paragraphs = item.children.filter { if case .paragraph = $0 { return true } else { return false } }
            let others = item.children.filter {
                switch $0 {
                case .paragraph, .list: return false
                default: return true
                }
            }
            let tight = paragraphs.count <= 1 && others.isEmpty
            for child in item.children {
                if tight, case .paragraph(let content) = child {
                    body += inline(content)
                } else {
                    body += block(child)
                }
            }
            lis += "\(open("li", extraStyle: liExtra))\(body)</li>\n"
        }
        return "\(open(tag, attrs: startAttr))\n\(lis)</\(tag)>"
    }

    private func table(_ t: TableNode) -> String {
        let cols = t.header.count
        func alignAttr(_ i: Int) -> (attr: String, style: String) {
            guard i < t.alignments.count, let a = t.alignments[i] else { return ("", "") }
            return inlineStyled ? ("", "text-align:\(a.rawValue);") : (" align=\"\(a.rawValue)\"", "")
        }
        var html = "\(open("table"))\n<thead>\n<tr>\n"
        for (i, cell) in t.header.enumerated() {
            let a = alignAttr(i)
            html += "\(open("th", attrs: a.attr, extraStyle: a.style))\(inline(cell))</th>\n"
        }
        html += "</tr>\n</thead>\n"
        if !t.rows.isEmpty {
            html += "<tbody>"
            for row in t.rows {
                html += "<tr>\n"
                for i in 0..<cols {
                    let cell: [Inline] = (i < row.count ? row[i] : nil) ?? []
                    let a = alignAttr(i)
                    html += "\(open("td", attrs: a.attr, extraStyle: a.style))\(inline(cell))</td>\n"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        return html + "</table>"
    }
}

// MARK: - 공개 입구

extension MDConverter {
    /// 서식 복사용 HTML. 모든 스타일이 태그 안에 들어 있어 Google Docs·Word·Gmail·Notion에 그대로 붙는다.
    ///
    /// - Parameters:
    ///   - markdown: 마크다운 원문
    ///   - options: 줄바꿈 옵션(표 변환 방식은 쓰지 않음)
    /// - Returns: `<div style=…>`로 감싼 HTML 조각
    public static func toRichCopyHtml(_ markdown: String, options: MDOptions = MDOptions()) -> String {
        MDLog.measure("rich", inputLength: markdown.utf8.count) {
            var r = DocHTMLRenderer(mode: .richCopy, options: options)
            let body = r.blocks(MarkdownTree.parse(markdown))
            return "<div style=\"font-family:\(WebStyles.fontStack);font-size:14px;color:#1f2328;line-height:1.6;\">\(body)</div>"
        }
    }

    /// 마크다운을 분석한 덩어리 목록. 앱의 미리보기가 이 구조로 화면을 그린다.
    public static func parse(_ markdown: String) -> [Block] {
        MarkdownTree.parse(markdown)
    }
}
