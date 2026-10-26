// 앱의 시작과 끝, 메뉴 막대 (electron/main.cjs의 buildMenu와 같은 구성 + 서식 메뉴)
// - 앱: 정보, 설정(⌘,), 가리기, 종료
// - 파일: 새 문서, 열기, 폴더 열기(⌘⇧O), 저장, 다른 이름으로 저장, HTML 보고서, PDF(⌘P), 마크다운 사본, 창 닫기
// - 편집: 기본 편집 + 찾기 + Slack용으로 복사(⌘⇧C), 서식 포함 복사(⌘⌥⇧C), 텍스트로 복사(⌘⇧T), 마크다운 원문 복사
// - 서식: 굵게, 기울임, 취소선, 코드, 링크, 제목, 목록, 할 일, 인용, 코드 블록, 표, 구분선
// - 보기: 편집만, 편집+미리보기, 미리보기만, 보기 전환(⌘\), 파일 목록, 확대·축소, 전체 화면
// - 도움말: 사용법과 단축키(⌘/), 로그 보기, 로그 폴더 열기
// Finder의 "다음으로 열기"와 Dock 아이콘에 끌어다 놓은 파일도 여기서 받는다.
// 의존성: AppKit
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public private(set) var main: MainWindowController?
    private var pendingFiles: [URL] = []
    private let makeEnvironment: () -> AppEnvironment
    /// 창을 띄운 뒤 할 일 (자가 점검에서 쓴다)
    public var afterStart: ((MainWindowController) -> Void)?

    public init(environment: @escaping () -> AppEnvironment = AppEnvironment.live) {
        makeEnvironment = environment
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(env: makeEnvironment())
        main = controller
        controller.start(pendingFiles: pendingFiles)
        pendingFiles = []
        NSApp.activate(ignoringOtherApps: true)
        afterStart?(controller)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        appLog.info("앱", "Finder에서 파일 열기 요청", ["count": "\(files.count)"])
        guard let main, let last = files.last else {
            pendingFiles.append(contentsOf: files)
            return
        }
        main.openFromFinder(last)
        main.window?.makeKeyAndOrderFront(nil)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let main else { return .terminateNow }
        return main.canClose() ? .terminateNow : .terminateCancel
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    public func applicationWillTerminate(_ notification: Notification) {
        appLog.info("앱", "MD Studio 종료")
        appLog.flush()
    }

    // MARK: - 메뉴

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        if action.hasPrefix("fmt:"), let cmd = FormatCommand(rawValue: String(action.dropFirst(4))) {
            main?.editor.run(cmd)
        } else if action == "openLogFolder" {
            try? FileManager.default.createDirectory(at: appLog.directoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(appLog.directoryURL)
        } else {
            main?.perform(action)
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.representedObject as? String else { return true }
        // 서식 명령은 편집기가 보일 때만
        if action.hasPrefix("fmt:") { return main?.settings.view != .preview }
        if let view = main?.settings.view {
            switch action {
            case "viewEdit": menuItem.state = view == .edit ? .on : .off
            case "viewSplit": menuItem.state = view == .split ? .on : .off
            case "viewPreview": menuItem.state = view == .preview ? .on : .off
            default: break
            }
        }
        return true
    }

    private func item(_ title: String, _ action: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
        i.target = self
        i.representedObject = action
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private func standard(_ title: String, _ selector: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = standard(title, #selector(NSTextView.performTextFinderAction(_:)), key, mods)
        i.tag = action.rawValue
        return i
    }

    func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            bar.addItem(holder)
            return m
        }
        let sep = { NSMenuItem.separator() }

        let about = standard("MD Studio 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        let hideOthers = standard("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = menu("MD Studio", [
            about, sep(),
            item("설정…", "settings", ","), sep(),
            standard("MD Studio 가리기", #selector(NSApplication.hide(_:)), "h"), hideOthers,
            standard("모두 보기", #selector(NSApplication.unhideAllApplications(_:))), sep(),
            standard("MD Studio 종료", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = menu("파일", [
            item("새 문서", "new", "n"),
            item("열기…", "open", "o"),
            item("폴더 열기…", "openFolder", "O", [.command, .shift]), sep(),
            item("저장", "save", "s"),
            item("다른 이름으로 저장…", "saveAs", "S", [.command, .shift]), sep(),
            item("HTML 보고서로 내보내기…", "exportHtml"),
            item("PDF로 내보내기…", "exportPdf", "p"),
            item("마크다운 사본 저장…", "downloadMd"), sep(),
            standard("창 닫기", #selector(NSWindow.performClose(_:)), "w"),
        ])

        let findMenu = NSMenu(title: "찾기")
        for i in [finder("찾기…", .showFindInterface, "f"), finder("찾아서 바꾸기…", .showReplaceInterface, "f", [.command, .option]),
                  finder("다음 찾기", .nextMatch, "g"), finder("이전 찾기", .previousMatch, "G", [.command, .shift])] {
            findMenu.addItem(i)
        }
        let findHolder = NSMenuItem(title: "찾기", action: nil, keyEquivalent: "")
        findHolder.submenu = findMenu
        _ = menu("편집", [
            standard("실행 취소", Selector(("undo:")), "z"),
            standard("실행 복귀", Selector(("redo:")), "Z", [.command, .shift]), sep(),
            standard("오려두기", #selector(NSText.cut(_:)), "x"),
            standard("복사하기", #selector(NSText.copy(_:)), "c"),
            standard("붙여넣기", #selector(NSText.paste(_:)), "v"),
            standard("서식 없이 붙여넣기", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            standard("전체 선택", #selector(NSText.selectAll(_:)), "a"), sep(),
            findHolder, sep(),
            item("Slack용으로 복사", "copySlack", "C", [.command, .shift]),
            item("서식 포함 복사 (Docs·메일)", "copyRich", "C", [.command, .option, .shift]),
            item("텍스트로 복사", "copyPlain", "T", [.command, .shift]),
            item("마크다운 원문 복사", "copyMd"),
        ])

        _ = menu("서식", [
            item("굵게", "fmt:bold", "b"),
            item("기울임", "fmt:italic", "i"),
            item("취소선", "fmt:strike", "X", [.command, .shift]),
            item("인라인 코드", "fmt:code", "e"),
            item("링크", "fmt:link", "k"), sep(),
            item("제목 1", "fmt:h1", "1", [.command, .option]),
            item("제목 2", "fmt:h2", "2", [.command, .option]),
            item("제목 3", "fmt:h3", "3", [.command, .option]), sep(),
            item("글머리 목록", "fmt:ul", "8", [.command, .shift]),
            item("번호 목록", "fmt:ol", "7", [.command, .shift]),
            item("할 일 목록", "fmt:task"),
            item("인용", "fmt:quote"), sep(),
            item("코드 블록", "fmt:codeBlock"),
            item("표", "fmt:table"),
            item("구분선", "fmt:hr"),
        ])

        _ = menu("보기", [
            item("편집만", "viewEdit"),
            item("편집 + 미리보기", "viewSplit"),
            item("미리보기만", "viewPreview"),
            item("보기 전환", "cycleView", "\\"),
            item("파일 목록 보이기/숨기기", "toggleSidebar", "L", [.command, .shift]), sep(),
            item("실제 크기", "zoomReset", "0"),
            item("확대", "zoomIn", "="),
            item("축소", "zoomOut", "-"), sep(),
            standard("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        let windowMenu = menu("윈도우", [
            standard("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("확대/축소", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = windowMenu

        let help = menu("도움말", [
            item("사용법과 단축키", "help", "/"),
            item("로그 보기", "logs"),
            item("로그 폴더 열기", "openLogFolder"),
        ])
        NSApp.helpMenu = help
        return bar
    }
}
