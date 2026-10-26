// 분석 나무(Block/Inline)를 최종 글자로 그리는 두 렌더러.
// - PlainRenderer: 텍스트 복사용 (convert.js의 inlinePlain, blockPlain, listPlain, blocksPlain)
// - SlackRenderer: Slack 복사용 HTML (convert.js의 inlineSlack, blockSlack, listSlack, toSlackHtml)
// 원본의 함수 구조와 순서를 그대로 따라서, 원본과 나란히 놓고 비교할 수 있게 했다.
// 의존성: 없음 (MDCore 내부)
import Foundation

private let bullets = ["•", "◦", "▪"]
private let indentUnit = "   "
private let hrText = String(repeating: "─", count: 20)

// MARK: - 텍스트

struct PlainRenderer {
    let options: MDOptions

    /// 한 줄 서식을 글자만 남겨 그린다.
    /// inCell이 참이면 표 칸 안이라서 줄바꿈을 " / "로 바꾼다.
    static func inlineText(_ items: [Inline], inCell: Bool) -> String {
        var out = ""
        for item in items {
            switch item {
            case .text(let s):
                // swift-markdown이 이미 엔티티를 풀어 준 글자다.
                out += s
            case .strong(let c), .emphasis(let c), .strikethrough(let c):
                out += inlineText(c, inCell: inCell)
            case .code(let s):
                // 코드 글자는 분석기가 원문 그대로 준다. 원본처럼 엔티티만 푼다.
                out += TextUtils.decodeEntities(s)
            case .softBreak:
                out += "\n"
            case .lineBreak:
                out += inCell ? " / " : "\n"
            case .link(let href, let children):
                let label = inlineText(children, inCell: inCell)
                let safe = TextUtils.safeHref(href)
                // 주소가 없거나 글자와 같으면 한 번만 쓴다.
                out += safe.isEmpty || label == safe || "mailto:\(label)" == safe ? label : "\(label) (\(safe))"
            case .image(_, let alt):
                out += alt.isEmpty ? "[이미지]" : "[이미지: \(alt)]"
            case .html(let raw):
                out += TextUtils.isBrHtml(raw) ? (inCell ? " / " : "\n") : TextUtils.stripTags(raw)
            }
        }
        return out
    }

    func inline(_ items: [Inline]) -> String {
        Self.inlineText(items, inCell: false)
    }

    private func tablePartsText(_ parts: [TablePart]) -> String {
        let joined = parts.map { p in
            if let inlines = p.inlines { return Self.inlineText(inlines, inCell: true) }
            return p.text ?? ""
        }.joined()
        return TextUtils.jsTrim(joined)
    }

    private func tableItemLines(_ items: [TableItem], depth: Int) -> [String] {
        var lines: [String] = []
        for it in items {
            let pad = String(repeating: indentUnit, count: depth)
            lines.append("\(pad)\(bullets[depth % bullets.count]) \(tablePartsText(it.parts))")
            if !it.children.isEmpty { lines += tableItemLines(it.children, depth: depth + 1) }
        }
        return lines
    }

    /// 빈 줄이 아닌 모든 줄 앞에 prefix를 붙인다.
    private func indentLines(_ text: String, _ prefix: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : prefix + $0 }.joined(separator: "\n")
    }

    private func list(ordered: Bool, start rawStart: Int, items: [ListItemNode], depth: Int) -> String {
        var lines: [String] = []
        // 원본은 Number(start) || 1 이라서 0번 시작도 1로 본다.
        let start = rawStart == 0 ? 1 : rawStart
        for (idx, item) in items.enumerated() {
            var marker = ordered ? "\(start + idx)." : bullets[depth % bullets.count]
            if let checked = item.checked { marker = checked ? "☑" : "☐" }
            let pad = String(repeating: indentUnit, count: depth)
            let contPad = pad + String(repeating: " ", count: TextUtils.textWidth(marker) + 1)
            var firstDone = false
            for child in item.children {
                if case .list(let o, let s, let sub) = child {
                    lines.append(list(ordered: o, start: s, items: sub, depth: depth + 1))
                    continue
                }
                let body = block(child)
                if body.isEmpty { continue }
                if !firstDone {
                    var parts = body.components(separatedBy: "\n")
                    let head = parts.removeFirst()
                    lines.append("\(pad)\(marker) \(head)")
                    if !parts.isEmpty { lines.append(indentLines(parts.joined(separator: "\n"), contPad)) }
                    firstDone = true
                } else {
                    lines.append(indentLines(body, contPad))
                }
            }
            // 내용이 없는 항목도 기호는 남긴다(하위 목록만 있는 경우 포함, 원본과 같음).
            if !firstDone { lines.append("\(pad)\(marker)") }
        }
        return lines.joined(separator: "\n")
    }

    func block(_ b: Block) -> String {
        switch b {
        case .heading(let level, let content):
            let text = inline(content)
            return level <= 2 ? "■ \(text)" : "□ \(text)"
        case .paragraph(let content):
            return inline(content)
        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items, depth: 0)
        case .table(let t):
            if options.tableMode == .grid { return TableLayout.tableGrid(t) }
            return tableItemLines(TableLayout.tableItems(t, mode: options.tableMode), depth: 0).joined(separator: "\n")
        case .code(let s):
            return s
        case .blockquote(let children):
            return indentLines(blocks(children), "│ ")
        case .thematicBreak:
            return hrText
        case .html(let raw):
            return TextUtils.jsTrim(TextUtils.stripTags(raw))
        }
    }

    /// 덩어리 사이에 빈 줄을 넣어 잇는다. 제목 바로 아래는 빈 줄 없이 붙인다.
    func blocks(_ list: [Block]) -> String {
        var out = ""
        var prevWasHeading = false
        var hasContent = false
        for b in list {
            let text = block(b)
            if text.isEmpty { continue }
            if hasContent { out += prevWasHeading ? "\n" : "\n\n" }
            out += text
            hasContent = true
            prevWasHeading = b.isHeading
        }
        return out
    }

    /// 마지막 정리: 줄 끝 공백 제거, 빈 줄 3개 이상은 2개로, 앞뒤 공백 제거 후 끝에 줄바꿈 하나.
    static func finish(_ s: String) -> String {
        let trimmedLines = s.components(separatedBy: "\n").map { line -> String in
            var scalars = Substring(line).unicodeScalars
            while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
            return String(scalars)
        }.joined(separator: "\n")
        var collapsed = ""
        var newlineRun = 0
        for ch in trimmedLines {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { collapsed.append(ch) }
            } else {
                newlineRun = 0
                collapsed.append(ch)
            }
        }
        return TextUtils.jsTrim(collapsed) + "\n"
    }
}

// MARK: - Slack

struct SlackRenderer {
    let options: MDOptions

    /// 블록 사이 빈 줄. Slack은 붙여넣은 문단·목록 사이 간격을 없애서,
    /// 넣지 않으면 연속된 두 목록이 하나로 합쳐져 보인다.
    private static let gap = "<p><br></p>"

    func inline(_ items: [Inline]) -> String {
        var out = ""
        for item in items {
            switch item {
            case .text(let s):
                out += TextUtils.escapeDecodedText(s)
            case .strong(let c):
                out += "<b>\(inline(c))</b>"
            case .emphasis(let c):
                out += "<i>\(inline(c))</i>"
            case .strikethrough(let c):
                out += "<s>\(inline(c))</s>"
            case .code(let s):
                out += "<code>\(TextUtils.escapeHtml(s))</code>"
            case .softBreak:
                // breaks가 꺼져 있으면 엔터 한 번은 띄어쓰기로 본다.
                out += options.breaks ? "<br>" : " "
            case .lineBreak:
                out += "<br>"
            case .link(let href, let children):
                let safe = TextUtils.safeHref(href)
                let label = inline(children)
                out += safe.isEmpty ? label : "<a href=\"\(TextUtils.escapeAttr(safe))\">\(label)</a>"
            case .image(let source, let alt):
                let safe = TextUtils.safeHref(source)
                let label = TextUtils.escapeDecodedText(alt.isEmpty ? "[이미지]" : "[이미지: \(alt)]")
                out += safe.isEmpty ? label : "<a href=\"\(TextUtils.escapeAttr(safe))\">\(label)</a>"
            case .html(let raw):
                out += TextUtils.isBrHtml(raw) ? "<br>" : TextUtils.escapeHtml(TextUtils.stripTags(raw))
            }
        }
        return out
    }

    private func tableParts(_ parts: [TablePart]) -> String {
        parts.map { p -> String in
            let html = p.inlines.map(inline) ?? TextUtils.escapeHtml(p.text ?? "")
            return p.kind == .bold ? "<b>\(html)</b>" : html
        }.joined()
    }

    private func tableItems(_ items: [TableItem]) -> String {
        if items.isEmpty { return "" }
        let lis = items.map { it in
            "<li>\(tableParts(it.parts))\(it.children.isEmpty ? "" : tableItems(it.children))</li>"
        }.joined()
        return "<ul>\(lis)</ul>"
    }

    private func list(ordered: Bool, start rawStart: Int, items: [ListItemNode]) -> String {
        let tag = ordered ? "ol" : "ul"
        let start = rawStart == 0 ? 1 : rawStart
        let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
        let lis = items.map { item -> String in
            var html = item.checked.map { $0 ? "☑ " : "☐ " } ?? ""
            var first = true
            for child in item.children {
                if case .list(let o, let s, let sub) = child {
                    html += list(ordered: o, start: s, items: sub)
                    continue
                }
                if case .paragraph(let content) = child {
                    html += (first ? "" : "<br>") + inline(content)
                } else {
                    html += block(child)
                }
                first = false
            }
            return "<li>\(html)</li>"
        }.joined()
        return "<\(tag)\(startAttr)>\(lis)</\(tag)>"
    }

    func block(_ b: Block) -> String {
        switch b {
        case .heading(_, let content):
            return "<p><b>\(inline(content))</b></p>"
        case .paragraph(let content):
            return "<p>\(inline(content))</p>"
        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items)
        case .table(let t):
            if options.tableMode == .grid { return "<pre>\(TextUtils.escapeHtml(TableLayout.tableGrid(t)))</pre>" }
            return tableItems(TableLayout.tableItems(t, mode: options.tableMode))
        case .code(let s):
            return "<pre>\(TextUtils.escapeHtml(s))</pre>"
        case .blockquote(let children):
            return "<blockquote>\(children.map(block).joined())</blockquote>"
        case .thematicBreak:
            return "<p>\(hrText)</p>"
        case .html(let raw):
            let text = TextUtils.jsTrim(TextUtils.stripTags(raw))
            return text.isEmpty ? "" : "<p>\(TextUtils.escapeHtml(text))</p>"
        }
    }

    /// 문서 전체를 그린다. 블록 사이에 빈 줄을 넣되, 제목 바로 아래는 붙인다.
    func document(_ list: [Block]) -> String {
        var out = ""
        var prev: Block?
        for b in list {
            let html = block(b)
            if html.isEmpty { continue }
            if let prev, !prev.isHeading { out += Self.gap }
            out += html
            prev = b
        }
        return out
    }
}
