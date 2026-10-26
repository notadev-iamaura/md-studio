// 보조 창: 설정, 로그, 도움말 (src/index.html의 dlg-settings, dlg-log, dlg-help)
// - 설정: 표 변환 방식, 엔터 한 번 줄바꿈, 붙여넣기 변환, 자동 저장, 스크롤 맞추기, 긴 줄 줄바꿈, 글꼴, 글자 크기, 테마
// - 로그: 목록 보기, 상세(debug) 보기, 비우기, 로그 복사, 로그 폴더 열기 (문서 본문은 기록하지 않음)
// - 도움말: 복사 버튼, 저장, 단축키 안내와 "예제 문서 불러오기"
// 의존성: AppKit, MDCore
import AppKit
import MDCore

private func makePanel(title: String, size: NSSize) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.center()
    return panel
}

// MARK: - 설정

public final class SettingsWindowController: NSWindowController {
    private weak var main: MainWindowController?
    private let tableMode = NSPopUpButton()
    private let breaks = NSButton(checkboxWithTitle: "엔터 한 번을 줄바꿈으로 인식", target: nil, action: nil)
    private let paste = NSButton(checkboxWithTitle: "웹/문서에서 붙여넣으면 마크다운으로 변환", target: nil, action: nil)
    private let autosave = NSButton(checkboxWithTitle: "열린 파일에 자동 저장", target: nil, action: nil)
    private let syncScroll = NSButton(checkboxWithTitle: "편집기와 미리보기 스크롤 맞추기", target: nil, action: nil)
    private let lineWrap = NSButton(checkboxWithTitle: "긴 줄 자동 줄바꿈", target: nil, action: nil)
    private let font = NSPopUpButton()
    private let fontSize = NSPopUpButton()
    private let theme = NSPopUpButton()
    private let tableModes: [(String, String)] = [
        ("title", "제목형: 첫 열을 제목, 나머지를 하위 항목으로"),
        ("inline", "한 줄형: 한 행을 한 줄로"),
        ("grid", "고정폭 표: 표 모양 유지 (코드 블록)"),
    ]
    private let sizes = [13, 14, 15, 16, 17, 18, 20]

    init(main: MainWindowController) {
        self.main = main
        super.init(window: makePanel(title: "설정", size: NSSize(width: 520, height: 360)))
        build()
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    private func build() {
        for (_, t) in tableModes { tableMode.addItem(withTitle: t) }
        font.addItems(withTitles: ["일반 글꼴", "고정폭 글꼴"])
        fontSize.addItems(withTitles: sizes.map(String.init))
        theme.addItems(withTitles: ["시스템 설정 따르기", "밝게", "어둡게"])
        for c in [tableMode, font, fontSize, theme] as [NSControl] {
            c.target = self
            c.action = #selector(changed)
        }
        for b in [breaks, paste, autosave, syncScroll, lineWrap] {
            b.target = self
            b.action = #selector(changed)
        }
        func labeled(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [labeled("표 변환 방식"), tableMode],
            [NSGridCell.emptyContentView, breaks],
            [NSGridCell.emptyContentView, paste],
            [NSGridCell.emptyContentView, autosave],
            [NSGridCell.emptyContentView, syncScroll],
            [NSGridCell.emptyContentView, lineWrap],
            [labeled("편집기 글꼴"), font],
            [labeled("편집기 글자 크기"), fontSize],
            [labeled("화면 테마"), theme],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        close.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            close.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window?.contentView = content
    }

    /// 현재 설정 값으로 칸을 채우고 창을 띄운다.
    public func show() {
        guard let s = main?.settings else { return }
        tableMode.selectItem(at: tableModes.firstIndex { $0.0 == s.tableMode } ?? 0)
        breaks.state = s.breaks ? .on : .off
        paste.state = s.pasteConvert ? .on : .off
        autosave.state = s.autosave ? .on : .off
        syncScroll.state = s.syncScroll ? .on : .off
        lineWrap.state = s.lineWrap ? .on : .off
        font.selectItem(at: s.editorFont == .mono ? 1 : 0)
        fontSize.selectItem(at: sizes.firstIndex(of: s.editorFontSize) ?? 2)
        theme.selectItem(at: [ThemeSetting.system, .light, .dark].firstIndex(of: s.theme) ?? 0)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func changed() {
        let modes = tableModes
        let sizeList = sizes
        main?.changeSetting { s in
            s.tableMode = modes[max(0, self.tableMode.indexOfSelectedItem)].0
            s.breaks = self.breaks.state == .on
            s.pasteConvert = self.paste.state == .on
            s.autosave = self.autosave.state == .on
            s.syncScroll = self.syncScroll.state == .on
            s.lineWrap = self.lineWrap.state == .on
            s.editorFont = self.font.indexOfSelectedItem == 1 ? .mono : .sans
            s.editorFontSize = sizeList[max(0, self.fontSize.indexOfSelectedItem)]
            s.theme = [ThemeSetting.system, .light, .dark][max(0, self.theme.indexOfSelectedItem)]
        }
    }

    @objc private func closeWindow() { window?.close() }
}

// MARK: - 로그

public final class LogWindowController: NSWindowController {
    private let textView = NSTextView()
    private let showDebug = NSButton(checkboxWithTitle: "상세(debug) 로그도 보기", target: nil, action: nil)
    private var listener: UUID?

    public init() {
        super.init(window: makePanel(title: "로그", size: NSSize(width: 760, height: 480)))
        build()
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    private func build() {
        let hint = NSTextField(wrappingLabelWithString: "문제가 생기면 \"로그 복사\"를 눌러 내용을 전달해 주세요. 문서 내용은 기록하지 않습니다.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        showDebug.target = self
        showDebug.action = #selector(render)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.font = Theme.mono(11.5)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("로그 목록")
        let clear = NSButton(title: "비우기", target: self, action: #selector(clearLogs))
        let copy = NSButton(title: "로그 복사", target: self, action: #selector(copyLogs))
        let folder = NSButton(title: "로그 폴더 열기", target: self, action: #selector(openFolder))
        let close = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        let buttons = NSStackView(views: [folder, NSView(), clear, copy, close])
        let stack = NSStackView(views: [hint, showDebug, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [hint, scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window?.contentView = stack
    }

    public func show() {
        if listener == nil {
            listener = appLog.addListener { [weak self] _ in
                DispatchQueue.main.async { if self?.window?.isVisible == true { self?.render() } }
            }
        }
        render()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func render() {
        let debug = showDebug.state == .on
        let lines = appLog.allEntries().filter { debug || $0.level != .debug }.suffix(400)
        let out = NSMutableAttributedString()
        for e in lines {
            let color: NSColor = e.level == .error ? .systemRed : e.level == .warn ? .systemOrange : e.level == .debug ? .secondaryLabelColor : .labelColor
            out.append(NSAttributedString(string: e.formatted + "\n", attributes: [.font: Theme.mono(11.5), .foregroundColor: color]))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func clearLogs() {
        appLog.clearEntries()
        render()
    }

    @objc private func copyLogs() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let text = "MD Studio \(version) / macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + appLog.allEntries().map(\.formatted).joined(separator: "\n")
        do {
            try Clipboard.write(ClipboardPayload(text: text))
        } catch {
            appLog.error("로그", "로그를 복사하지 못했습니다", error)
        }
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: appLog.directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(appLog.directoryURL)
    }

    @objc private func closeWindow() { window?.close() }
}

// MARK: - 도움말

public final class HelpWindowController: NSWindowController {
    private weak var main: MainWindowController?

    init(main: MainWindowController) {
        self.main = main
        super.init(window: makePanel(title: "사용법", size: NSSize(width: 620, height: 600)))
        build()
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    static func helpText() -> NSAttributedString {
        let md = """
        #### 복사 버튼

        - **Slack 복사**: 굵게, 링크, 목록은 살리고 표는 목록으로 풀어서 복사합니다. 메신저나 메모장처럼 서식을 못 받는 곳에는 깔끔한 텍스트로 들어갑니다.
        - **서식 복사**: Google Docs, Word, Gmail, Notion에 표와 제목까지 그대로 붙여넣습니다.
        - **텍스트 복사**: 서식 없이 •, ◦ 같은 기호로 구조를 표현한 텍스트입니다.
        - **MD 복사**: 마크다운 원문입니다.
        - 편집기에서 일부를 선택한 채로 누르면 선택한 부분만 복사합니다.

        #### 저장

        - 왼쪽 "폴더 열기"로 내 맥의 폴더를 고르면, 그 폴더의 .md 파일을 직접 열고 저장합니다. 서버로 전송되는 내용은 없습니다.
        - 작성 중인 내용은 임시본으로도 보관되어, 앱이 갑자기 꺼져도 다시 열면 복구됩니다.
        - .md 파일을 창에 끌어다 놓아도 열리고, Finder의 "다음으로 열기 → MD Studio"로도 열립니다.

        #### 단축키

        | 단축키 | 기능 | 단축키 | 기능 |
        |---|---|---|---|
        | ⌘S | 저장 | ⌘O | 열기 |
        | ⌘B | 굵게 | ⌘I | 기울임 |
        | ⌘K | 링크 | ⌘E | 인라인 코드 |
        | ⌘⌥1~3 | 제목 1~3 | ⌘⇧X | 취소선 |
        | ⌘⇧8 | 글머리 목록 | ⌘⇧7 | 번호 목록 |
        | ⌘F | 찾기/바꾸기 | ⌘\\ | 보기 전환 |
        | Tab | 목록 들여쓰기 | ⌘Z | 실행 취소 |
        | ⌘⇧C | Slack용으로 복사 | ⌘⇧T | 텍스트로 복사 |
        """
        return DocRenderer.render(md, style: PreviewStyle(baseSize: 13.5), options: MDOptions())
    }

    private func build() {
        let (scroll, text) = PreviewTextView.make()
        text.maxContentWidth = 600
        text.textStorage?.setAttributedString(Self.helpText())
        let sample = NSButton(title: "예제 문서 불러오기", target: self, action: #selector(loadSample))
        let close = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), sample, close])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window?.contentView = stack
    }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func loadSample() {
        window?.close()
        main?.perform("loadSample")
    }

    @objc private func closeWindow() { window?.close() }
}
