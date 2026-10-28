// 창을 이루는 부품들 (src/index.html의 화면 구조를 그대로 따름)
// - TopBar: 파일 목록 버튼, 앱 이름, 파일 이름·저장 안 됨 표시, 새 문서/열기/저장/다른 이름, 보기 전환, 복사 4종, 내보내기, 설정, 도움말
// - FormatBar: 서식 도구 막대 (H1~H3, 굵게, 기울임, 취소선, 코드, 링크, 목록, 할 일, 인용, 코드 블록, 표, 구분선)
// - PreviewPane: 미리보기 탭(문서 / Slack 미리보기 / 텍스트 미리보기)과 표 변환 방식
// - SidebarView: 폴더 이름, 새 파일·새로고침, 검색, 파일 목록, 빈 상태 안내, 다른 폴더 열기·폴더 닫기
// - StatusBar: 글자 수, 저장 상태, 저장 위치, 로그 버튼
// - ToastCenter: 잠깐 떴다 사라지는 알림
// 의존성: AppKit, MDCore
import AppKit
import MDCore

// MARK: - 공통 도구

/// 클릭하면 closure를 부르는 버튼
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, tooltip: String? = nil, style: NSButton.BezelStyle = .rounded, primary: Bool = false,
                     handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(fire)
        bezelStyle = style
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        toolTip = tooltip
        setAccessibilityLabel(tooltip ?? title)
        if primary { keyEquivalent = ""; bezelColor = Theme.accent }
    }

    @objc private func fire() { handler?() }
}

/// 배경색을 칠하는 단순한 화면 조각.
/// 그림판(비트맵)을 따로 만들지 않도록 레이어 색으로 칠한다. 창 전체 크기의 그림판을 아끼면 메모리가 크게 준다.
class ColorView: NSView {
    var color: NSColor = Theme.panel { didSet { needsDisplay = true } }
    var bottomLine = false { didSet { needsLayout = true } }
    var topLine = false { didSet { needsLayout = true } }
    var rightLine = false { didSet { needsLayout = true } }
    private let lineLayers = (bottom: CALayer(), top: CALayer(), right: CALayer())

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for l in [lineLayers.bottom, lineLayers.top, lineLayers.right] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // 동적 색(밝게/어둡게)은 이 화면의 모양으로 풀어서 넣는다.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
            let line = Theme.line.cgColor
            for l in [lineLayers.bottom, lineLayers.top, lineLayers.right] { l.backgroundColor = line }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let scale = window?.backingScaleFactor ?? 2
        let px = 1 / scale * scale // 1pt
        lineLayers.bottom.isHidden = !bottomLine
        lineLayers.top.isHidden = !topLine
        lineLayers.right.isHidden = !rightLine
        // 레이어 좌표는 뒤집히지 않았으므로(아래가 0) 위·아래를 바꿔 놓는다.
        lineLayers.bottom.frame = CGRect(x: 0, y: 0, width: b.width, height: px)
        lineLayers.top.frame = CGRect(x: 0, y: b.height - px, width: b.width, height: px)
        lineLayers.right.frame = CGRect(x: b.width - px, y: 0, width: px, height: b.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.muted) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    return l
}

// MARK: - 상단 막대

final class TopBar: ColorView {
    let sidebarButton: ActionButton
    let fileName = label("새 문서", size: 13, weight: .medium, color: Theme.fg)
    let dirtyDot = NSView()
    let viewSwitch = NSSegmentedControl(labels: ["편집", "분할", "보기"], trackingMode: .selectOne, target: nil, action: nil)
    let exportMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    var onViewChange: ((ViewMode) -> Void)?
    var onExport: ((String) -> Void)?

    init(actions: @escaping (String) -> Void) {
        sidebarButton = ActionButton("☰", tooltip: "파일 목록 열고 닫기", style: .texturedRounded) { actions("toggleSidebar") }
        super.init(frame: .zero)
        color = Theme.panel
        bottomLine = true

        let brand = label("MD Studio", size: 13, weight: .bold, color: Theme.fg)
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = Theme.accent.cgColor
        dirtyDot.layer?.cornerRadius = 4
        dirtyDot.toolTip = "저장하지 않은 변경 사항"
        dirtyDot.isHidden = true
        dirtyDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dirtyDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        fileName.toolTip = "현재 문서"
        fileName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileName.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let fileButtons = [
            ActionButton("새 문서", tooltip: "새 문서 (⌘N)") { actions("new") },
            ActionButton("열기", tooltip: "파일 열기 (⌘O)") { actions("open") },
            ActionButton("저장", tooltip: "저장 (⌘S)") { actions("save") },
            ActionButton("다른 이름", tooltip: "다른 이름으로 저장 (⌘⇧S)") { actions("saveAs") },
        ]
        viewSwitch.controlSize = .small
        viewSwitch.target = self
        viewSwitch.action = #selector(viewChanged)
        viewSwitch.setToolTip("편집만 보기", forSegment: 0)
        viewSwitch.setToolTip("편집과 미리보기 나란히 (⌘\\)", forSegment: 1)
        viewSwitch.setToolTip("미리보기만 보기", forSegment: 2)

        let copyButtons = [
            ActionButton("Slack 복사", tooltip: "Slack에 붙여넣기 좋게 복사 (표는 목록으로 풀어서) ⌘⇧C", primary: true) { actions("copySlack") },
            ActionButton("서식 복사", tooltip: "Google Docs, Word, 메일에 서식 그대로 붙여넣기 ⌘⌥⇧C") { actions("copyRich") },
            ActionButton("텍스트 복사", tooltip: "서식 없이 깔끔한 텍스트로 복사 ⌘⇧T") { actions("copyPlain") },
            ActionButton("MD 복사", tooltip: "마크다운 원문 복사") { actions("copyMd") },
        ]

        exportMenu.controlSize = .small
        exportMenu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        exportMenu.addItem(withTitle: "내보내기")
        for (title, action) in [("HTML 보고서로 저장…", "exportHtml"), ("PDF로 저장…", "exportPdf"), ("마크다운 사본 저장…", "downloadMd")] {
            let item = NSMenuItem(title: title, action: #selector(exportPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            exportMenu.menu?.addItem(item)
        }
        exportMenu.toolTip = "HTML 보고서, PDF, 마크다운 사본"
        onExport = actions

        let settings = ActionButton("설정", tooltip: "설정 (⌘,)") { actions("settings") }
        let help = ActionButton("?", tooltip: "사용법과 단축키 (⌘/)") { actions("help") }

        let left = NSStackView(views: [sidebarButton, brand, fileName, dirtyDot])
        left.spacing = 8
        let group1 = NSStackView(views: fileButtons)
        group1.spacing = 4
        let group2 = NSStackView(views: copyButtons)
        group2.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [left, group1, spacer, viewSwitch, group2, exportMenu, settings, help])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.alignment = .centerY
        row.detachesHiddenViews = true
        // 창이 좁으면 덜 중요한 것부터 숨긴다.
        row.setVisibilityPriority(.init(300), for: group1)
        row.setVisibilityPriority(.init(400), for: exportMenu)
        left.setVisibilityPriority(.init(200), for: brand)
        group2.setVisibilityPriority(.init(350), for: copyButtons[3])
        group2.setVisibilityPriority(.init(360), for: copyButtons[2])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    func setView(_ mode: ViewMode) {
        viewSwitch.selectedSegment = [ViewMode.edit, .split, .preview].firstIndex(of: mode) ?? 1
    }

    @objc private func viewChanged() {
        let modes: [ViewMode] = [.edit, .split, .preview]
        let i = viewSwitch.selectedSegment
        if i >= 0 && i < modes.count { onViewChange?(modes[i]) }
    }

    @objc private func exportPicked(_ sender: NSMenuItem) {
        if let a = sender.representedObject as? String { onExport?(a) }
    }
}

// MARK: - 서식 도구 막대

/// 가로 막대의 항목을 앞에서부터 들어가는 만큼만 보이고 나머지는 숨긴다.
/// NSStackView는 좁아지면 버튼을 숨기지 않고 찌그러뜨리므로(“…”), 폭을 직접 재서 정한다.
/// 끝에 남는 구분선은 함께 숨긴다.
enum RowFitter {
    /// - Parameters:
    ///   - views: 막대 항목(보여 줄 순서)
    ///   - available: 항목이 쓸 수 있는 폭
    ///   - spacing: 항목 사이 간격
    /// - Returns: 보이게 된 항목 수
    @discardableResult
    static func fit(_ views: [NSView], available: CGFloat, spacing: CGFloat) -> Int {
        var used: CGFloat = 0
        var overflow = false
        var shown = 0
        for v in views {
            let w = max(v.fittingSize.width, 1)
            let need = shown == 0 ? w : used + spacing + w
            let show = !overflow && need <= available
            if show { used = need; shown += 1 } else { overflow = true }
            setHidden(v, !show)
        }
        for v in views.reversed() where !v.isHidden {
            guard v is NSBox else { break }
            setHidden(v, true)
            shown -= 1
        }
        return shown
    }

    /// 값이 바뀔 때만 고친다(레이아웃 중에 같은 값을 다시 넣어 반복 배치가 일어나지 않게).
    static func setHidden(_ v: NSView, _ hidden: Bool) {
        if v.isHidden != hidden { v.isHidden = hidden }
    }
}

final class FormatBar: ColorView {
    init(run: @escaping (FormatCommand) -> Void) {
        super.init(frame: .zero)
        color = Theme.bg
        bottomLine = true
        let items: [(String, String, FormatCommand)?] = [
            ("H1", "제목 1 (⌘⌥1)", .h1), ("H2", "제목 2 (⌘⌥2)", .h2), ("H3", "제목 3 (⌘⌥3)", .h3), nil,
            ("B", "굵게 (⌘B)", .bold), ("I", "기울임 (⌘I)", .italic), ("S", "취소선 (⌘⇧X)", .strike),
            ("</>", "인라인 코드 (⌘E)", .code), ("링크", "링크 (⌘K)", .link), nil,
            ("• 목록", "글머리 목록 (⌘⇧8)", .ul), ("1. 목록", "번호 목록 (⌘⇧7)", .ol), ("☐ 할 일", "할 일 목록", .task),
            ("❝ 인용", "인용", .quote), nil,
            ("코드 블록", "코드 블록", .codeBlock), ("표", "표 넣기", .table), ("―", "구분선", .hr),
        ]
        var views: [NSView] = []
        for item in items {
            guard let (title, tip, cmd) = item else {
                let sep = NSBox()
                sep.boxType = .separator
                sep.heightAnchor.constraint(equalToConstant: 16).isActive = true
                views.append(sep)
                continue
            }
            let b = ActionButton(title, tooltip: tip, style: .recessed) { run(cmd) }
            b.isBordered = false
            b.contentTintColor = Theme.muted
            switch cmd {
            case .bold: b.font = .boldSystemFont(ofSize: 12)
            case .italic: b.attributedTitle = NSAttributedString(string: "I", attributes: [.obliqueness: 0.2, .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.muted])
            case .strike: b.attributedTitle = NSAttributedString(string: "S", attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.muted])
            case .code: b.font = Theme.mono(11)
            default: b.font = .systemFont(ofSize: 12)
            }
            views.append(b)
        }
        buttons = views
        let row = NSStackView(views: views)
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.detachesHiddenViews = true
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("서식")
    }

    /// 버튼들 (보이는 순서)
    private var buttons: [NSView] = []

    /// 좁으면 뒤쪽 버튼부터 숨긴다. 숨긴 명령은 "서식" 메뉴와 단축키로 쓸 수 있다.
    override func layout() {
        super.layout()
        RowFitter.fit(buttons, available: bounds.width - 16 - 8, spacing: 6)
    }

    /// 지금 보이는 버튼 수 (자가 점검용)
    var totalItemCount: Int { buttons.filter { !($0 is NSBox) }.count }
    var visibleItemCount: Int { buttons.filter { !$0.isHidden && !($0 is NSBox) }.count }
    /// 보이지만 원래 폭보다 찌그러진 버튼 수 (자가 점검용, 0이어야 한다)
    var compressedItemCount: Int { buttons.filter { !$0.isHidden && $0.frame.width + 1 < $0.fittingSize.width }.count }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }
}

// MARK: - 미리보기

/// 읽기 전용 미리보기 글 상자. 내용 폭을 최대 너비에 맞춰 가운데에 둔다.
final class PreviewTextView: NSTextView, NSTextViewDelegate {
    var maxContentWidth: CGFloat = 820 { didSet { updateInsets() } }

    static func make() -> (NSScrollView, PreviewTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = true
        view.backgroundColor = Theme.bg
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.delegate = view
        view.setAccessibilityLabel("미리보기")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = view
        return (scroll, view)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let x = max(28, (bounds.width - maxContentWidth) / 2)
        let inset = NSSize(width: x, height: 24)
        if textContainerInset != inset { textContainerInset = inset }
    }

    /// 링크는 기본 브라우저(또는 메일 앱)로 연다. 그 밖의 주소는 열지 않는다.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            appLog.info("미리보기", "열 수 없는 링크라 무시합니다")
            return true
        }
        NSWorkspace.shared.open(url)
        appLog.info("미리보기", "링크 열기", ["scheme": scheme])
        return true
    }
}

final class PreviewPane: ColorView {
    let tabs = NSSegmentedControl(labels: ["문서", "Slack 미리보기", "텍스트 미리보기"], trackingMode: .selectOne, target: nil, action: nil)
    let tableMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let scroll: NSScrollView
    let textView: PreviewTextView
    var onTab: ((PreviewTab) -> Void)?
    var onTableMode: ((String) -> Void)?
    private let modes: [(String, String)] = [("title", "제목형"), ("inline", "한 줄형"), ("grid", "고정폭 표")]
    /// 탭 이름: 넓을 때 / 좁을 때
    private let fullTabLabels = ["문서", "Slack 미리보기", "텍스트 미리보기"]
    private let shortTabLabels = ["문서", "Slack", "텍스트"]
    private var fullTabsWidth: CGFloat = 0
    private let modeLabel = label("표 변환")

    override init(frame: NSRect) {
        (scroll, textView) = PreviewTextView.make()
        super.init(frame: frame)
        color = Theme.bg
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setToolTip("문서로 보기", forSegment: 0)
        tabs.setToolTip("Slack에 붙였을 때 모습", forSegment: 1)
        tabs.setToolTip("텍스트 복사 결과", forSegment: 2)
        tableMode.controlSize = .small
        tableMode.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for (_, title) in modes { tableMode.addItem(withTitle: title) }
        tableMode.target = self
        tableMode.action = #selector(modeChanged)
        tableMode.toolTip = "Slack/텍스트로 바꿀 때 표를 어떻게 풀지"
        fullTabsWidth = tabs.fittingSize.width

        let header = ColorView()
        header.color = Theme.bg
        header.bottomLine = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [tabs, spacer, modeLabel, tableMode])
        row.spacing = 6
        row.detachesHiddenViews = true
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            row.topAnchor.constraint(equalTo: header.topAnchor),
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -1),
            header.heightAnchor.constraint(equalToConstant: 32),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    /// 칸이 좁으면 탭 이름을 줄이고, 그래도 모자라면 "표 변환" 글자 → 표 변환 메뉴 순서로 숨긴다.
    override func layout() {
        super.layout()
        let available = bounds.width - 24
        let labels = fullTabsWidth + 12 <= available ? fullTabLabels : shortTabLabels
        for (i, title) in labels.enumerated() where tabs.label(forSegment: i) != title {
            tabs.setLabel(title, forSegment: i)
        }
        // 탭 뒤에 최소 12px 여백을 두고 남은 폭에 표 변환 메뉴와 글자를 넣는다.
        RowFitter.fit([tableMode, modeLabel], available: available - tabs.fittingSize.width - 12, spacing: 6)
    }

    /// 지금 탭 이름이 줄어 있는지 (자가 점검용)
    var isTabLabelShort: Bool { tabs.label(forSegment: 1) == shortTabLabels[1] }
    var isTableModeVisible: Bool { !tableMode.isHidden }
    var isTabsCompressed: Bool { tabs.frame.width + 1 < tabs.fittingSize.width }

    func setTab(_ tab: PreviewTab) {
        tabs.selectedSegment = [PreviewTab.doc, .slack, .plain].firstIndex(of: tab) ?? 0
        textView.maxContentWidth = tab == .doc ? 820 : 760
    }

    func setTableMode(_ mode: String) {
        tableMode.selectItem(at: modes.firstIndex { $0.0 == mode } ?? 0)
    }

    /// 미리보기 내용을 바꾼다. 스크롤 위치는 되도록 유지한다.
    func show(_ attr: NSAttributedString) {
        let y = scroll.contentView.bounds.origin.y
        textView.textStorage?.setAttributedString(attr)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func tabChanged() {
        let all: [PreviewTab] = [.doc, .slack, .plain]
        let i = tabs.selectedSegment
        if i >= 0 && i < all.count { onTab?(all[i]) }
    }

    @objc private func modeChanged() {
        let i = tableMode.indexOfSelectedItem
        if i >= 0 && i < modes.count { onTableMode?(modes[i].0) }
    }
}

// MARK: - 파일 목록

final class FileCellView: NSTableCellView {
    let name = label("", size: 13, color: Theme.fg)
    let dir = label("", size: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView(views: [name, dir])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        name.lineBreakMode = .byTruncatingTail
        dir.lineBreakMode = .byTruncatingHead
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }
}

final class SidebarView: ColorView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let folderName = label("폴더 없음", size: 12, weight: .semibold, color: Theme.fg)
    let newButton: ActionButton
    let refreshButton: ActionButton
    let filter = NSSearchField()
    let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let empty = NSStackView()
    let reconnectButton: ActionButton
    private let foot = NSStackView()
    private let emptyMessage = label("", size: 12)
    private let filler = NSView()

    private(set) var shown: [FileEntry] = []
    private var all: [FileEntry] = []
    private var activePath: String?
    private var hasFolder = false
    var onOpen: ((FileEntry) -> Void)?

    init(actions: @escaping (String) -> Void) {
        newButton = ActionButton("＋", tooltip: "이 폴더에 새 파일", style: .texturedRounded) { actions("newInFolder") }
        refreshButton = ActionButton("↻", tooltip: "목록 새로고침", style: .texturedRounded) { actions("refreshFolder") }
        reconnectButton = ActionButton("지난 폴더 다시 열기", tooltip: nil) { actions("reconnectFolder") }
        super.init(frame: .zero)
        color = Theme.panel
        rightLine = true

        let head = NSStackView(views: [folderName, NSView(), newButton, refreshButton])
        head.spacing = 4
        folderName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        filter.placeholderString = "파일 이름 검색"
        filter.controlSize = .small
        filter.delegate = self
        filter.isHidden = true

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        // 사이드바 색 위에 그대로 보이도록 표 자체 배경은 칠하지 않는다.
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("파일 목록")
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        let intro = label("내 맥의 폴더를 열면 그 안의 마크다운 파일을 바로 열고 저장할 수 있습니다.", size: 12)
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 0
        intro.preferredMaxLayoutWidth = 200
        let open = ActionButton("폴더 열기", tooltip: "폴더 열기 (⌘⇧O)", primary: true) { actions("openFolder") }
        reconnectButton.isHidden = true
        empty.setViews([intro, open, reconnectButton], in: .top)
        empty.orientation = .vertical
        empty.alignment = .leading
        empty.spacing = 10

        let other = ActionButton("다른 폴더 열기", tooltip: nil, style: .inline) { actions("openFolder") }
        let close = ActionButton("폴더 닫기", tooltip: nil, style: .inline) { actions("closeFolder") }
        other.isBordered = false
        close.isBordered = false
        other.contentTintColor = Theme.accent
        close.contentTintColor = Theme.accent
        foot.setViews([other, close], in: .leading)
        foot.spacing = 10
        foot.isHidden = true

        emptyMessage.isHidden = true
        emptyMessage.lineBreakMode = .byWordWrapping
        emptyMessage.maximumNumberOfLines = 0

        // 폴더가 없을 때 남는 아래쪽 공간을 채워 안내 문구를 위에 붙인다.
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        filler.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let stack = NSStackView(views: [head, filter, emptyMessage, tableScroll, empty, filler, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [head, filter, tableScroll, empty, emptyMessage] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(folder: nil, files: [], activePath: nil)
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    /// 폴더와 파일 목록을 다시 그린다.
    func update(folder: URL?, files: [FileEntry], activePath: String?) {
        hasFolder = folder != nil
        all = files
        self.activePath = activePath
        folderName.stringValue = folder.map { FileManager.default.displayName(atPath: $0.path) } ?? "폴더 없음"
        folderName.toolTip = folder?.path
        newButton.isHidden = !hasFolder
        refreshButton.isHidden = !hasFolder
        empty.isHidden = hasFolder
        foot.isHidden = !hasFolder
        tableScroll.isHidden = !hasFolder
        filler.isHidden = hasFolder
        filter.isHidden = !hasFolder || files.count < 8
        if filter.isHidden { filter.stringValue = "" }
        applyFilter()
    }

    func showReconnect(_ folderDisplayName: String?) {
        reconnectButton.isHidden = folderDisplayName == nil
        if let n = folderDisplayName { reconnectButton.title = "\"\(n)\" 폴더 다시 열기" }
    }

    private func applyFilter() {
        let q = FileStore.normalized(filter.stringValue.trimmingCharacters(in: .whitespaces)).lowercased()
        shown = all.filter { q.isEmpty || FileStore.normalized($0.path).lowercased().contains(q) }
        emptyMessage.isHidden = !hasFolder || !shown.isEmpty
        emptyMessage.stringValue = q.isEmpty ? "마크다운 파일이 없습니다. ＋로 새로 만드세요." : "검색 결과가 없습니다"
        table.reloadData()
        if let activePath, let row = shown.firstIndex(where: { $0.path == activePath }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileCellView) ?? {
            let c = FileCellView(frame: .zero)
            c.identifier = id
            return c
        }()
        let entry = shown[row]
        cell.name.stringValue = entry.displayName
        cell.dir.stringValue = entry.directory
        cell.dir.isHidden = entry.directory.isEmpty
        cell.toolTip = entry.path
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 && row < shown.count else { return }
        onOpen?(shown[row])
    }
}

// MARK: - 하단 막대

final class StatusBar: ColorView {
    let stats = label("0자")
    let save = label("저장됨")
    let storage = label("")
    let logButton: ActionButton

    init(onLogs: @escaping () -> Void) {
        logButton = ActionButton("로그", tooltip: "로그 보기", style: .inline, handler: onLogs)
        super.init(frame: .zero)
        color = Theme.panel
        topLine = true
        logButton.isBordered = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [stats, save, storage, spacer, logButton])
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        storage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    enum SaveState { case normal, unsaved, error }

    func setSave(_ text: String, state: SaveState) {
        save.stringValue = text
        switch state {
        case .normal: save.textColor = Theme.muted
        case .unsaved: save.textColor = Theme.accent
        case .error: save.textColor = Theme.danger
        }
    }

    func setErrorCount(_ n: Int) {
        logButton.title = n > 0 ? "로그 (오류 \(n))" : "로그"
        logButton.contentTintColor = n > 0 ? Theme.danger : nil
    }
}

// MARK: - 알림 (토스트)

final class ToastCenter {
    enum Kind { case info, warn, error }
    private weak var host: NSView?
    private var stack = NSStackView()
    /// 마지막으로 띄운 알림 (자가 점검에서 확인용)
    private(set) var history: [String] = []

    init(host: NSView) {
        self.host = host
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40),
        ])
    }

    func show(_ message: String, _ kind: Kind = .info, seconds: Double = 2.6) {
        history.append(message)
        if history.count > 50 { history.removeFirst() }
        let box = ColorView()
        box.color = kind == .error ? Theme.danger : kind == .warn ? NSColor.systemOrange : Theme.fg
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = .systemFont(ofSize: 13)
        text.textColor = kind == .info ? Theme.bg : .white
        text.preferredMaxLayoutWidth = 520
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
        ])
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityLabel(message)
        stack.addArrangedSubview(box)
        while stack.arrangedSubviews.count > 3 { stack.arrangedSubviews.first?.removeFromSuperview() }
        let wait = kind == .error ? max(seconds, 5) : seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak box] in
            guard let box else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                box.animator().alphaValue = 0
            }, completionHandler: { box.removeFromSuperview() })
        }
    }
}
