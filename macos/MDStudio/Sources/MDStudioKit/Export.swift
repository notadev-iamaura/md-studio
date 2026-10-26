// 클립보드 쓰기와 내보내기(PDF·HTML 보고서·서식 복사용 RTF).
// - 클립보드: HTML, 일반 텍스트, RTF를 "한 항목"에 함께 넣는다. 붙여넣는 앱이 알맞은 형식을 고른다.
//   (Electron 44에서 예전 클립보드 방식이 막혀 복사가 전부 실패했던 일이 있어, 쓰고 나서 다시 읽어 확인한다.)
// - PDF: 인쇄 창 없이 A4 PDF 파일로 바로 저장한다(배경 포함). 보고서와 같은 머리말·목차·꼬리말을 넣는다.
// 의존성: AppKit, MDCore
import AppKit
import MDCore

/// 복사할 내용
public struct ClipboardPayload {
    public var html: String?
    public var text: String
    public var rtf: Data?

    public init(html: String? = nil, text: String, rtf: Data? = nil) {
        self.html = html
        self.text = text
        self.rtf = rtf
    }
}

public enum Clipboard {
    /// 클립보드에 쓴다. 다 쓴 뒤 다시 읽어서 텍스트가 들어갔는지 확인한다.
    ///
    /// - Throws: 클립보드가 쓰기를 거부했거나 확인에 실패하면
    public static func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        var ok = item.setString(payload.text, forType: .string)
        if let html = payload.html { ok = item.setString(html, forType: .html) && ok }
        if let rtf = payload.rtf { ok = item.setData(rtf, forType: .rtf) && ok }
        guard ok, pasteboard.writeObjects([item]) else {
            throw FileStoreError(message: "클립보드에 쓰지 못했습니다")
        }
        guard pasteboard.string(forType: .string) == payload.text else {
            throw FileStoreError(message: "클립보드에 쓴 내용을 확인하지 못했습니다")
        }
    }

    /// 서식 복사용 RTF. 미리보기와 같은 렌더러를 종이용 밝은 색으로 그려 만든다.
    public static func richRTF(_ markdown: String, options: MDOptions) -> Data? {
        let attr = DocRenderer.render(markdown, style: PreviewStyle(palette: .light, baseSize: 14), options: options)
        do {
            return try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            appLog.error("복사", "RTF를 만들지 못해 HTML과 텍스트만 넣습니다", error)
            return nil
        }
    }
}

public enum ReportExporter {
    /// A4 (pt)
    static let a4 = NSSize(width: 595.28, height: 841.89)
    /// 여백: 위아래 18mm, 좌우 16mm (보고서 인쇄 CSS와 같음)
    static let marginV: CGFloat = 51.02
    static let marginH: CGFloat = 45.35

    /// PDF에 넣을 보고서 글자(제목·날짜·목차·본문·꼬리말)를 만든다.
    public static func reportAttributed(_ markdown: String, options: ReportOptions, date: Date = Date(),
                                        baseURL: URL? = nil) -> NSAttributedString {
        let p = Palette.light
        let out = NSMutableAttributedString()
        let title = options.title.isEmpty ? "문서" : options.title

        // 머리말: 제목과 날짜, 아래 굵은 선
        let header = NSTextBlock()
        header.setContentWidth(100, type: .percentageValueType)
        header.setBorderColor(p.fg, for: .maxY)
        header.setWidth(2, type: .absoluteValueType, for: .border, edge: .maxY)
        header.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxY)
        header.setWidth(22, type: .absoluteValueType, for: .margin, edge: .maxY)
        func para(_ blocks: [NSTextBlock], after: CGFloat = 0, indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let ps = NSMutableParagraphStyle()
            ps.textBlocks = blocks
            ps.paragraphSpacing = after
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent
            ps.lineHeightMultiple = 1.3
            ps.lineBreakStrategy = .hangulWordPriority
            return ps
        }
        func add(_ s: String, _ attrs: [NSAttributedString.Key: Any], _ ps: NSParagraphStyle) {
            var a = attrs
            a[.paragraphStyle] = ps
            out.append(NSAttributedString(string: s + "\n", attributes: a))
        }
        add(title, [.font: Theme.ui(22, weight: .bold), .foregroundColor: p.fg], para([header], after: options.includeDate ? 4 : 0))
        if options.includeDate {
            add(MDConverter.koreanDate(date), [.font: Theme.ui(10.5), .foregroundColor: p.muted], para([header]))
        }

        // 본문 (보고서 제목과 같은 첫 h1은 뺀다)
        var blocks = MDConverter.parse(markdown)
        if case .heading(1, let content)? = blocks.first,
           plainText(content).trimmingCharacters(in: .whitespacesAndNewlines) == options.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            blocks.removeFirst()
        }

        // 목차: 소제목(h2·h3)이 3개 이상일 때
        let heads: [(Int, String)] = blocks.compactMap {
            if case .heading(let lv, let c) = $0, lv == 2 || lv == 3 { return (lv, plainText(c)) }
            return nil
        }
        if options.includeToc && heads.count >= 3 {
            let toc = NSTextBlock()
            toc.setContentWidth(100, type: .percentageValueType)
            toc.backgroundColor = p.soft
            toc.setBorderColor(p.line)
            toc.setWidth(1, type: .absoluteValueType, for: .border)
            toc.setWidth(12, type: .absoluteValueType, for: .padding)
            add("목차", [.font: Theme.ui(10.5, weight: .bold), .foregroundColor: p.muted], para([toc], after: 4))
            var n = 0
            for (lv, text) in heads {
                let label: String
                if lv == 2 { n += 1; label = "\(n). \(text)" } else { label = "◦ \(text)" }
                add(label, [.font: Theme.ui(10.5), .foregroundColor: p.fg], para([toc], after: 2, indent: lv == 3 ? 18 : 0))
            }
            // 목차 상자 아래 간격 (상자 바깥 여백은 배경이 번져 보여서 빈 줄로 띄운다)
            let gap = NSMutableParagraphStyle()
            gap.minimumLineHeight = 20
            gap.maximumLineHeight = 20
            out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(1), .paragraphStyle: gap]))
        }

        let body = DocRenderer(style: PreviewStyle(palette: p, baseSize: 11, baseURL: baseURL), options: options.render)
        out.append(body.render(blocks: blocks))

        // 꼬리말
        let footer = NSTextBlock()
        footer.setContentWidth(100, type: .percentageValueType)
        footer.setBorderColor(p.line, for: .minY)
        footer.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        footer.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY)
        footer.setWidth(36, type: .absoluteValueType, for: .margin, edge: .minY)
        add("MD Studio에서 생성 · \(MDConverter.koreanDate(date))", [.font: Theme.ui(9), .foregroundColor: p.muted], para([footer]))
        return out
    }

    private static func plainText(_ inlines: [Inline]) -> String {
        inlines.map { item -> String in
            switch item {
            case .text(let s), .code(let s): return s
            case .strong(let c), .emphasis(let c), .strikethrough(let c), .link(_, let c): return plainText(c)
            case .image(_, let alt): return alt
            case .softBreak, .lineBreak: return " "
            case .html(let raw): return MDText.stripTags(raw)
            }
        }.joined()
    }

    /// 보고서를 A4 PDF 파일로 저장한다. 인쇄 창은 띄우지 않는다. (메인 스레드에서 부른다)
    ///
    /// - Throws: PDF를 만들지 못하면
    public static func writePDF(_ markdown: String, options: ReportOptions, to url: URL, baseURL: URL? = nil) throws {
        let attr = reportAttributed(markdown, options: options, baseURL: baseURL)
        let width = a4.width - marginH * 2
        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = max(ceil(layout.usedRect(for: container).height) + 4, 10)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.drawsBackground = true
        view.isEditable = false
        view.textContainerInset = .zero

        let info = NSPrintInfo()
        info.paperSize = a4
        info.topMargin = marginV
        info.bottomMargin = marginV
        info.leftMargin = marginH
        info.rightMargin = marginH
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw FileStoreError(message: "PDF를 만들지 못했습니다") }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 0 else {
            throw FileStoreError(message: "PDF 파일이 비어 있습니다")
        }
        appLog.info("내보내기", "PDF 저장", ["file": url.lastPathComponent, "bytes": "\(size.intValue)"])
    }
}
