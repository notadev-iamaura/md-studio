// 붙여넣기 변환: 웹·Google Docs·Notion에서 복사한 서식 있는 HTML을 마크다운으로 바꾼다.
// - 판정 규칙은 src/output.js의 convertPaste와 같다.
//   1) 텍스트가 이미 마크다운처럼 보이면 변환하지 않는다(nil).
//   2) HTML에 서식 정보(제목, 굵게, 목록, 표, 링크 등)가 없으면 변환하지 않는다(nil).
//   3) 그 외에는 HTML을 마크다운으로 바꾼다. 원본은 turndown 라이브러리를 썼고, 여기서는 같은 규칙을 직접 구현했다.
// - HTML 분석에는 Foundation의 XMLDocument(HTML 정리 기능)를 쓴다. 브라우저 엔진을 띄우지 않는다.
// - Google Docs 함정: 문서 전체를 <b id="docs-internal-guid…" style="font-weight:normal">로 감싸고,
//   굵게·기울임은 <span style="font-weight:700">, font-style:italic으로 표현한다.
// 의존성: Foundation (XMLDocument)
import Foundation

public enum PasteConverter {
    private static let looksLikeMarkdown = Pattern(
        "(^|\\n)\\s{0,3}(#{1,6}\\s|[-*+]\\s|\\d+\\.\\s|>\\s|```|\\|.*\\|)|\\*\\*[^*\\n]+\\*\\*|\\[[^\\]\\n]+\\]\\([^)\\s]+\\)"
    )
    private static let semanticHTML = Pattern(
        "<(h[1-6]|strong|b|em|i|ul|ol|li|table|a\\s|code|pre|blockquote|img)\\b|font-weight:\\s*(bold|[6-9]00)",
        .caseInsensitive
    )

    /// 텍스트가 이미 마크다운처럼 보이는지 (줄 시작이 #, -, 1., >, ```, |…| 이거나 **굵게**, [a](b)가 있음)
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        looksLikeMarkdown.matches(text)
    }

    /// HTML에 마크다운으로 옮길 서식 정보가 있는지
    public static func hasSemanticHTML(_ html: String) -> Bool {
        semanticHTML.matches(html)
    }

    /// 붙여넣을 마크다운을 정한다. nil이면 평소처럼 텍스트를 그대로 붙인다.
    ///
    /// - Parameters:
    ///   - html: 클립보드의 HTML (없으면 nil)
    ///   - text: 클립보드의 일반 텍스트
    /// - Returns: 변환한 마크다운, 변환할 필요가 없으면 nil
    /// - Throws: HTML을 전혀 읽을 수 없을 때. 호출 측은 기록한 뒤 원문 텍스트로 붙인다.
    public static func convertPaste(html: String?, text: String?) throws -> String? {
        guard let html, !html.isEmpty else { return nil }
        if let text, looksLikeMarkdown(text) {
            MDLog.core.debug("붙여넣기: 텍스트가 이미 마크다운이라 그대로 사용")
            return nil
        }
        if !hasSemanticHTML(html) {
            MDLog.core.debug("붙여넣기: 서식 정보가 없는 HTML이라 텍스트 사용")
            return nil
        }
        let md = try MDLog.measure("paste", inputLength: html.utf8.count) { try htmlToMarkdown(html) }
        return md.isEmpty ? nil : md
    }

    /// HTML을 마크다운으로 바꾼다.
    public static func htmlToMarkdown(_ html: String) throws -> String {
        let root = try parseHTML(html)
        var converter = HTMLToMarkdown()
        let raw = converter.children(of: root)
        return HTMLToMarkdown.finalize(raw)
    }

    /// HTML 조각을 읽어 <body> 요소를 돌려준다.
    /// 클립보드 HTML은 인코딩 표시가 없거나 제각각이라, 껍데기를 벗기고 UTF-8 표시가 있는 <head>로 다시 감싼다.
    private static func parseHTML(_ html: String) throws -> XMLNode {
        // 이미 완성된 문서(<html>, <head>, <body>)로 온 경우 껍데기와 기존 인코딩 표시를 벗긴다.
        let stripped = Pattern("<!doctype[^>]*>|</?html[^>]*>|<head[\\s>][\\s\\S]*?</head>|</?body[^>]*>|<meta[^>]*>", .caseInsensitive)
            .replace(html, with: "")
        let wrapped = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
            + "<title></title></head><body>\(stripped)</body></html>"
        let doc = try XMLDocument(data: Data(wrapped.utf8), options: [.documentTidyHTML])
        // XHTML 이름공간 때문에 XPath 대신 직접 찾는다.
        func findBody(_ node: XMLNode) -> XMLNode? {
            if node.kind == .element, (node.localName ?? node.name ?? "").lowercased() == "body" { return node }
            for child in node.children ?? [] {
                if let found = findBody(child) { return found }
            }
            return nil
        }
        guard let body = doc.rootElement().flatMap(findBody) else {
            throw NSError(domain: "MDCore.Paste", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTML 본문을 찾지 못했습니다"])
        }
        return body
    }
}

/// turndown과 같은 규칙으로 HTML 나무를 마크다운 글자로 바꾼다.
/// 들여쓰기와 줄바꿈(<br>)은 임시 표시 문자로 넣어 두었다가 마지막 정리(finalize) 때 실제 글자로 바꾼다.
/// 그래야 정리 단계에서 공백을 지워도 의도한 들여쓰기는 남는다.
struct HTMLToMarkdown {
    /// 의도한 들여쓰기 한 칸
    static let indentMark: Character = "\u{E001}"
    /// <br> 줄바꿈
    static let breakMark = "\u{E000}"

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption",
        "address", "dl", "dt", "dd", "center", "form", "fieldset",
    ]
    private static let removedTags: Set<String> = [
        "head", "style", "script", "meta", "title", "noscript", "template", "iframe", "object", "svg", "button", "select",
    ]
    // turndown의 글자 이스케이프 규칙 (^는 글자 조각의 시작)
    private static let escapes: [(Pattern, String)] = [
        (Pattern("\\\\"), "\\\\\\\\"),
        (Pattern("\\*"), "\\\\*"),
        (Pattern("^-"), "\\\\-"),
        (Pattern("^\\+ "), "\\\\+ "),
        (Pattern("^(=+)"), "\\\\$1"),
        (Pattern("^(#{1,6}) "), "\\\\$1 "),
        (Pattern("`"), "\\\\`"),
        (Pattern("^~~~"), "\\\\~~~"),
        (Pattern("\\["), "\\\\["),
        (Pattern("\\]"), "\\\\]"),
        (Pattern("^>"), "\\\\>"),
        (Pattern("_"), "\\\\_"),
        (Pattern("^(\\d+)\\. "), "$1\\\\. "),
    ]
    private static let boldStyle = Pattern("font-weight:\\s*(bold|[6-9]00)", .caseInsensitive)
    private static let normalWeight = Pattern("font-weight:\\s*(normal|[1-4]00)", .caseInsensitive)
    private static let italicStyle = Pattern("font-style:\\s*italic", .caseInsensitive)
    private static let spaces = Pattern("[ \\t\\r\\n\\f]+")

    /// 목록 안에 있는지 (하위 목록 처리용)
    private var listDepth = 0

    // MARK: - 나무 걷기

    mutating func children(of node: XMLNode) -> String {
        (node.children ?? []).map { convert($0) }.joined()
    }

    private mutating func convert(_ node: XMLNode) -> String {
        switch node.kind {
        case .text:
            return text(node.stringValue ?? "")
        case .element:
            guard let el = node as? XMLElement else { return "" }
            return element(el)
        default:
            return ""
        }
    }

    private func text(_ raw: String) -> String {
        // 공백 여러 개(줄바꿈 포함)는 띄어쓰기 하나로. 줄바꿈 없는 공백(nbsp)도 일반 공백으로 바꾼다.
        let collapsed = Self.spaces.replace(raw.replacingOccurrences(of: "\u{00A0}", with: " "), with: " ")
        var out = collapsed
        for (pattern, template) in Self.escapes {
            out = pattern.regex.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        return out
    }

    private static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue ?? el.attributes?.first { $0.name?.lowercased() == name }?.stringValue
    }

    private mutating func element(_ el: XMLElement) -> String {
        let tag = (el.localName ?? el.name ?? "").lowercased()
        if Self.removedTags.contains(tag) { return "" }
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 1
            let content = Self.flatten(children(of: el))
            return content.isEmpty ? "" : "\n\n\(String(repeating: "#", count: level)) \(content)\n\n"
        case "p":
            return block(children(of: el))
        case "br":
            return Self.breakMark
        case "hr":
            return "\n\n---\n\n"
        case "b", "strong":
            let style = Self.attr(el, "style") ?? ""
            let id = Self.attr(el, "id") ?? ""
            // Google Docs의 문서 전체 감싸기와 font-weight:normal은 굵게가 아니다.
            if id.hasPrefix("docs-internal-guid") || Self.normalWeight.matches(style) { return children(of: el) }
            return Self.delimit(children(of: el), "**")
        case "i", "em":
            return Self.delimit(children(of: el), "*")
        case "s", "del", "strike":
            return Self.delimit(children(of: el), "~~")
        case "span":
            let style = Self.attr(el, "style") ?? ""
            var out = children(of: el)
            if Self.italicStyle.matches(style) { out = Self.delimit(out, "*") }
            if Self.boldStyle.matches(style) { out = Self.delimit(out, "**") }
            return out
        case "code":
            return Self.inlineCode(el.stringValue ?? "")
        case "pre":
            return pre(el)
        case "a":
            let label = children(of: el)
            let href = TextUtils.safeHref(Self.attr(el, "href"))
            if TextUtils.jsTrim(label).isEmpty { return label }
            return href.isEmpty ? label : "[\(label)](\(href.replacingOccurrences(of: " ", with: "%20")))"
        case "img":
            let src = TextUtils.safeHref(Self.attr(el, "src"))
            if src.isEmpty { return "" }
            let alt = (Self.attr(el, "alt") ?? "").replacingOccurrences(of: "\n", with: " ")
            return "![\(alt)](\(src))"
        case "ul", "ol":
            return list(el, ordered: tag == "ol")
        case "li":
            // 목록 밖에 떨어진 항목
            return block(children(of: el))
        case "blockquote":
            let inner = HTMLToMarkdown.finalize(children(of: el))
            if inner.isEmpty { return "" }
            let quoted = inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        case "table":
            return table(el)
        case "input":
            // 할 일 목록 체크박스 (목록 처리에서 쓴다)
            if (Self.attr(el, "type") ?? "").lowercased() == "checkbox" {
                return el.attribute(forName: "checked") != nil ? "[x] " : "[ ] "
            }
            return ""
        default:
            let inner = children(of: el)
            return Self.blockTags.contains(tag) ? block(inner) : inner
        }
    }

    private func block(_ content: String) -> String {
        let trimmed = Self.trimEdges(content)
        return trimmed.isEmpty ? "" : "\n\n\(trimmed)\n\n"
    }

    // MARK: - 개별 규칙

    /// 굵게·기울임 기호로 감싼다. 앞뒤 공백은 기호 바깥으로 뺀다(turndown과 같음).
    private static func delimit(_ content: String, _ mark: String) -> String {
        let core = content.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if core.isEmpty || core == breakMark { return content }
        let lead = content.prefix { $0 == " " }
        let trail = String(content.reversed().prefix { $0 == " " })
        return "\(lead)\(mark)\(core)\(mark)\(trail)"
    }

    private static func inlineCode(_ code: String) -> String {
        let flat = code.replacingOccurrences(of: "\n", with: " ")
        if flat.isEmpty { return "" }
        // 코드 안의 ` 개수보다 하나 많은 `로 감싼다.
        var longest = 0, run = 0
        for ch in flat {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = flat.hasPrefix("`") || flat.hasSuffix("`") ? " " : ""
        return "\(fence)\(pad)\(flat)\(pad)\(fence)"
    }

    private func pre(_ el: XMLElement) -> String {
        var code = el.stringValue ?? ""
        while code.hasSuffix("\n") { code.removeLast() }
        while code.hasPrefix("\n") { code.removeFirst() }
        var lang = ""
        if let codeEl = (el.children ?? []).compactMap({ $0 as? XMLElement })
            .first(where: { ($0.localName ?? $0.name ?? "").lowercased() == "code" }),
           let cls = HTMLToMarkdown.attr(codeEl, "class"),
           let r = cls.range(of: "language-") {
            lang = String(cls[r.upperBound...].prefix { !$0.isWhitespace })
        }
        // 코드 안에 ``` 가 있으면 더 긴 울타리를 쓴다.
        let fence = code.contains("```") ? "````" : "```"
        // 코드 줄은 마지막 정리에서 공백을 지우지 않도록 표시해 둔다.
        let protected = code.components(separatedBy: "\n").map { "\u{E002}" + $0 }.joined(separator: "\n")
        return "\n\n\(fence)\(lang)\n\(protected)\n\(fence)\n\n"
    }

    private mutating func list(_ el: XMLElement, ordered: Bool) -> String {
        let start = Int(Self.attr(el, "start") ?? "") ?? 1
        let items = (el.children ?? []).compactMap { $0 as? XMLElement }.filter { ($0.localName ?? $0.name ?? "").lowercased() == "li" }
        var lines: [String] = []
        listDepth += 1
        for (idx, li) in items.enumerated() {
            let marker = ordered ? "\(start + idx). " : "- "
            var content = HTMLToMarkdown.finalize(children(of: li), keepMarks: true)
            if content.isEmpty { content = "" }
            let pad = String(repeating: Self.indentMark, count: marker.count)
            let parts = content.components(separatedBy: "\n")
            var out = marker + (parts.first ?? "")
            for line in parts.dropFirst() {
                out += "\n" + (line.isEmpty ? "" : pad + line)
            }
            lines.append(out)
        }
        listDepth -= 1
        let body = lines.joined(separator: "\n")
        // 목록 안의 하위 목록은 빈 줄 없이 붙인다(촘촘한 목록 유지).
        return listDepth > 0 ? "\n\(body)\n" : "\n\n\(body)\n\n"
    }

    private mutating func table(_ el: XMLElement) -> String {
        var rows: [[String]] = []
        func collect(_ node: XMLElement) {
            for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
                let name = (child.localName ?? child.name ?? "").lowercased()
                if name == "tr" {
                    let cells = (child.children ?? []).compactMap { $0 as? XMLElement }
                        .filter { ["td", "th"].contains(($0.localName ?? $0.name ?? "").lowercased()) }
                        .map { cell -> String in
                            var conv = HTMLToMarkdown()
                            let md = HTMLToMarkdown.flatten(conv.children(of: cell))
                            return md.replacingOccurrences(of: "|", with: "\\|")
                        }
                    rows.append(cells)
                } else if ["thead", "tbody", "tfoot"].contains(name) {
                    collect(child)
                }
            }
        }
        collect(el)
        guard let header = rows.first else { return "" }
        let cols = max(1, rows.map(\.count).max() ?? 1)
        func line(_ cells: [String]) -> String {
            "| " + (0..<cols).map { $0 < cells.count ? cells[$0] : "" }.joined(separator: " | ") + " |"
        }
        let sep = "| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |"
        let body = ([line(header), sep] + rows.dropFirst().map(line)).joined(separator: "\n")
        return "\n\n\(body)\n\n"
    }

    // MARK: - 정리

    /// 한 줄로 만든다(제목·표 칸). 줄바꿈은 띄어쓰기로.
    private static func flatten(_ s: String) -> String {
        let joined = s.replacingOccurrences(of: breakMark, with: " ").replacingOccurrences(of: "\n", with: " ")
        return TextUtils.jsTrim(spaces.replace(joined, with: " ")).replacingOccurrences(of: String(indentMark), with: "")
    }

    /// 덩어리 앞뒤의 공백·빈 줄을 지운다.
    private static func trimEdges(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t"))
    }

    /// 마지막 정리: 줄마다 앞뒤 공백을 지우고, 표시 문자를 실제 들여쓰기·줄바꿈으로 바꾸고, 빈 줄을 2개까지만 남긴다.
    /// keepMarks가 참이면 표시 문자를 남겨 둔다(바깥 목록이 한 번 더 들여쓰기 때문).
    static func finalize(_ s: String, keepMarks: Bool = false) -> String {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            if line.contains("\u{E002}") {
                // 코드 줄: 의도한 들여쓰기 뒤의 내용은 손대지 않는다.
                return line
            }
            return line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        var text = lines.joined(separator: "\n")
        // <br>: 줄 끝 공백 두 개 + 줄바꿈 (마크다운의 강제 줄바꿈)
        text = text.replacingOccurrences(of: " \(breakMark)", with: breakMark)
        text = text.replacingOccurrences(of: "\(breakMark) ", with: breakMark)
        text = text.replacingOccurrences(of: breakMark, with: "  \n")
        text = Pattern("\\n{3,}").replace(text, with: "\n\n")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t"))
        if !keepMarks {
            text = text.replacingOccurrences(of: String(indentMark), with: " ").replacingOccurrences(of: "\u{E002}", with: "")
            // 강제 줄바꿈 뒤 바로 끝나는 줄의 공백은 지운다.
            text = text.components(separatedBy: "\n").map { line in
                line.hasSuffix("  ") && line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line
            }.joined(separator: "\n")
        }
        return text
    }
}
