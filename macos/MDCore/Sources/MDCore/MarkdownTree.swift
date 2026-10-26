// 마크다운 분석 결과를 변환하기 쉬운 단순한 나무 구조로 옮긴다.
// - swift-markdown(cmark-gfm)이 만든 노드를 Block/Inline 열거형으로 바꾼다.
// - 원본 웹 버전이 쓰는 분석기(marked)와 결과가 같아지도록 두 가지를 보정한다.
//   1) 잘게 쪼개진 이웃 글자 노드를 하나로 합친다.
//   2) 맨 주소(www.a.com, https://…, 메일 주소)를 링크로 바꾼다. swift-markdown은 이 확장을 켜지 않는다.
// 의존성: Markdown (swift-markdown)
import Foundation
import Markdown

/// 한 줄 안의 서식 조각.
indirect enum Inline: Equatable {
    case text(String)
    case strong([Inline])
    case emphasis([Inline])
    case strikethrough([Inline])
    case code(String)
    case softBreak
    case lineBreak
    case link(href: String, children: [Inline])
    case image(source: String, alt: String)
    case html(String)
}

/// 할 일 목록의 체크 상태. 할 일이 아니면 nil.
struct ListItemNode: Equatable {
    var checked: Bool?
    var children: [Block]
}

/// 표. 행의 칸 수가 머리글보다 적을 수 있어 칸은 Optional로 둔다.
struct TableNode: Equatable {
    var header: [[Inline]]
    var rows: [[[Inline]?]]
}

/// 문단, 제목, 목록 같은 덩어리.
indirect enum Block: Equatable {
    case heading(level: Int, content: [Inline])
    case paragraph([Inline])
    case list(ordered: Bool, start: Int, items: [ListItemNode])
    case table(TableNode)
    case code(String)
    case blockquote([Block])
    case thematicBreak
    case html(String)

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

enum MarkdownTree {
    /// 마크다운 글을 분석해 덩어리 목록을 돌려준다.
    /// 스마트 따옴표 변환은 끈다. 원본(marked)은 따옴표를 바꾸지 않기 때문이다.
    static func parse(_ markdown: String) -> [Block] {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        return blocks(document.children)
    }

    // MARK: - 덩어리 변환

    private static func blocks(_ children: MarkupChildren) -> [Block] {
        children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> Block? {
        switch markup {
        case let h as Heading:
            return .heading(level: h.level, content: inlines(h.children))
        case let p as Paragraph:
            return .paragraph(inlines(p.children))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: listItems(list.listItems))
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: listItems(list.listItems))
        case let code as CodeBlock:
            return .code(trimFinalNewline(code.code))
        case let quote as BlockQuote:
            return .blockquote(blocks(quote.children))
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return .html(html.rawHTML)
        case let table as Table:
            return .table(tableNode(table))
        default:
            // 켜지 않은 확장(지시문 등)만 여기에 온다. 글자만이라도 살린다.
            let text = markup.format()
            MDLog.core.notice("알 수 없는 블록 종류: \(String(describing: type(of: markup)), privacy: .public)")
            return text.isEmpty ? nil : .paragraph([.text(text)])
        }
    }

    private static func listItems(_ items: some Sequence<ListItem>) -> [ListItemNode] {
        items.map { item in
            let checked: Bool?
            switch item.checkbox {
            case .checked?: checked = true
            case .unchecked?: checked = false
            case nil: checked = nil
            }
            return ListItemNode(checked: checked, children: blocks(item.children))
        }
    }

    private static func tableNode(_ table: Table) -> TableNode {
        let header: [[Inline]] = Array(table.head.cells.map { inlines($0.children) })
        let rows: [[[Inline]?]] = Array(table.body.rows.map { row in
            Array(row.cells.map { Optional(inlines($0.children)) })
        })
        return TableNode(header: header, rows: rows)
    }

    /// cmark는 코드 블록 끝에 줄바꿈을 하나 붙여 준다. marked는 붙이지 않으므로 하나만 뗀다.
    private static func trimFinalNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    // MARK: - 한 줄 서식 변환

    /// insideLink: 링크 글자 안에서는 자동 링크를 만들지 않는다(링크 안의 링크 방지, 원본과 같음).
    private static func inlines(_ children: MarkupChildren, insideLink: Bool = false) -> [Inline] {
        let raw: [Inline] = children.compactMap { inline($0, insideLink: insideLink) }
        return autolink(mergeText(raw), insideLink: insideLink)
    }

    private static func inline(_ markup: Markup, insideLink: Bool) -> Inline? {
        switch markup {
        case let t as Text:
            return .text(t.string)
        case let s as Strong:
            return .strong(inlines(s.children, insideLink: insideLink))
        case let e as Emphasis:
            return .emphasis(inlines(e.children, insideLink: insideLink))
        case let d as Strikethrough:
            return .strikethrough(inlines(d.children, insideLink: insideLink))
        case let c as InlineCode:
            return .code(c.code)
        case is SoftBreak:
            return .softBreak
        case is LineBreak:
            return .lineBreak
        case let l as Link:
            return .link(href: l.destination ?? "", children: inlines(l.children, insideLink: true))
        case let img as Image:
            return .image(source: img.source ?? "", alt: img.plainText)
        case let html as InlineHTML:
            return .html(html.rawHTML)
        default:
            if let container = markup as? InlineContainer {
                return .text(container.plainText)
            }
            return .text(markup.format())
        }
    }

    /// 이웃한 글자 조각을 하나로 합친다. cmark는 `_`, `*` 같은 기호에서 글자를 잘게 나눈다.
    private static func mergeText(_ items: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for item in items {
            if case .text(let s) = item, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + s)
            } else {
                out.append(item)
            }
        }
        return out
    }

    // MARK: - 맨 주소 자동 링크 (marked의 GFM url 규칙을 옮김)

    private static let urlPattern = Pattern("((?:ftp|https?)://|www\\.)(?:[a-zA-Z0-9\\-]+\\.?)+[^\\s<]*")
    private static let emailPattern = Pattern(
        "(?<![A-Za-z0-9._+-])[A-Za-z0-9._+-]+@[a-zA-Z0-9_-]+(?:\\.[a-zA-Z0-9_-]*[a-zA-Z0-9])+(?![-_])"
    )
    // 주소 끝에 붙은 문장부호(마침표, 닫는 괄호 등)는 주소에서 뺀다.
    private static let backpedal = Pattern(
        "^(?:[^?!.,:;*_'\"~()&]+|\\([^)]*\\)|&(?![a-zA-Z0-9]+;$)|[?!.,:;*_'\"~)]+(?!$))+"
    )

    private static func autolink(_ items: [Inline], insideLink: Bool) -> [Inline] {
        if insideLink { return items }
        var out: [Inline] = []
        for item in items {
            switch item {
            case .text(let s):
                out.append(contentsOf: linkify(s))
            default:
                out.append(item)
            }
        }
        return out
    }

    /// 글자 안의 주소를 찾아 링크 조각으로 나눈다.
    private static func linkify(_ s: String) -> [Inline] {
        var result: [Inline] = []
        var rest = s
        while !rest.isEmpty {
            guard let found = firstAutolink(in: rest) else { break }
            let ns = rest as NSString
            let before = ns.substring(to: found.range.location)
            if !before.isEmpty { result.append(.text(before)) }
            result.append(.link(href: found.href, children: [.text(found.text)]))
            rest = ns.substring(from: found.range.location + found.range.length)
        }
        if !rest.isEmpty { result.append(.text(rest)) }
        return result
    }

    private static func firstAutolink(in s: String) -> (range: NSRange, text: String, href: String)? {
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        let url = urlPattern.regex.firstMatch(in: s, range: all)
        let email = emailPattern.regex.firstMatch(in: s, range: all)

        // 먼저 나오는 쪽을 쓴다. 메일 주소는 문장부호를 떼지 않는다(원본과 같음).
        if let email, url == nil || email.range.location < url!.range.location {
            let text = ns.substring(with: email.range)
            return (email.range, text, "mailto:" + text)
        }
        guard let url else { return nil }
        var text = ns.substring(with: url.range)
        while true {
            let prev = text
            let tns = text as NSString
            if let m = backpedal.regex.firstMatch(in: text, range: NSRange(location: 0, length: tns.length)) {
                text = tns.substring(with: m.range)
            } else {
                text = ""
            }
            if text == prev { break }
        }
        if text.isEmpty { return nil }
        let href = text.hasPrefix("www.") ? "http://" + text : text
        return (NSRange(location: url.range.location, length: (text as NSString).length), text, href)
    }
}
