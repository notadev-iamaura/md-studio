// MD Studio 메인 창: 화면 부품과 편집기·변환기·저장소를 연결한다 (src/main.js를 옮김).
// - 파일: 새 문서, 열기, 저장(⌘S), 다른 이름으로 저장, 폴더 열기·닫기·새로고침, 폴더에 새 파일
// - 안전장치: 자동 저장(1.5초), 임시본(0.7초), 외부 변경 감지, 떠나기 전 확인
// - 복사 4종, 내보내기(HTML 보고서, PDF, 마크다운 사본), 보기 모드, 스크롤 맞추기, 설정 적용
// 사용자에게 묻는 창은 Prompter를 거쳐서, 자가 점검(SelfTest)이 사람 없이 같은 흐름을 실행할 수 있다.
// 의존성: AppKit, MDCore
import AppKit
import MDCore

/// 앱이 쓰는 바깥 의존성 묶음 (실제 앱과 자가 점검이 서로 다른 것을 끼운다)
public struct AppEnvironment {
    public var settingsStore: SettingsStore
    public var drafts: DraftStore
    public var prompter: Prompter
    public var pasteboard: NSPasteboard
    /// 브라우저로 열기 (보고서 미리보기)
    public var openInBrowser: (URL) -> Void

    public init(settingsStore: SettingsStore, drafts: DraftStore, prompter: Prompter, pasteboard: NSPasteboard,
                openInBrowser: @escaping (URL) -> Void) {
        self.settingsStore = settingsStore
        self.drafts = drafts
        self.prompter = prompter
        self.pasteboard = pasteboard
        self.openInBrowser = openInBrowser
    }

    public static func live() -> AppEnvironment {
        AppEnvironment(settingsStore: SettingsStore(), drafts: DraftStore(), prompter: SystemPrompter(),
                       pasteboard: .general, openInBrowser: { NSWorkspace.shared.open($0) })
    }
}

/// 마지막 호출 후 일정 시간이 지나면 한 번 실행한다(자동 저장·임시본·미리보기).
/// 실행 루프 타이머를 쓴다. 대화상자가 떠 있거나 다른 작업이 실행 루프를 돌리는 중에도 제때 실행된다.
final class Debouncer {
    private let delay: TimeInterval
    private var timer: Timer?
    private let work: () -> Void

    init(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        self.delay = delay
        self.work = work
    }

    func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.work()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() { timer?.invalidate(); timer = nil }

    /// 기다리지 않고 지금 실행한다.
    func flush() { cancel(); work() }

    var isPending: Bool { timer != nil }
}

/// 열려 있는 파일
public struct OpenFile: Equatable {
    public var url: URL
    /// 폴더 안 파일이면 폴더 기준 상대 경로, 아니면 파일 이름
    public var path: String
    public var name: String { url.lastPathComponent }
    public var fromFolder: Bool
}

public enum CopyKind: String {
    case slack, rich, plain, md
}

/// 창 내용 전체. 파일을 끌어다 놓으면 열고, 놓을 수 있을 때 안내 문구를 보여 준다.
final class DropContainerView: ColorView {
    var onDrop: ((URL) -> Void)?
    private let overlay = NSTextField(labelWithString: "여기에 놓으면 파일을 엽니다")

    override init(frame: NSRect) {
        super.init(frame: frame)
        color = Theme.bg
        registerForDraggedTypes([.fileURL])
        overlay.font = .systemFont(ofSize: 20, weight: .semibold)
        overlay.alignment = .center
        overlay.textColor = Theme.accent
        overlay.drawsBackground = true
        overlay.backgroundColor = Theme.accentSoft.withAlphaComponent(0.92)
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    private func url(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard url(sender) != nil else { return [] }
        overlay.isHidden = false
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { overlay.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        overlay.isHidden = true
        guard let u = url(sender) else { return false }
        onDrop?(u)
        return true
    }
}

public final class MainWindowController: NSWindowController, NSWindowDelegate, EditorTextViewDelegate, NSSplitViewDelegate {
    public let env: AppEnvironment
    public private(set) var settings: AppSettings

    // 상태 (src/main.js의 state와 같다)
    public private(set) var folder: URL?
    public private(set) var files: [FileEntry] = []
    public private(set) var file: OpenFile?
    public private(set) var savedText = ""
    private var lastModified: Date?
    private var saving = false
    private var pendingSave = false
    private var externalWarned: Date?
    private var savedAt: String?
    private var saveError: String?
    private var errorCount = 0
    private var logListener: UUID?

    // 화면
    public let editor: EditorTextView
    private let editorScroll: NSScrollView
    let previewPane = PreviewPane()
    private var topBar: TopBar!
    private var formatBar: FormatBar!
    private(set) var sidebar: SidebarView!
    private var statusBar: StatusBar!
    private let split = EditorSplitView()
    private var sidebarWidth: NSLayoutConstraint!
    private let editorPane = NSView()
    private(set) var toasts: ToastCenter!
    private var root: DropContainerView!

    private var previewDebounce: Debouncer!
    private var draftDebounce: Debouncer!
    private var autosaveDebounce: Debouncer!
    private var statsDebounce: Debouncer!
    private var scrollSource: String?
    private var scrollRelease: DispatchWorkItem?

    /// 설정 창·로그 창·도움말 창
    lazy var settingsWindow = SettingsWindowController(main: self)
    lazy var logWindow = LogWindowController()
    lazy var helpWindow = HelpWindowController(main: self)

    public init(env: AppEnvironment) {
        self.env = env
        settings = env.settingsStore.load()
        (editorScroll, editor) = EditorTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MD Studio"
        window.minSize = NSSize(width: 720, height: 480)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        previewDebounce = Debouncer(0.12) { [weak self] in self?.renderPreview() }
        statsDebounce = Debouncer(0.15) { [weak self] in self?.updateStats() }
        draftDebounce = Debouncer(0.7) { [weak self] in self?.storeDraft() }
        autosaveDebounce = Debouncer(1.5) { [weak self] in
            guard let self, self.settings.autosave, self.file != nil, self.isDirty else { return }
            _ = self.save(silent: true)
        }
        buildLayout()
        window.setFrameAutosaveName("MDStudioMainWindow")
        if !window.setFrameUsingName("MDStudioMainWindow") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("코드에서만 만든다") }

    // MARK: - 화면 배치

    private func buildLayout() {
        root = DropContainerView()
        root.onDrop = { [weak self] url in self?.openDropped(url) }
        window?.contentView = root

        topBar = TopBar { [weak self] action in self?.perform(action) }
        topBar.onViewChange = { [weak self] mode in self?.setView(mode) }
        formatBar = FormatBar { [weak self] cmd in self?.editor.run(cmd) }
        sidebar = SidebarView { [weak self] action in self?.perform(action) }
        sidebar.onOpen = { [weak self] entry in self?.openEntry(entry) }
        statusBar = StatusBar { [weak self] in self?.perform("logs") }

        editor.editorDelegate = self
        editor.pasteboard = env.pasteboard
        previewPane.onTab = { [weak self] tab in self?.setPreviewTab(tab) }
        previewPane.onTableMode = { [weak self] mode in self?.changeSetting { $0.tableMode = mode } }

        // 편집 영역 = 서식 도구 막대 + 편집기
        for v in [formatBar!, editorScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            editorPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            formatBar.topAnchor.constraint(equalTo: editorPane.topAnchor),
            formatBar.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            formatBar.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: formatBar.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
        ])

        // 파일 목록은 폭이 고정된 왼쪽 칸, 편집기와 미리보기는 경계를 끌어 폭을 바꿀 수 있는 나누기 칸
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.onDragEnd = { [weak self] in self?.dividerMoved() }
        split.onDoubleClick = { [weak self] in self?.resetDivider() }
        split.addArrangedSubview(editorPane)
        split.addArrangedSubview(previewPane)

        for v in [topBar!, sidebar!, split, statusBar!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            split.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 240)
        sidebarWidth.isActive = true
        toasts = ToastCenter(host: root)

        // 스크롤 맞추기: 두 스크롤 영역의 움직임을 지켜본다.
        for (clip, who) in [(editorScroll.contentView, "editor"), (previewPane.scroll.contentView, "preview")] {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.syncScroll(from: who)
            }
        }
    }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + SplitLayout.minPane
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - SplitLayout.minPane
    }

    /// 1px 경계선은 정확히 잡기 어려우므로 마우스가 잡히는 범위를 양옆으로 넓힌다.
    public func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -SplitLayout.grabMargin, dy: 0)
    }

    /// 창 크기가 바뀔 때: 두 칸이 다 보이면 기억한 비율대로, 아니면 맥 기본 방식대로 나눈다.
    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard isSplitShowingBoth else {
            splitView.adjustSubviews()
            return
        }
        let total = splitView.bounds.width
        let height = splitView.bounds.height
        let thickness = splitView.dividerThickness
        let pos = SplitLayout.position(ratio: settings.splitRatio, total: total, divider: thickness)
        editorPane.frame = NSRect(x: 0, y: 0, width: pos, height: height)
        previewPane.frame = NSRect(x: pos + thickness, y: 0, width: max(0, total - pos - thickness), height: height)
    }

    private var isSplitShowingBoth: Bool {
        settings.view == .split && !editorPane.isHidden && !previewPane.isHidden
    }

    /// 사용자가 경계를 끌어 놓았을 때: 비율을 기억하고 저장한다.
    private func dividerMoved() {
        guard isSplitShowingBoth else { return }
        let ratio = SplitLayout.ratio(editorWidth: editorPane.frame.width, total: split.bounds.width, divider: split.dividerThickness)
        guard abs(ratio - settings.splitRatio) > 0.0005 else { return }
        settings.splitRatio = ratio
        persistSettings()
        appLog.info("화면", "분할 경계 이동", ["ratio": String(format: "%.3f", ratio)])
    }

    /// 경계를 두 번 누르면 반반으로 되돌린다.
    func resetDivider() {
        settings.splitRatio = 0.5
        persistSettings()
        placeDivider()
        appLog.info("화면", "분할 경계를 가운데로 되돌림")
    }

    /// 기억한 비율대로 경계를 놓는다.
    private func placeDivider() {
        guard isSplitShowingBoth else { return }
        let pos = SplitLayout.position(ratio: settings.splitRatio, total: split.bounds.width, divider: split.dividerThickness)
        split.setPosition(pos, ofDividerAt: 0)
    }

    /// 보기 모드와 파일 목록 표시 여부에 맞춰 칸을 숨기고 나눈다.
    /// 숨긴 칸 옆의 경계 위치를 바꾸면 맥이 그 칸을 다시 보여 주므로, 둘 다 보일 때만 위치를 정한다.
    /// 경계는 반반이 아니라 사용자가 끌어 놓은 비율(settings.splitRatio)로 되살린다.
    private func applyLayout() {
        sidebar.isHidden = !settings.sidebar
        sidebarWidth.constant = settings.sidebar ? 240 : 0
        editorPane.isHidden = settings.view == .preview
        previewPane.isHidden = settings.view == .edit
        root.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        placeDivider()
    }

    // MARK: - 시작

    /// 창을 띄우고 지난 상태를 되살린다 (src/main.js init).
    public func start(pendingFiles: [URL] = []) {
        appLog.info("앱", "MD Studio 시작", [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        logListener = appLog.addListener { [weak self] entry in
            guard entry.level == .error else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorCount += 1
                self.statusBar.setErrorCount(self.errorCount)
            }
        }
        applySettings()
        showWindow(nil)
        window?.layoutIfNeeded()
        setView(settings.view)
        setPreviewTab(settings.previewTab)

        // 첫 문서: 저장 못 한 새 문서 임시본 → 처음 실행이면 예제 → 빈 문서
        let draft = env.drafts.load("untitled")
        if let draft, !draft.text.isEmpty {
            loadDoc(text: "", restoreDraft: .auto)
        } else if !settings.welcomed {
            settings.welcomed = true
            persistSettings()
            loadDoc(text: SampleDoc.text)
        } else {
            loadDoc(text: "")
        }

        // 지난 폴더: 아직 있으면 바로 열고, 없으면 잊는다.
        if let last = settings.lastFolder {
            let url = URL(fileURLWithPath: last, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                setFolder(url, openLast: draft?.text.isEmpty ?? true)
            } else {
                appLog.warn("폴더", "지난 폴더를 찾지 못했습니다", ["folder": url.lastPathComponent])
                sidebar.showReconnect(nil)
                settings.lastFolder = nil
                settings.lastFile = nil
                persistSettings()
            }
        }
        if let lastPending = pendingFiles.last {
            openFromFinder(lastPending)
        }
        updateStorageStatus()
        window?.makeFirstResponder(editor)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkExternalChange()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isDirty else { return }
            self.draftDebounce.flush()
        }
    }

    // MARK: - 공통 도구

    public var isDirty: Bool { editor.string != savedText }
    public var text: String { editor.string }

    private func toast(_ message: String, _ kind: ToastCenter.Kind = .info, seconds: Double = 2.6) {
        toasts.show(message, kind, seconds: seconds)
    }

    private var draftKey: String {
        if let file { return "file:\(file.url.path)" }
        return "untitled"
    }

    private var docBaseName: String {
        guard let file else { return "" }
        return (file.name as NSString).deletingPathExtension
    }

    private func suggestName() -> String {
        let title = MDConverter.extractTitle(editor.string)
        return FileStore.cleanFileName(title.isEmpty ? (docBaseName.isEmpty ? "새 문서" : docBaseName) : title)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func persistSettings() { env.settingsStore.save(settings) }

    // MARK: - 상태 표시

    func updateTitleAndStatus() {
        let dirty = isDirty
        let name = file?.name ?? "새 문서"
        topBar.fileName.stringValue = file?.fromFolder == true ? file!.path : name
        topBar.fileName.toolTip = file?.url.path ?? "현재 문서"
        topBar.dirtyDot.isHidden = !dirty
        window?.title = "\(name) — MD Studio"
        window?.representedURL = file?.url
        window?.isDocumentEdited = dirty
        if let saveError, dirty {
            statusBar.setSave("저장 실패: \(saveError)", state: .error)
        } else if dirty {
            statusBar.setSave(file != nil && settings.autosave ? "변경됨 (곧 자동 저장)" : "저장 안 됨 (임시 보관 중)", state: .unsaved)
        } else {
            saveError = nil
            statusBar.setSave(savedAt.map { "저장됨 \($0)" } ?? (file != nil ? "저장됨" : "빈 문서"), state: .normal)
        }
        // 글자 수는 입력할 때마다 세지 않고 잠깐 멈췄을 때 센다(긴 문서에서 입력이 느려지지 않도록).
        statsDebounce.schedule()
    }

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    func updateStats() {
        let s = MDConverter.stats(editor.string)
        func n(_ v: Int) -> String { Self.decimal.string(from: NSNumber(value: v)) ?? "\(v)" }
        statusBar.stats.stringValue = "\(n(s.chars))자 · 단어 \(n(s.words)) · \(n(s.lines))줄"
    }

    private func markSaved() {
        saveError = nil
        savedAt = Self.clock.string(from: Date())
        updateTitleAndStatus()
    }

    private func markSaveError(_ message: String) {
        saveError = message
        updateTitleAndStatus()
    }

    func updateStorageStatus() {
        if let folder {
            statusBar.storage.stringValue = "폴더: \(folder.path)"
        } else if file != nil {
            statusBar.storage.stringValue = "파일에 직접 저장"
        } else {
            statusBar.storage.stringValue = "폴더 미선택 · 임시 보관"
        }
    }

    // MARK: - 미리보기

    func renderPreview() {
        guard settings.view != .edit else { return }
        let md = editor.string
        let opts = settings.renderOptions
        let tab = settings.previewTab
        let zoom = CGFloat(settings.zoom)
        appLog.time("미리보기", "미리보기 렌더링", ["tab": tab.rawValue, "chars": "\(md.count)"]) {
            let attr: NSAttributedString
            switch tab {
            case .doc:
                attr = DocRenderer.render(md, style: PreviewStyle(baseSize: 15.5 * zoom, baseURL: file?.url.deletingLastPathComponent()), options: opts)
            case .slack:
                attr = SlackPreviewRenderer.renderMock(slackHTML: MDConverter.toSlackHtml(md, options: opts), palette: Theme.dynamicPalette, size: 15 * zoom)
            case .plain:
                attr = PlainPreviewRenderer.render(MDConverter.toPlainText(md, options: opts), palette: Theme.dynamicPalette, size: 13.5 * zoom)
            }
            previewPane.show(attr)
        }
    }

    func setPreviewTab(_ tab: PreviewTab) {
        settings.previewTab = tab
        persistSettings()
        previewPane.setTab(tab)
        renderPreview()
    }

    public func setView(_ mode: ViewMode) {
        settings.view = mode
        persistSettings()
        topBar.setView(mode)
        applyLayout()
        if mode != .edit { renderPreview() }
        if mode == .preview { window?.makeFirstResponder(previewPane.textView) } else { window?.makeFirstResponder(editor) }
    }

    /// 분할 보기에서 한쪽을 움직이면 다른 쪽도 같은 비율 위치로 옮긴다.
    private func syncScroll(from who: String) {
        guard settings.syncScroll, settings.view == .split else { return }
        if let s = scrollSource, s != who { return }
        scrollSource = who
        scrollRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in self?.scrollSource = nil }
        scrollRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: release)
        let (from, to) = who == "editor" ? (editorScroll, previewPane.scroll) : (previewPane.scroll, editorScroll)
        guard let fromDoc = from.documentView, let toDoc = to.documentView else { return }
        let fromMax = fromDoc.frame.height - from.contentView.bounds.height
        let ratio = fromMax > 0 ? from.contentView.bounds.origin.y / fromMax : 0
        let toMax = max(0, toDoc.frame.height - to.contentView.bounds.height)
        to.contentView.scroll(to: NSPoint(x: to.contentView.bounds.origin.x, y: ratio * toMax))
        to.reflectScrolledClipView(to.contentView)
    }

    // MARK: - 편집기 연결

    public func editorDidChange(_ editor: EditorTextView) {
        if saveError != nil && !isDirty { saveError = nil }
        updateTitleAndStatus()
        previewDebounce.schedule()
        draftDebounce.schedule()
        autosaveDebounce.schedule()
    }

    public func editorPasteConversionEnabled(_ editor: EditorTextView) -> Bool { settings.pasteConvert }

    public func editor(_ editor: EditorTextView, didDropFile url: URL) { openDropped(url) }

    private func storeDraft() {
        if isDirty { env.drafts.save(editor.string, for: draftKey) } else { env.drafts.clear(draftKey) }
    }

    // MARK: - 저장

    /// 저장한다 (src/main.js save).
    ///
    /// - Parameters:
    ///   - silent: 자동 저장이면 참 (알림을 띄우지 않는다)
    ///   - forceNew: 다른 이름으로 저장
    /// - Returns: 저장했으면 참
    @discardableResult
    public func save(silent: Bool = false, forceNew: Bool = false) -> Bool {
        if saving {
            pendingSave = true
            return true
        }
        saving = true
        defer {
            saving = false
            if pendingSave {
                pendingSave = false
                if isDirty { DispatchQueue.main.async { [weak self] in _ = self?.save(silent: true) } }
            }
        }
        let text = editor.string
        let oldKey = draftKey
        do {
            if let file, !forceNew {
                lastModified = try FileStore.writeSafely(text, to: file.url)
            } else if let folder, !forceNew {
                guard let name = env.prompter.askName(defaultName: suggestName(), hint: "열린 폴더(\(folder.lastPathComponent))에 저장합니다.", window: window) else {
                    appLog.info("저장", "저장을 취소했습니다")
                    return false
                }
                let url = try FileStore.createFile(in: folder, name: name, text: text)
                lastModified = try FileStore.modificationDate(url)
                file = OpenFile(url: url, path: relativePath(of: url) ?? url.lastPathComponent, fromFolder: true)
                settings.lastFile = file?.path
                persistSettings()
                refreshFolder()
            } else {
                let dir = file?.url.deletingLastPathComponent() ?? folder
                guard let url = env.prompter.pickSaveURL(suggestedName: suggestName(), ext: "md", directory: dir, window: window) else {
                    appLog.info("저장", "저장을 취소했습니다")
                    return false
                }
                lastModified = try FileStore.writeSafely(text, to: url)
                if let rel = relativePath(of: url) {
                    file = OpenFile(url: url, path: rel, fromFolder: true)
                    settings.lastFile = rel
                    persistSettings()
                    refreshFolder()
                } else {
                    file = OpenFile(url: url, path: url.lastPathComponent, fromFolder: false)
                }
            }
            savedText = text
            env.drafts.clear(oldKey)
            env.drafts.clear(draftKey)
            externalWarned = nil
            markSaved()
            updateStorageStatus()
            renderFileList()
            if !silent { toast("저장했습니다") }
            return true
        } catch {
            appLog.error("저장", "저장 실패", error, ["file": file?.name ?? "새 문서"])
            markSaveError(error.localizedDescription)
            toast("저장하지 못했습니다: \(error.localizedDescription). 작성 내용은 임시본으로 보관되어 있습니다.", .error)
            draftDebounce.flush()
            return false
        }
    }

    private func relativePath(of url: URL) -> String? {
        guard let folder else { return nil }
        let base = folder.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base + "/") else { return nil }
        return FileStore.normalized(String(p.dropFirst(base.count + 1)))
    }

    /// 지금 문서를 떠나도 되는지 확인한다(저장 안 된 내용 보호).
    public func confirmLeave() -> Bool {
        guard isDirty else { return true }
        autosaveDebounce.cancel()
        if file != nil && settings.autosave { return save(silent: true) }
        let name = file?.name ?? "새 문서"
        let choice = env.prompter.askChoice(
            title: "저장하지 않은 변경 사항",
            message: "\"\(name)\"에 저장하지 않은 내용이 있습니다. 저장할까요?",
            buttons: [ChoiceButton("save", "저장", isDefault: true), ChoiceButton("discard", "저장 안 함", destructive: true),
                      ChoiceButton("cancel", "취소")],
            window: window)
        switch choice {
        case "save": return save()
        case "discard":
            env.drafts.clear(draftKey)
            appLog.info("문서", "변경 사항을 저장하지 않고 닫았습니다", ["name": name])
            return true
        default: return false
        }
    }

    enum RestoreDraft { case ask, auto }

    /// 문서를 편집기에 연다. 저장하지 못한 임시본이 있으면 복구한다 (src/main.js loadDoc).
    func loadDoc(text: String, file: OpenFile? = nil, lastModified: Date? = nil, restoreDraft: RestoreDraft = .ask) {
        draftDebounce.cancel()
        autosaveDebounce.cancel()
        self.file = file
        savedText = text
        self.lastModified = lastModified
        externalWarned = nil
        savedAt = nil
        saveError = nil
        editor.setText(text, keepHistory: false)

        if let draft = env.drafts.load(draftKey), draft.text != text, draft.at > (lastModified ?? .distantPast) {
            if restoreDraft == .auto {
                editor.setText(draft.text, keepHistory: true)
                toast("지난번에 저장하지 않은 내용을 복구했습니다")
                appLog.info("임시본", "임시본 자동 복구", ["chars": "\(draft.text.count)"])
            } else {
                let f = DateFormatter()
                f.locale = Locale(identifier: "ko_KR")
                f.dateStyle = .medium
                f.timeStyle = .short
                let choice = env.prompter.askChoice(
                    title: "저장하지 못한 내용이 있습니다",
                    message: "이 문서에 \(f.string(from: draft.at))에 작성하고 저장하지 못한 내용이 남아 있습니다. 복구할까요?",
                    buttons: [ChoiceButton("restore", "복구", isDefault: true), ChoiceButton("discard", "버리기", destructive: true)],
                    window: window)
                if choice == "restore" {
                    editor.setText(draft.text, keepHistory: true)
                    appLog.info("임시본", "임시본을 복구했습니다")
                } else {
                    env.drafts.clear(draftKey)
                }
            }
        }
        if let file, file.fromFolder {
            settings.lastFile = file.path
            persistSettings()
        }
        updateTitleAndStatus()
        updateStorageStatus()
        renderFileList()
        renderPreview()
        appLog.info("문서", "문서 열기", ["name": file?.path ?? "새 문서", "chars": "\(text.count)"])
    }

    // MARK: - 파일 열기

    func newDoc() {
        guard confirmLeave() else { return }
        env.drafts.clear("untitled")
        loadDoc(text: "")
        window?.makeFirstResponder(editor)
    }

    func newInFolder() {
        guard let folder else { return newDoc() }
        guard confirmLeave() else { return }
        guard let name = env.prompter.askName(defaultName: "새 문서.md", hint: "\"\(folder.lastPathComponent)\" 폴더에 새 파일을 만듭니다.", window: window) else { return }
        do {
            let url = try FileStore.createFile(in: folder, name: name)
            refreshFolder()
            let r = try FileStore.read(url)
            loadDoc(text: r.text, file: OpenFile(url: url, path: relativePath(of: url) ?? url.lastPathComponent, fromFolder: true), lastModified: r.modified)
            window?.makeFirstResponder(editor)
        } catch {
            appLog.error("파일", "새 파일 만들기 실패", error)
            toast("새 파일을 만들지 못했습니다: \(error.localizedDescription)", .error)
        }
    }

    func openFile() {
        guard confirmLeave() else { return }
        guard let url = env.prompter.pickFileToOpen(window: window) else { return }
        openPath(url)
    }

    func openEntry(_ entry: FileEntry) {
        if let file, file.fromFolder, file.path == entry.path { return }
        guard confirmLeave() else {
            renderFileList()
            return
        }
        do {
            let r = try FileStore.read(entry.url)
            loadDoc(text: r.text, file: OpenFile(url: entry.url, path: entry.path, fromFolder: true), lastModified: r.modified)
        } catch {
            appLog.error("파일", "파일 열기 실패", error, ["file": entry.path])
            toast("파일을 열지 못했습니다: \(error.localizedDescription)", .error)
            refreshFolder()
        }
    }

    /// 실제 경로의 파일을 연다(열기 창, Finder, 끌어다 놓기).
    func openPath(_ url: URL) {
        do {
            let r = try FileStore.read(url)
            let rel = relativePath(of: url)
            loadDoc(text: r.text, file: OpenFile(url: url, path: rel ?? url.lastPathComponent, fromFolder: rel != nil), lastModified: r.modified)
        } catch {
            appLog.error("파일", "파일 열기 실패", error, ["file": url.lastPathComponent])
            toast("파일을 열지 못했습니다: \(error.localizedDescription)", .error)
        }
    }

    /// Finder의 "다음으로 열기"로 받은 파일
    public func openFromFinder(_ url: URL) {
        if file?.url.standardizedFileURL == url.standardizedFileURL { return }
        guard confirmLeave() else { return }
        openPath(url)
    }

    func openDropped(_ url: URL) {
        guard FileStore.isMarkdown(url) else {
            toast(".md 또는 .txt 파일만 열 수 있습니다", .warn)
            return
        }
        guard confirmLeave() else { return }
        openPath(url)
    }

    // MARK: - 폴더

    func setFolder(_ url: URL, openLast: Bool = false) {
        folder = url
        settings.lastFolder = url.path
        persistSettings()
        sidebar.showReconnect(nil)
        refreshFolder()
        updateStorageStatus()
        appLog.info("폴더", "폴더 열기", ["folder": url.lastPathComponent, "files": "\(files.count)"])
        if openLast, let last = settings.lastFile, !isDirty, let entry = files.first(where: { $0.path == last }) {
            openEntry(entry)
        }
    }

    func refreshFolder() {
        guard let folder else { return }
        do {
            files = try FileStore.listMarkdownFiles(in: folder).entries
        } catch {
            appLog.error("폴더", "폴더 목록을 읽지 못했습니다", error)
            toast("폴더를 읽지 못했습니다: \(error.localizedDescription)", .error)
            files = []
        }
        renderFileList()
    }

    func openFolder() {
        guard let url = env.prompter.pickFolder(window: window) else { return }
        if file?.fromFolder == true {
            guard confirmLeave() else { return }
            loadDoc(text: "")
        }
        setFolder(url)
        toast("\"\(url.lastPathComponent)\" 폴더를 열었습니다")
    }

    func closeFolder() {
        if file?.fromFolder == true && !confirmLeave() { return }
        let name = folder?.lastPathComponent ?? ""
        folder = nil
        files = []
        settings.lastFolder = nil
        settings.lastFile = nil
        persistSettings()
        if file?.fromFolder == true { loadDoc(text: "") }
        renderFileList()
        updateStorageStatus()
        appLog.info("폴더", "폴더 닫기", ["folder": name])
    }

    func renderFileList() {
        sidebar.update(folder: folder, files: files, activePath: file?.fromFolder == true ? file?.path : nil)
    }

    /// 다른 앱에서 파일이 바뀌었는지 창으로 돌아올 때 확인한다.
    public func checkExternalChange() {
        guard let file, !saving else { return }
        let modified: Date
        do {
            modified = try FileStore.modificationDate(file.url)
        } catch {
            appLog.warn("외부 변경", "파일을 확인하지 못했습니다(지워졌거나 옮겨졌을 수 있음)", ["file": file.name])
            return
        }
        if let lastModified, modified.timeIntervalSince(lastModified) <= 0.001 { return }
        if modified == externalWarned { return }
        if !isDirty {
            do {
                let r = try FileStore.read(file.url)
                savedText = r.text
                lastModified = r.modified
                editor.setText(r.text, keepHistory: true)
                updateTitleAndStatus()
                renderPreview()
                toast("다른 앱에서 바뀐 내용을 불러왔습니다")
                appLog.info("외부 변경", "외부 변경 감지 → 다시 불러옴", ["file": file.name])
            } catch {
                appLog.error("외부 변경", "바뀐 파일을 다시 읽지 못했습니다", error)
            }
        } else {
            externalWarned = modified
            toast("이 파일이 다른 곳에서도 바뀌었습니다. 저장하면 지금 화면의 내용으로 덮어씁니다.", .warn, seconds: 6)
            appLog.warn("외부 변경", "외부 변경 감지 (편집 중이라 불러오지 않음)", ["file": file.name])
        }
    }

    // MARK: - 복사

    private func copySource() -> (String, Bool) {
        let sel = editor.selectedRange()
        if sel.length > 0 { return ((editor.string as NSString).substring(with: sel), true) }
        return (editor.string, false)
    }

    /// 복사 4종 (src/main.js copy). 선택한 부분이 있으면 그 부분만 복사한다.
    public func copy(_ kind: CopyKind) {
        let (md, partial) = copySource()
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast("복사할 내용이 없습니다", .warn)
            return
        }
        let opts = settings.renderOptions
        let payload: ClipboardPayload
        switch kind {
        case .slack:
            payload = ClipboardPayload(html: "<meta charset=\"utf-8\">" + MDConverter.toSlackHtml(md, options: opts),
                                       text: MDConverter.toPlainText(md, options: opts))
        case .rich:
            payload = ClipboardPayload(html: "<meta charset=\"utf-8\">" + MDConverter.toRichCopyHtml(md, options: opts),
                                       text: MDConverter.toPlainText(md, options: opts),
                                       rtf: Clipboard.richRTF(md, options: opts))
        case .plain:
            payload = ClipboardPayload(text: MDConverter.toPlainText(md, options: opts))
        case .md:
            payload = ClipboardPayload(text: md)
        }
        let messages: [CopyKind: String] = [
            .slack: "Slack용으로 복사했습니다. Slack 입력창에 붙여넣으세요.",
            .rich: "서식을 포함해 복사했습니다. Google Docs, Word, 메일에 붙여넣으세요.",
            .plain: "텍스트로 복사했습니다.",
            .md: "마크다운 원문을 복사했습니다.",
        ]
        do {
            try Clipboard.write(payload, to: env.pasteboard)
            toast((messages[kind] ?? "") + (partial ? " (선택한 부분만)" : ""))
            appLog.info("복사", "복사: \(kind.rawValue)", ["partial": "\(partial)", "chars": "\(md.count)", "tableMode": opts.tableMode.rawValue])
        } catch {
            appLog.error("복사", "복사 실패: \(kind.rawValue)", error)
            toast("복사하지 못했습니다: \(error.localizedDescription)", .error)
        }
    }

    // MARK: - 내보내기

    func export(pdf: Bool) {
        let md = editor.string
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast("내보낼 내용이 없습니다", .warn)
            return
        }
        let title = MDConverter.extractTitle(md)
        let defaultTitle = title.isEmpty ? (docBaseName.isEmpty ? "보고서" : docBaseName) : title
        guard let choice = env.prompter.askExport(isPDF: pdf, defaultTitle: defaultTitle, window: window) else { return }
        let options = ReportOptions(title: choice.title, includeToc: choice.includeToc, includeDate: choice.includeDate, render: settings.renderOptions)
        let dir = file?.url.deletingLastPathComponent() ?? folder
        do {
            if choice.action == .preview {
                let html = MDConverter.buildReportHtml(md, options: options)
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("MD Studio 미리보기", isDirectory: true)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let url = tmpDir.appendingPathComponent(FileStore.cleanFileName(choice.title, ext: "html"))
                try Data(html.utf8).write(to: url, options: .atomic)
                env.openInBrowser(url)
                appLog.info("내보내기", "보고서 미리보기 열기")
            } else if pdf {
                guard let url = env.prompter.pickSaveURL(suggestedName: FileStore.cleanFileName(choice.title, ext: "pdf"), ext: "pdf", directory: dir, window: window) else { return }
                try ReportExporter.writePDF(md, options: options, to: url, baseURL: file?.url.deletingLastPathComponent())
                toast("\"\(url.lastPathComponent)\"으로 저장했습니다")
            } else {
                guard let url = env.prompter.pickSaveURL(suggestedName: FileStore.cleanFileName(choice.title, ext: "html"), ext: "html", directory: dir, window: window) else { return }
                let html = MDConverter.buildReportHtml(md, options: options)
                try Data(html.utf8).write(to: url, options: .atomic)
                toast("\"\(url.lastPathComponent)\"으로 저장했습니다")
                appLog.info("내보내기", "HTML 보고서 저장", ["file": url.lastPathComponent, "bytes": "\(html.utf8.count)"])
            }
        } catch {
            appLog.error("내보내기", "내보내기 실패", error)
            toast("내보내지 못했습니다: \(error.localizedDescription)", .error)
        }
    }

    /// 지금 문서는 그대로 두고 사본만 저장한다.
    func saveCopy() {
        let dir = file?.url.deletingLastPathComponent() ?? folder
        guard let url = env.prompter.pickSaveURL(suggestedName: suggestName(), ext: "md", directory: dir, window: window) else { return }
        do {
            try FileStore.writeSafely(editor.string, to: url)
            toast("사본을 \"\(url.lastPathComponent)\"으로 저장했습니다")
            if relativePath(of: url) != nil { refreshFolder() }
        } catch {
            appLog.error("저장", "사본 저장 실패", error)
            toast("저장하지 못했습니다: \(error.localizedDescription)", .error)
        }
    }

    // MARK: - 설정

    /// 설정을 화면에 반영한다.
    func applySettings() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        editor.useMonoFont = settings.editorFont == .mono
        editor.fontSize = CGFloat(settings.editorFontSize) * CGFloat(settings.zoom)
        editor.lineWrap = settings.lineWrap
        previewPane.setTableMode(settings.tableMode)
        applyLayout()
    }

    /// 설정 하나를 바꾸고 저장·반영한다.
    public func changeSetting(_ change: (inout AppSettings) -> Void) {
        let before = settings
        change(&settings)
        guard settings != before else { return }
        persistSettings()
        applySettings()
        renderPreview()
        updateTitleAndStatus()
        appLog.info("설정", "설정 변경", diff(before, settings))
    }

    private func diff(_ a: AppSettings, _ b: AppSettings) -> [String: String] {
        let ma = Mirror(reflecting: a).children, mb = Mirror(reflecting: b).children
        var out: [String: String] = [:]
        for (x, y) in zip(ma, mb) where "\(x.value)" != "\(y.value)" {
            out[x.label ?? "?"] = "\(y.value)"
        }
        return out
    }

    func zoom(_ delta: Double?) {
        changeSetting { s in
            if let delta {
                let v = ((s.zoom + delta) * 10).rounded() / 10
                s.zoom = min(2.0, max(0.6, v))
            } else {
                s.zoom = 1.0
            }
        }
    }

    // MARK: - 동작 이름표 (버튼·메뉴가 함께 쓴다)

    public func perform(_ action: String) {
        appLog.debug("동작", action)
        switch action {
        case "new": newDoc()
        case "open": openFile()
        case "save": save()
        case "saveAs": save(forceNew: true)
        case "openFolder": openFolder()
        case "reconnectFolder":
            if let last = settings.lastFolder { setFolder(URL(fileURLWithPath: last), openLast: true) }
        case "closeFolder": closeFolder()
        case "refreshFolder": refreshFolder()
        case "newInFolder": newInFolder()
        case "copySlack": copy(.slack)
        case "copyRich": copy(.rich)
        case "copyPlain": copy(.plain)
        case "copyMd": copy(.md)
        case "exportHtml": export(pdf: false)
        case "exportPdf": export(pdf: true)
        case "downloadMd": saveCopy()
        case "viewEdit": setView(.edit)
        case "viewSplit": setView(.split)
        case "viewPreview": setView(.preview)
        case "cycleView": setView(settings.view.next)
        case "toggleSidebar": changeSetting { $0.sidebar.toggle() }
        case "settings": settingsWindow.show()
        case "help": helpWindow.show()
        case "logs": logWindow.show()
        case "loadSample":
            guard confirmLeave() else { return }
            loadDoc(text: SampleDoc.text)
        case "zoomIn": zoom(0.1)
        case "zoomOut": zoom(-0.1)
        case "zoomReset": zoom(nil)
        default:
            appLog.warn("동작", "알 수 없는 동작: \(action)")
        }
    }

    // MARK: - 자가 점검용 읽기 창구

    var isEditorPaneVisible: Bool { !editorPane.isHidden }
    var splitView: NSSplitView { split }
    var formatBarView: FormatBar { formatBar }
    var editorPaneWidth: CGFloat { editorPane.frame.width }
    var isPreviewPaneVisible: Bool { !previewPane.isHidden }
    var isSidebarVisible: Bool { !sidebar.isHidden }
    var statusSaveText: String { statusBar.save.stringValue }
    var statusStatsText: String { statusBar.stats.stringValue }
    var topFileName: String { topBar.fileName.stringValue }
    var rootView: NSView { root }

    // MARK: - 창 닫기

    /// 창을 닫거나 앱을 끝내도 되는지 확인한다.
    public func canClose() -> Bool {
        guard isDirty else { return true }
        draftDebounce.flush()
        if file != nil && settings.autosave { return save(silent: true) }
        let choice = env.prompter.askChoice(
            title: "저장하지 않은 변경 사항이 있습니다.",
            message: "그래도 닫으면 내용은 임시본으로 보관되어, 다음에 열 때 복구할 수 있습니다.",
            buttons: [ChoiceButton("save", "저장", isDefault: true), ChoiceButton("close", "저장하지 않고 닫기", destructive: true),
                      ChoiceButton("cancel", "취소")],
            window: window)
        switch choice {
        case "save": return save()
        case "close":
            appLog.info("앱", "저장하지 않은 상태로 닫기 선택")
            return true
        default: return false
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }

    public func windowDidBecomeKey(_ notification: Notification) { checkExternalChange() }

    public func windowWillClose(_ notification: Notification) {
        if let id = logListener { appLog.removeListener(id) }
        appLog.flush()
    }
}
