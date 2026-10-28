// 마크다운 편집기: 맥 기본 글 입력 부품(NSTextView) 위에 문법 색칠과 서식 명령을 얹었다.
// - 한글 입력, 찾기/바꾸기(⌘F), 실행 취소, 맞춤법 같은 기본 기능은 NSTextView가 그대로 제공한다.
// - 마크다운을 망가뜨리는 자동 고침(따옴표 바꾸기, 대시, 철자 자동 수정, 링크 자동 만들기)은 끈다.
// - Enter: 목록 기호 이어 쓰기 / Tab, ⇧Tab: 줄 들여쓰기·내어쓰기
// - 붙여넣기: 설정이 켜져 있으면 웹·Docs의 서식 있는 내용을 마크다운으로 바꿔 넣는다.
// - .md 파일을 끌어다 놓으면 글로 넣지 않고 파일을 연다.
// TextKit 1(NSLayoutManager)을 쓴다. 제목 글자 크기처럼 범위마다 다른 글꼴을 쉽게 다룰 수 있기 때문이다.
// 의존성: AppKit, MDCore
import AppKit
import MDCore

public protocol EditorTextViewDelegate: AnyObject {
    /// 글이 바뀌었다(입력, 붙여넣기, 서식 명령, 실행 취소 모두).
    func editorDidChange(_ editor: EditorTextView)
    /// 붙여넣기 변환 설정이 켜져 있는지
    func editorPasteConversionEnabled(_ editor: EditorTextView) -> Bool
    /// 마크다운 파일을 편집기에 끌어다 놓았다.
    func editor(_ editor: EditorTextView, didDropFile url: URL)
}

public final class EditorTextView: NSTextView, NSTextStorageDelegate {
    public weak var editorDelegate: EditorTextViewDelegate?

    /// 편집기 글꼴 설정
    public var useMonoFont = false { didSet { applyBaseStyle() } }
    public var fontSize: CGFloat = 15 { didSet { applyBaseStyle() } }
    public var lineWrap = true { didSet { updateContainerSize() } }
    /// 붙여넣기에 쓰는 클립보드 (자가 점검은 사용자 클립보드를 건드리지 않도록 따로 만든 것을 쓴다)
    public var pasteboard: NSPasteboard = .general

    /// 글이 이만큼보다 길면 바뀐 줄만 다시 색칠한다(긴 문서에서 입력이 느려지지 않도록).
    private let fullHighlightLimit = 60_000
    private var isApplyingHighlight = false
    private let placeholder = "여기에 마크다운을 쓰거나 붙여넣으세요.  AI가 쓴 문서를 그대로 붙여넣어도 됩니다."

    /// TextKit 1 구성으로 편집기와 스크롤 영역을 만든다.
    public static func make() -> (NSScrollView, EditorTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // 긴 문서에서 화면에 보이는 부분만 먼저 배치해 입력이 느려지지 않게 한다.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // 배경은 편집기가 칠한다. 스크롤 영역까지 칠하면 같은 크기의 그림판이 하나 더 생긴다.
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = view
        view.configure()
        return (scroll, view)
    }

    private func configure() {
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = true
        backgroundColor = Theme.bg
        insertionPointColor = Theme.fg
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        textContainerInset = NSSize(width: 28, height: 18)
        textContainer?.lineFragmentPadding = 0
        textStorage?.delegate = self
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("마크다운 편집기")
        applyBaseStyle()
    }

    // MARK: - 글자 모양

    private var baseFont: NSFont { useMonoFont ? Theme.mono(fontSize) : Theme.ui(fontSize) }

    private var baseParagraph: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.38
        ps.lineBreakStrategy = .hangulWordPriority
        return ps
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: Theme.fg, .paragraphStyle: baseParagraph]
    }

    private func applyBaseStyle() {
        typingAttributes = baseAttributes
        highlightAll()
        updateContainerSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContainerSize()
    }

    /// 줄바꿈이 켜져 있으면 글 폭을 화면에 맞추되 최대 900pt(원본 편집기와 같음), 꺼져 있으면 가로로 길게 둔다.
    /// 칸을 좁혀도 글이 보이는 폭 안에서 줄바꿈되도록 최솟값은 아주 작게(80pt) 둔다.
    private func updateContainerSize() {
        guard let container = textContainer else { return }
        if lineWrap {
            let width = max(80, min(bounds.width, 900) - textContainerInset.width * 2)
            if container.size.width != width {
                container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            isHorizontallyResizable = false
            enclosingScrollView?.hasHorizontalScroller = false
        } else {
            container.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = true
            enclosingScrollView?.hasHorizontalScroller = true
        }
    }

    // MARK: - 문법 색칠

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplyingHighlight else { return }
        if textStorage.length <= fullHighlightLimit {
            highlight(range: NSRange(location: 0, length: textStorage.length), in: textStorage)
        } else {
            let ns = textStorage.string as NSString
            highlight(range: ns.paragraphRange(for: editedRange), in: textStorage)
        }
    }

    /// 글 전체를 다시 색칠한다(글꼴·모양 설정이 바뀌었을 때, 다른 파일을 열었을 때).
    public func highlightAll() {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        highlight(range: NSRange(location: 0, length: storage.length), in: storage)
        storage.endEditing()
        needsDisplay = true
    }

    private func highlight(range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0 || storage.length == 0 else { return }
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }
        let base = baseAttributes
        storage.setAttributes(base, range: range)
        let ns = storage.string as NSString
        let text = range.location == 0 && range.length == ns.length ? storage.string : ns.substring(with: range)
        let spans = MarkdownHighlighter.spans(for: text)
        let font = baseFont
        // 순서: 줄 단위(제목·인용) → 글자 단위 → 기호(흐리게)
        let order: (HighlightStyle) -> Int = {
            switch $0 {
            case .heading, .quote: return 0
            case .syntax: return 2
            default: return 1
            }
        }
        for span in spans.sorted(by: { order($0.style) < order($1.style) }) {
            let r = NSRange(location: span.range.location + range.location, length: span.range.length)
            guard NSMaxRange(r) <= storage.length else { continue }
            switch span.style {
            case .heading(let level):
                let scale: [CGFloat] = [1.35, 1.2, 1.08, 1, 1, 1]
                storage.addAttribute(.font, value: Theme.bold(useMonoFont ? Theme.mono(fontSize * scale[level - 1]) : Theme.ui(fontSize * scale[level - 1])), range: r)
            case .strong:
                let current = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? font
                storage.addAttribute(.font, value: Theme.bold(current), range: r)
            case .emphasis:
                let current = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? font
                storage.addAttributes(Theme.italicAttributes(for: current), range: r)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .link:
                storage.addAttribute(.foregroundColor, value: Theme.accent, range: r)
            case .url:
                storage.addAttributes([.foregroundColor: Theme.muted, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .code:
                storage.addAttributes([.font: Theme.mono(fontSize * 0.93), .foregroundColor: Theme.codeFg], range: r)
            case .quote:
                storage.addAttributes([.foregroundColor: Theme.muted, .obliqueness: 0.12], range: r)
            case .syntax:
                storage.addAttribute(.foregroundColor, value: Theme.syntax, range: r)
            }
        }
    }

    // MARK: - 그리기 (현재 줄 강조, 빈 편집기 안내 문구)

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, selectedRange().length == 0, window?.firstResponder === self else { return }
        let len = (string as NSString).length
        let loc = min(selectedRange().location, len)
        var lineRect: NSRect
        if len == 0 || loc == len && (string.hasSuffix("\n") || len == 0) {
            lineRect = lm.extraLineFragmentRect
            if lineRect.isEmpty { return }
        } else {
            let glyph = lm.glyphIndexForCharacter(at: max(0, min(loc, len - 1)))
            lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        _ = tc
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        Theme.activeLine.setFill()
        lineRect.fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: Theme.muted]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attrs)
        }
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: - 글 바꾸기

    /// 명령 결과를 적용한다. 실행 취소(⌘Z) 한 번으로 되돌릴 수 있다.
    public func apply(_ result: CommandResult) {
        let edits = result.edits.sorted { $0.range.location > $1.range.location }
        guard !edits.isEmpty else {
            setSelectedRange(result.selection)
            return
        }
        breakUndoCoalescing()
        let ranges = edits.map { NSValue(range: $0.range) }
        let strings = edits.map(\.replacement)
        guard shouldChangeText(inRanges: ranges, replacementStrings: strings), let storage = textStorage else { return }
        storage.beginEditing()
        for e in edits { storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: baseAttributes)) }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        let len = (string as NSString).length
        let sel = NSRange(location: min(result.selection.location, len),
                          length: max(0, min(result.selection.length, len - min(result.selection.location, len))))
        setSelectedRange(sel)
        scrollRangeToVisible(sel)
    }

    /// 서식 명령 실행 (도구 막대 버튼, 단축키, 메뉴)
    public func run(_ command: FormatCommand) {
        let selections = selectedRanges.map(\.rangeValue)
        apply(EditorCommands.run(command, text: string, selections: selections))
        window?.makeFirstResponder(self)
    }

    /// 전체 글을 바꾼다. keepHistory가 거짓이면 실행 취소 기록을 새로 시작한다(다른 파일을 열 때).
    public func setText(_ text: String, keepHistory: Bool) {
        if keepHistory {
            let full = NSRange(location: 0, length: (string as NSString).length)
            if shouldChangeText(in: full, replacementString: text) {
                textStorage?.replaceCharacters(in: full, with: text)
                didChangeText()
            }
        } else {
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
            undoManager?.removeAllActions(withTarget: textStorage as Any)
            undoManager?.removeAllActions()
            setSelectedRange(NSRange(location: 0, length: 0))
            scrollToBeginningOfDocument(nil)
        }
        highlightAll()
    }

    public override func didChangeText() {
        super.didChangeText()
        editorDelegate?.editorDidChange(self)
    }

    // MARK: - 키 입력

    /// ⌘⇧8, ⌘⇧7처럼 Shift와 숫자를 같이 쓰는 단축키는 자판에 따라 글자(*, &)가 달라져 메뉴가 못 알아들을 수 있다.
    /// 키 위치(keyCode)로 직접 처리한다.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .shift], window?.firstResponder === self {
            switch event.keyCode {
            case 28: run(.ul); return true   // 8
            case 26: run(.ol); return true   // 7
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func insertNewline(_ sender: Any?) {
        // 한글 조합 중에는 손대지 않는다.
        if hasMarkedText() { super.insertNewline(sender); return }
        if let r = EditorCommands.continueList(text: string, selection: selectedRange()) {
            apply(r)
        } else {
            super.insertNewline(sender)
        }
    }

    public override func insertTab(_ sender: Any?) {
        if hasMarkedText() { super.insertTab(sender); return }
        apply(EditorCommands.indent(text: string, selections: selectedRanges.map(\.rangeValue), outdent: false))
    }

    public override func insertBacktab(_ sender: Any?) {
        apply(EditorCommands.indent(text: string, selections: selectedRanges.map(\.rangeValue), outdent: true))
    }

    // MARK: - 붙여넣기

    public override func paste(_ sender: Any?) {
        guard editorDelegate?.editorPasteConversionEnabled(self) == true else {
            pastePlain()
            return
        }
        let pb = pasteboard
        let html = pb.string(forType: .html)
        let text = pb.string(forType: .string)
        var md: String?
        do {
            md = try PasteConverter.convertPaste(html: html, text: text)
        } catch {
            appLog.error("붙여넣기", "붙여넣기 변환 실패, 원문 텍스트로 붙여넣습니다", error)
        }
        if let md {
            insertText(md, replacementRange: selectedRange())
            appLog.info("붙여넣기", "서식 있는 붙여넣기를 마크다운으로 변환했습니다", ["chars": "\(md.count)"])
        } else {
            pastePlain()
        }
    }

    public override func pasteAsPlainText(_ sender: Any?) { pastePlain() }

    /// 클립보드의 일반 텍스트를 그대로 넣는다.
    private func pastePlain() {
        guard let text = pasteboard.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    // MARK: - 끌어다 놓기

    private func droppedMarkdownURL(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppedMarkdownURL(sender) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = droppedMarkdownURL(sender) {
            editorDelegate?.editor(self, didDropFile: url)
            return true
        }
        return super.performDragOperation(sender)
    }
}
