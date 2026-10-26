// 미리보기 화면 그리기: 브라우저 엔진 없이 NSAttributedString(서식 있는 글자)으로 만든다.
// - DocRenderer: 문서 미리보기. 디자인 기준은 src/styles.css의 .md-body
//   (제목 크기와 h1·h2 밑줄, 목록, 할 일, 표 테두리·머리글 배경·짝수 행 배경·열 정렬, 코드 블록 배경·테두리, 인용 왼쪽 막대, 구분선, 링크)
//   표는 NSTextTable, 코드·인용 배경과 테두리는 NSTextBlock으로 그린다(TextKit 1).
// - SlackRenderer: Slack 복사 HTML을 Slack 메시지처럼 그린다 (.slack-content)
// - PlainRenderer: 텍스트 복사 결과를 고정폭 글꼴 상자에 그린다 (.plain-out)
// - 같은 렌더러로 PDF와 RTF(서식 복사)도 만든다. 이때는 종이용 밝은 색(Palette.light)을 쓴다.
// 의존성: AppKit, MDCore
import AppKit
import MDCore

/// 미리보기 글자 모양 설정
public struct PreviewStyle {
    public var palette: Palette
    /// 본문 글자 크기 (CSS 15.5px)
    public var baseSize: CGFloat
    /// 상대 경로 이미지를 찾을 기준 폴더 (열린 파일의 폴더)
    public var baseURL: URL?

    public init(palette: Palette = Theme.dynamicPalette, baseSize: CGFloat = 15.5, baseURL: URL? = nil) {
        self.palette = palette
        self.baseSize = baseSize
        self.baseURL = baseURL
    }
}

// MARK: - 공통 도구

/// 덩어리를 그릴 때의 위치 정보 (들여쓰기, 바깥 상자들, 글자색)
private struct BlockContext {
    var textBlocks: [NSTextBlock] = []
    var indent: CGFloat = 0
    var color: NSColor
    /// 표 칸 안에서는 문단 간격을 두지 않는다.
    var inCell = false
}

private extension NSTextBlock {
    func setPadding(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
        setWidth(top, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(right, type: .absoluteValueType, for: .padding, edge: .maxX)
        setWidth(bottom, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(left, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    /// 폭을 정하지 않은 NSTextBlock은 테두리·배경을 그리지 않는다. 남은 폭 전체(100%)를 쓰게 한다.
    func fillWidth() {
        setContentWidth(100, type: .percentageValueType)
    }

    func setMargin(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0) {
        setWidth(top, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(bottom, type: .absoluteValueType, for: .margin, edge: .maxY)
        setWidth(left, type: .absoluteValueType, for: .margin, edge: .minX)
    }
}

// MARK: - 문서 미리보기

public final class DocRenderer {
    private let style: PreviewStyle
    private let options: MDOptions
    private let out = NSMutableAttributedString()
    private var p: Palette { style.palette }
    private var em: CGFloat { style.baseSize }

    public init(style: PreviewStyle, options: MDOptions) {
        self.style = style
        self.options = options
    }

    /// 마크다운을 미리보기 글자로 만든다.
    public static func render(_ markdown: String, style: PreviewStyle, options: MDOptions) -> NSAttributedString {
        let r = DocRenderer(style: style, options: options)
        return r.render(blocks: MDConverter.parse(markdown))
    }

    public func render(blocks: [Block]) -> NSAttributedString {
        let ctx = BlockContext(color: p.fg)
        for (i, b) in blocks.enumerated() { block(b, ctx, first: i == 0) }
        if out.length == 0 {
            out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(em), .foregroundColor: p.muted]))
        }
        return out
    }

    // MARK: 문단 모양

    private func paragraph(_ ctx: BlockContext, before: CGFloat = 0, after: CGFloat, firstIndent: CGFloat? = nil,
                           headIndent: CGFloat? = nil, lineHeight: CGFloat = 1.42, align: NSTextAlignment = .natural,
                           tabs: [NSTextTab] = []) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = ctx.textBlocks
        ps.paragraphSpacingBefore = before
        ps.paragraphSpacing = ctx.inCell ? 0 : after
        ps.firstLineHeadIndent = firstIndent ?? ctx.indent
        ps.headIndent = headIndent ?? ctx.indent
        ps.lineHeightMultiple = lineHeight
        ps.alignment = align
        ps.tabStops = tabs
        ps.defaultTabInterval = 24
        ps.lineBreakStrategy = .hangulWordPriority
        return ps
    }

    private func baseAttrs(_ ctx: BlockContext, font: NSFont? = nil) -> [NSAttributedString.Key: Any] {
        [.font: font ?? Theme.ui(em), .foregroundColor: ctx.color]
    }

    /// 문단 하나를 붙인다(끝에 줄바꿈 포함).
    private func appendParagraph(_ content: NSAttributedString, _ ps: NSParagraphStyle, _ attrs: [NSAttributedString.Key: Any]) {
        let m = NSMutableAttributedString(attributedString: content)
        m.append(NSAttributedString(string: "\n", attributes: attrs))
        m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
        out.append(m)
    }

    /// 마지막 문단의 아래 간격을 최소 value로 늘린다(목록이 끝날 때 등).
    private func bumpLastSpacing(_ value: CGFloat) {
        guard out.length > 0 else { return }
        let last = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let ps = out.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle,
              ps.paragraphSpacing < value else { return }
        let m = ps.mutableCopy() as! NSMutableParagraphStyle
        m.paragraphSpacing = value
        out.addAttribute(.paragraphStyle, value: m, range: last)
    }

    // MARK: 덩어리

    private func block(_ b: Block, _ ctx: BlockContext, first: Bool = false) {
        switch b {
        case .heading(let level, let content):
            heading(level, content, ctx, first: first)
        case .paragraph(let content):
            let attrs = baseAttrs(ctx)
            appendParagraph(inline(content, attrs), paragraph(ctx, after: em), attrs)
        case .list(let ordered, let start, let items):
            list(ordered: ordered, start: start, items: items, ctx, depth: 0)
            bumpLastSpacing(ctx.inCell ? 0 : em)
        case .table(let t):
            table(t, ctx)
            spacer(em * 1.2, ctx)
        case .code(let code):
            codeBlock(code, ctx)
            spacer(em, ctx)
        case .blockquote(let children):
            blockquote(children, ctx)
            spacer(em, ctx)
        case .thematicBreak:
            hr(ctx)
        case .html(let raw):
            let text = MDText.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let attrs = baseAttrs(ctx)
                appendParagraph(NSAttributedString(string: text, attributes: attrs), paragraph(ctx, after: em), attrs)
            }
        }
    }

    private func heading(_ level: Int, _ content: [Inline], _ ctx: BlockContext, first: Bool) {
        let scale: [CGFloat] = [1.8, 1.45, 1.2, 1.05, 1.0, 0.95]
        let size = em * scale[min(max(level, 1), 6) - 1]
        var hctx = ctx
        if level == 6 { hctx.color = p.muted }
        let attrs = baseAttrs(hctx, font: Theme.ui(size, weight: .bold))
        var c = hctx
        if level <= 2 && !ctx.inCell {
            // h1·h2 아래 구분선
            let rule = NSTextBlock()
            rule.fillWidth()
            rule.setBorderColor(p.line, for: .maxY)
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setPadding(top: 0, right: 0, bottom: size * (level == 1 ? 0.3 : 0.25), left: 0)
            rule.setMargin(bottom: size * 0.6, left: ctx.indent)
            c.textBlocks = ctx.textBlocks + [rule]
            c.indent = 0
        }
        let before = first ? 0 : size * 1.6 * 0.75
        let ps = paragraph(c, before: before, after: level <= 2 ? 0 : size * 0.6, lineHeight: 1.15)
        appendParagraph(inline(content, attrs), ps, attrs)
    }

    private func list(ordered: Bool, start rawStart: Int, items: [ListItemNode], _ ctx: BlockContext, depth: Int) {
        let start = rawStart == 0 ? 1 : rawStart
        let bullets = ["•", "◦", "▪"]
        let step = em * 1.6
        for (idx, item) in items.enumerated() {
            var marker = ordered ? "\(start + idx)." : bullets[depth % bullets.count]
            if let checked = item.checked { marker = checked ? "☑" : "☐" }
            let head = ctx.indent + step
            var childCtx = ctx
            childCtx.indent = head
            var markerDone = false
            for child in item.children {
                switch child {
                case .paragraph(let content) where !markerDone:
                    let attrs = baseAttrs(ctx)
                    let line = NSMutableAttributedString(string: marker + "\t", attributes: attrs)
                    if item.checked != nil {
                        line.addAttribute(.foregroundColor, value: item.checked == true ? p.accent : p.muted, range: NSRange(location: 0, length: 1))
                    }
                    line.append(inline(content, attrs))
                    let ps = paragraph(ctx, after: em * 0.2, firstIndent: ctx.indent + step - markerWidth(marker, attrs) - 6,
                                       headIndent: head, tabs: [NSTextTab(textAlignment: .natural, location: head)])
                    appendParagraph(line, ps, attrs)
                    markerDone = true
                case .list(let o, let s, let sub):
                    if !markerDone {
                        let attrs = baseAttrs(ctx)
                        appendParagraph(NSAttributedString(string: marker, attributes: attrs),
                                        paragraph(ctx, after: em * 0.2, firstIndent: ctx.indent + step - markerWidth(marker, attrs) - 6, headIndent: head), attrs)
                        markerDone = true
                    }
                    list(ordered: o, start: s, items: sub, childCtx, depth: depth + 1)
                default:
                    if !markerDone {
                        let attrs = baseAttrs(ctx)
                        appendParagraph(NSAttributedString(string: marker, attributes: attrs),
                                        paragraph(ctx, after: em * 0.2, firstIndent: ctx.indent + step - markerWidth(marker, attrs) - 6, headIndent: head), attrs)
                        markerDone = true
                    }
                    block(child, childCtx)
                }
            }
            if !markerDone {
                let attrs = baseAttrs(ctx)
                appendParagraph(NSAttributedString(string: marker, attributes: attrs),
                                paragraph(ctx, after: em * 0.2, firstIndent: ctx.indent + step - markerWidth(marker, attrs) - 6, headIndent: head), attrs)
            }
        }
    }

    private func markerWidth(_ marker: String, _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((marker as NSString).size(withAttributes: attrs).width)
    }

    private func table(_ t: TableNode, _ ctx: BlockContext) {
        let cols = max(1, t.header.count)
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setMargin(left: ctx.indent)

        func cell(_ content: [Inline], row: Int, col: Int, header: Bool) {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
            block.setBorderColor(p.line)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setPadding(top: 6, right: 12, bottom: 6, left: 12)
            block.verticalAlignment = .topAlignment
            if header {
                block.backgroundColor = p.soft
            } else if row % 2 == 0 {
                block.backgroundColor = p.stripe
            }
            var c = ctx
            c.textBlocks = ctx.textBlocks + [block]
            c.indent = 0
            c.inCell = true
            let align: NSTextAlignment
            switch col < t.alignments.count ? t.alignments[col] : nil {
            case .center?: align = .center
            case .right?: align = .right
            case .left?: align = .left
            case nil: align = header ? .left : .natural
            }
            let attrs = baseAttrs(c, font: header ? Theme.ui(em * 0.97, weight: .bold) : Theme.ui(em * 0.97))
            appendParagraph(inline(content, attrs), paragraph(c, after: 0, lineHeight: 1.3, align: align), attrs)
        }

        for (i, h) in t.header.enumerated() { cell(h, row: 0, col: i, header: true) }
        for (r, row) in t.rows.enumerated() {
            for c in 0..<cols {
                let content: [Inline] = (c < row.count ? row[c] : nil) ?? []
                cell(content, row: r + 1, col: c, header: false)
            }
        }
    }

    private func codeBlock(_ code: String, _ ctx: BlockContext) {
        let box = NSTextBlock()
        box.fillWidth()
        box.backgroundColor = p.soft
        box.setBorderColor(p.line)
        box.setWidth(1, type: .absoluteValueType, for: .border)
        box.setPadding(top: 12, right: 16, bottom: 12, left: 16)
        box.setMargin(left: ctx.indent)
        var c = ctx
        c.textBlocks = ctx.textBlocks + [box]
        c.indent = 0
        c.color = p.fg
        let attrs = baseAttrs(c, font: Theme.mono(em * 0.87))
        let ps = paragraph(c, after: 0, lineHeight: 1.2)
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            appendParagraph(NSAttributedString(string: line, attributes: attrs), ps, attrs)
        }
    }

    private func blockquote(_ children: [Block], _ ctx: BlockContext) {
        let bar = NSTextBlock()
        bar.fillWidth()
        bar.setBorderColor(p.line, for: .minX)
        bar.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setPadding(top: em * 0.3, right: 0, bottom: em * 0.3, left: em)
        bar.setMargin(left: ctx.indent)
        var c = ctx
        c.textBlocks = ctx.textBlocks + [bar]
        c.indent = 0
        c.color = p.muted
        if children.isEmpty {
            let attrs = baseAttrs(c)
            appendParagraph(NSAttributedString(string: "", attributes: attrs), paragraph(c, after: 0), attrs)
            return
        }
        for (i, child) in children.enumerated() {
            block(child, c, first: i == 0)
        }
        // 인용 안의 마지막 문단은 아래 간격을 두지 않는다(상자 여백이 대신한다).
        trimLastSpacing()
    }

    /// 상자(표·코드·인용) 아래의 빈 간격. 상자 바깥 여백(margin)은 배경이 번져 보여서 빈 줄로 띄운다.
    private func spacer(_ height: CGFloat, _ ctx: BlockContext) {
        guard !ctx.inCell else { return }
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = ctx.textBlocks
        ps.minimumLineHeight = height
        ps.maximumLineHeight = height
        out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(1), .paragraphStyle: ps]))
    }

    private func trimLastSpacing() {
        guard out.length > 0 else { return }
        let last = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let ps = out.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle else { return }
        let m = ps.mutableCopy() as! NSMutableParagraphStyle
        m.paragraphSpacing = 0
        out.addAttribute(.paragraphStyle, value: m, range: last)
    }

    private func hr(_ ctx: BlockContext) {
        let rule = NSTextBlock()
        rule.fillWidth()
        rule.setBorderColor(p.line, for: .maxY)
        rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        rule.setMargin(top: em * 1.2, bottom: em * 2, left: ctx.indent)
        var c = ctx
        c.textBlocks = ctx.textBlocks + [rule]
        c.indent = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(2), .foregroundColor: p.line]
        appendParagraph(NSAttributedString(string: "\u{00A0}", attributes: attrs), paragraph(c, after: 0, lineHeight: 1), attrs)
    }

    // MARK: 한 줄 서식

    private func inline(_ items: [Inline], _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let font = (attrs[.font] as? NSFont) ?? Theme.ui(em)
        for item in items {
            switch item {
            case .text(let s):
                m.append(NSAttributedString(string: s, attributes: attrs))
            case .strong(let c):
                var a = attrs
                a[.font] = Theme.bold(font)
                m.append(inline(c, a))
            case .emphasis(let c):
                var a = attrs
                for (k, v) in Theme.italicAttributes(for: font) { a[k] = v }
                m.append(inline(c, a))
            case .strikethrough(let c):
                var a = attrs
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                m.append(inline(c, a))
            case .code(let s):
                var a = attrs
                a[.font] = Theme.mono(font.pointSize * 0.87)
                a[.backgroundColor] = p.codeBg
                // 앞뒤에 아주 좁은 공백을 넣어 배경이 글자에 딱 붙지 않게 한다.
                m.append(NSAttributedString(string: "\u{2009}\(s)\u{2009}", attributes: a))
            case .softBreak:
                m.append(NSAttributedString(string: options.breaks ? "\u{2028}" : " ", attributes: attrs))
            case .lineBreak:
                m.append(NSAttributedString(string: "\u{2028}", attributes: attrs))
            case .link(let href, let children):
                let label = inline(children, attrs)
                let safe = MDText.safeHref(href)
                if let url = URL(string: safe), !safe.isEmpty {
                    let l = NSMutableAttributedString(attributedString: label)
                    let r = NSRange(location: 0, length: l.length)
                    l.addAttribute(.link, value: url, range: r)
                    l.addAttribute(.foregroundColor, value: p.accent, range: r)
                    l.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                    m.append(l)
                } else {
                    m.append(label)
                }
            case .image(let source, let alt):
                m.append(image(source: source, alt: alt, attrs))
            case .html(let raw):
                let text = MDText.isBrHtml(raw) ? "\u{2028}" : MDText.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                m.append(NSAttributedString(string: text, attributes: attrs))
            }
        }
        return m
    }

    /// 이미지: 내 맥에 있는 파일(문서 기준 상대 경로 포함)이면 그림으로, 인터넷 주소면 "[이미지: 설명]" 링크로 보여 준다.
    /// 인터넷 이미지를 앱이 몰래 내려받지 않도록 하기 위해서다.
    private func image(source: String, alt: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let safe = MDText.safeHref(source)
        let label = alt.isEmpty ? "[이미지]" : "[이미지: \(alt)]"
        var fileURL: URL?
        if let u = URL(string: safe), u.isFileURL {
            fileURL = u
        } else if !safe.isEmpty, URL(string: safe)?.scheme == nil, let base = style.baseURL {
            let decoded = safe.removingPercentEncoding ?? safe
            fileURL = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : base.appendingPathComponent(decoded)
        }
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path), let img = NSImage(contentsOf: fileURL) {
            let maxWidth: CGFloat = 760
            var size = img.size
            if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
            img.size = size
            let att = NSTextAttachment()
            att.image = img
            att.bounds = NSRect(origin: .zero, size: size)
            return NSAttributedString(attachment: att)
        }
        var a = attrs
        a[.foregroundColor] = p.muted
        if let url = URL(string: safe), !safe.isEmpty, url.scheme != nil { a[.link] = url }
        return NSAttributedString(string: label, attributes: a)
    }
}

// MARK: - Slack 미리보기

public enum SlackPreviewRenderer {
    /// Slack 복사 HTML(b, i, s, code, pre, a, ul, ol, li, blockquote, p, br)을 Slack 메시지 모양으로 그린다.
    public static func render(slackHTML: String, palette: Palette, size: CGFloat = 15) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let wrapped = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"><title></title></head><body>\(slackHTML)</body></html>"
        guard let doc = try? XMLDocument(data: Data(wrapped.utf8), options: [.documentTidyHTML]),
              let body = findBody(doc.rootElement()) else {
            appLog.error("미리보기", "Slack 미리보기 HTML을 읽지 못했습니다")
            out.append(NSAttributedString(string: slackHTML, attributes: [.font: Theme.ui(size), .foregroundColor: palette.fg]))
            return out
        }
        var r = SlackWalker(palette: palette, size: size, out: out)
        r.blocks(body, BlockContext(color: palette.fg), depth: 0)
        return out
    }

    /// Slack 메시지 모양(아바타 "나", 이름, "오늘", 내용)과 안내 문구까지 그린다. (.slack-mock)
    public static func renderMock(slackHTML: String, palette: Palette, size: CGFloat = 15) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setBorderColor(palette.line)
        table.setWidth(1, type: .absoluteValueType, for: .border)
        table.setWidth(14, type: .absoluteValueType, for: .padding)
        table.setContentWidth(100, type: .percentageValueType)
        table.backgroundColor = palette.bg

        // 아바타: 보라색 둥근 사각형에 "나" (칸 높이와 상관없이 36×36으로 위에 붙인다)
        let avatarCell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        avatarCell.setValue(36, type: .absoluteValueType, for: .width)
        avatarCell.verticalAlignment = .topAlignment
        let content = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 1, columnSpan: 1)
        content.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        content.verticalAlignment = .topAlignment

        let avatarImage = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { rect in
            NSColor(srgbRed: 0x4a / 255, green: 0x15 / 255, blue: 0x4b / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let text = NSAttributedString(string: "나", attributes: [.font: Theme.ui(15, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = avatarImage
        attachment.bounds = NSRect(x: 0, y: -10, width: 36, height: 36)
        let avatarPara = NSMutableParagraphStyle()
        avatarPara.textBlocks = [avatarCell]
        let avatarLine = NSMutableAttributedString(attachment: attachment)
        avatarLine.append(NSAttributedString(string: "\n"))
        avatarLine.addAttribute(.paragraphStyle, value: avatarPara, range: NSRange(location: 0, length: avatarLine.length))
        out.append(avatarLine)

        let meta = NSMutableParagraphStyle()
        meta.textBlocks = [content]
        meta.paragraphSpacing = 2
        let metaLine = NSMutableAttributedString(string: "나", attributes: [.font: Theme.ui(size, weight: .bold), .foregroundColor: palette.fg, .paragraphStyle: meta])
        metaLine.append(NSAttributedString(string: "  오늘\n", attributes: [.font: Theme.ui(12), .foregroundColor: palette.muted, .paragraphStyle: meta]))
        out.append(metaLine)

        let wrapped = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"><title></title></head><body>\(slackHTML)</body></html>"
        let before = out.length
        if let doc = try? XMLDocument(data: Data(wrapped.utf8), options: [.documentTidyHTML]), let body = findBody(doc.rootElement()) {
            var ctx = BlockContext(color: palette.fg)
            ctx.textBlocks = [content]
            var r = SlackWalker(palette: palette, size: size, out: out)
            r.blocks(body, ctx, depth: 0)
        } else {
            appLog.error("미리보기", "Slack 미리보기 HTML을 읽지 못했습니다")
        }
        if out.length == before {
            let ps = NSMutableParagraphStyle()
            ps.textBlocks = [content]
            out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(size), .paragraphStyle: ps]))
        }

        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = 10
        gap.maximumLineHeight = 10
        out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(1), .paragraphStyle: gap]))
        let hint = NSMutableParagraphStyle()
        hint.lineBreakStrategy = .hangulWordPriority
        out.append(NSAttributedString(
            string: "Slack 입력창에 붙여넣었을 때의 예상 모습입니다. 실제 Slack은 버전에 따라 줄 간격이 조금 다를 수 있습니다.\n",
            attributes: [.font: Theme.ui(12), .foregroundColor: palette.muted, .paragraphStyle: hint]))
        return out
    }

    private static func findBody(_ node: XMLNode?) -> XMLNode? {
        guard let node else { return nil }
        if node.kind == .element, (node.localName ?? node.name ?? "").lowercased() == "body" { return node }
        for c in node.children ?? [] { if let f = findBody(c) { return f } }
        return nil
    }
}

private struct SlackWalker {
    let palette: Palette
    let size: CGFloat
    let out: NSMutableAttributedString

    private func ps(_ ctx: BlockContext, first: CGFloat? = nil, head: CGFloat? = nil, tabs: [NSTextTab] = []) -> NSMutableParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.textBlocks = ctx.textBlocks
        s.firstLineHeadIndent = first ?? ctx.indent
        s.headIndent = head ?? ctx.indent
        s.lineHeightMultiple = 1.22
        s.paragraphSpacing = 0
        s.tabStops = tabs
        s.lineBreakStrategy = .hangulWordPriority
        return s
    }

    private func attrs(_ ctx: BlockContext) -> [NSAttributedString.Key: Any] {
        [.font: Theme.ui(size), .foregroundColor: ctx.color]
    }

    private func name(_ n: XMLNode) -> String { (n.localName ?? n.name ?? "").lowercased() }

    private func append(_ s: NSAttributedString, _ style: NSParagraphStyle, _ a: [NSAttributedString.Key: Any]) {
        let m = NSMutableAttributedString(attributedString: s)
        m.append(NSAttributedString(string: "\n", attributes: a))
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        out.append(m)
    }

    mutating func blocks(_ node: XMLNode, _ ctx: BlockContext, depth: Int) {
        var pending = NSMutableAttributedString()
        func flush() {
            if pending.length > 0 {
                append(pending, ps(ctx), attrs(ctx))
                pending = NSMutableAttributedString()
            }
        }
        for child in node.children ?? [] {
            let n = name(child)
            switch n {
            case "p":
                flush()
                let line = inline(child, attrs(ctx))
                // <p><br></p>는 블록 사이 빈 줄 하나다(원본 CSS: 빈 문단도 한 줄 높이).
                let isBlank = line.string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2028} ")).isEmpty
                append(isBlank ? NSAttributedString(string: "", attributes: attrs(ctx)) : line, ps(ctx), attrs(ctx))
            case "ul", "ol":
                flush()
                list(child, ordered: n == "ol", ctx, depth: depth)
            case "pre":
                flush()
                pre(child, ctx)
            case "blockquote":
                flush()
                let bar = NSTextBlock()
                bar.fillWidth()
                bar.setBorderColor(palette.line, for: .minX)
                bar.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
                bar.setPadding(top: 2, right: 0, bottom: 2, left: 12)
                bar.setMargin(left: ctx.indent)
                var c = ctx
                c.textBlocks = ctx.textBlocks + [bar]
                c.indent = 0
                blocks(child, c, depth: depth)
            default:
                pending.append(inline(child, attrs(ctx)))
            }
        }
        flush()
    }

    private mutating func list(_ node: XMLNode, ordered: Bool, _ ctx: BlockContext, depth: Int) {
        let start = Int((node as? XMLElement)?.attribute(forName: "start")?.stringValue ?? "") ?? 1
        let marks = ["•", "◦", "▪"]
        let step = size * 1.6
        var index = 0
        for li in (node.children ?? []) where name(li) == "li" {
            let marker = ordered ? "\(start + index)." : marks[depth % marks.count]
            index += 1
            let head = ctx.indent + step
            var line = NSMutableAttributedString(string: marker + "\t", attributes: attrs(ctx))
            var lineStarted = false
            var child = ctx
            child.indent = head
            func flushLine() {
                let w = ceil((marker as NSString).size(withAttributes: attrs(ctx)).width)
                append(line, ps(ctx, first: head - w - 6, head: head, tabs: [NSTextTab(textAlignment: .natural, location: head)]), attrs(ctx))
                line = NSMutableAttributedString()
                lineStarted = true
            }
            for c in li.children ?? [] {
                let n = name(c)
                if n == "ul" || n == "ol" {
                    if !lineStarted { flushLine() }
                    list(c, ordered: n == "ol", child, depth: depth + 1)
                } else if n == "pre" {
                    if !lineStarted { flushLine() }
                    pre(c, child)
                } else {
                    line.append(inline(c, attrs(ctx)))
                }
            }
            if !lineStarted { flushLine() }
        }
    }

    private func pre(_ node: XMLNode, _ ctx: BlockContext) {
        let box = NSTextBlock()
        box.fillWidth()
        box.backgroundColor = palette.soft
        box.setBorderColor(palette.line)
        box.setWidth(1, type: .absoluteValueType, for: .border)
        box.setPadding(top: 8, right: 8, bottom: 8, left: 8)
        box.setMargin(left: ctx.indent)
        var c = ctx
        c.textBlocks = ctx.textBlocks + [box]
        c.indent = 0
        let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(size * 0.8), .foregroundColor: palette.fg]
        let style = ps(c)
        var code = node.stringValue ?? ""
        while code.hasSuffix("\n") { code.removeLast() }
        for line in code.components(separatedBy: "\n") {
            append(NSAttributedString(string: line, attributes: a), style, a)
        }
    }

    private func inline(_ node: XMLNode, _ a: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if node.kind == .text {
            let t = (node.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
            m.append(NSAttributedString(string: t, attributes: a))
            return m
        }
        let font = (a[.font] as? NSFont) ?? Theme.ui(size)
        var next = a
        switch name(node) {
        case "br":
            m.append(NSAttributedString(string: "\u{2028}", attributes: a))
            return m
        case "b", "strong": next[.font] = Theme.bold(font)
        case "i", "em": for (k, v) in Theme.italicAttributes(for: font) { next[k] = v }
        case "s", "del": next[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "code":
            next[.font] = Theme.mono(size * 0.8)
            next[.foregroundColor] = palette.slackCode
            next[.backgroundColor] = palette.soft
        case "a":
            if let href = (node as? XMLElement)?.attribute(forName: "href")?.stringValue, let url = URL(string: href) {
                next[.link] = url
            }
            next[.foregroundColor] = palette.slackLink
        default: break
        }
        for c in node.children ?? [] { m.append(inline(c, next)) }
        return m
    }
}

// MARK: - 텍스트 미리보기

public enum PlainPreviewRenderer {
    /// 텍스트 복사 결과를 고정폭 글꼴 상자에 담는다.
    public static func render(_ text: String, palette: Palette, size: CGFloat = 13.5) -> NSAttributedString {
        let box = NSTextBlock()
        box.fillWidth()
        box.backgroundColor = palette.soft
        box.setBorderColor(palette.line)
        box.setWidth(1, type: .absoluteValueType, for: .border)
        box.setPadding(top: 16, right: 18, bottom: 16, left: 18)
        let ps = NSMutableParagraphStyle()
        ps.textBlocks = [box]
        ps.lineHeightMultiple = 1.3
        ps.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(size), .foregroundColor: palette.fg, .paragraphStyle: ps]
        var body = text
        while body.hasSuffix("\n") { body.removeLast() }
        return NSAttributedString(string: body + "\n", attributes: attrs)
    }
}
