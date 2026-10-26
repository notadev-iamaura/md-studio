// 자가 점검: 실제 앱 창을 띄워 사람이 하는 흐름을 끝까지 실행하고 결과와 화면 사진을 남긴다.
// (Electron 버전의 test/app-e2e.mjs, test/e2e.mjs에 해당)
// - 사용자의 설정·임시본·클립보드를 건드리지 않도록 모두 임시 폴더와 전용 저장소를 쓴다.
// - 사용자에게 묻는 창은 ScriptedPrompter가 정해진 답으로 대신한다.
// - 결과: <출력 폴더>/selftest.json, 화면 사진 *.png, 만든 PDF·HTML
// 실행: MDSTUDIO_SELFTEST=<출력 폴더> "MD Studio.app/Contents/MacOS/MDStudio"
// 의존성: AppKit, MDCore
import AppKit
import MDCore

/// 정해진 답을 돌려주는 Prompter. 예상하지 못한 질문이 오면 기록한다.
final class ScriptedPrompter: Prompter {
    var choices: [String] = []
    /// nil이면 기본 이름을 그대로 쓴다.
    var names: [String?] = []
    var exports: [ExportChoice] = []
    var folders: [URL] = []
    var openFiles: [URL] = []
    var saveURLs: [URL] = []
    private(set) var unexpected: [String] = []
    var currentStep = ""
    private(set) var asked: [String] = []

    func askChoice(title: String, message: String, buttons: [ChoiceButton], window: NSWindow?) -> String {
        asked.append(title)
        guard !choices.isEmpty else { unexpected.append("[\(currentStep)] 확인 창: \(title)"); return "cancel" }
        return choices.removeFirst()
    }

    func askName(defaultName: String, hint: String, window: NSWindow?) -> String? {
        asked.append("이름: \(defaultName)")
        guard !names.isEmpty else { unexpected.append("이름 창: \(defaultName)"); return nil }
        return FileStore.cleanFileName(names.removeFirst() ?? defaultName)
    }

    func askExport(isPDF: Bool, defaultTitle: String, window: NSWindow?) -> ExportChoice? {
        asked.append("내보내기: \(defaultTitle)")
        guard !exports.isEmpty else { unexpected.append("내보내기 창"); return nil }
        return exports.removeFirst()
    }

    func pickFolder(window: NSWindow?) -> URL? {
        guard !folders.isEmpty else { unexpected.append("폴더 선택 창"); return nil }
        return folders.removeFirst()
    }

    func pickFileToOpen(window: NSWindow?) -> URL? {
        guard !openFiles.isEmpty else { unexpected.append("열기 창"); return nil }
        return openFiles.removeFirst()
    }

    func pickSaveURL(suggestedName: String, ext: String, directory: URL?, window: NSWindow?) -> URL? {
        asked.append("저장 위치: \(suggestedName)")
        guard !saveURLs.isEmpty else { unexpected.append("저장 위치 창: \(suggestedName)"); return nil }
        return saveURLs.removeFirst()
    }
}

public enum SelfTest {
    struct StepResult: Codable {
        var name: String
        var ok: Bool
        var detail: String
        var ms: Int
    }

    struct Report: Codable {
        var passed: Int
        var failed: Int
        var steps: [StepResult]
        var metrics: [String: String]
        var screenshots: [String]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // 점검에 쓰는 공유 상태
    static var out: URL!
    static var work: URL!
    static var prompter = ScriptedPrompter()
    static var pasteboard = NSPasteboard(name: NSPasteboard.Name("local.mdstudio.selftest.\(UUID().uuidString)"))
    static var openedInBrowser: [URL] = []
    static var defaultsSuite = "local.mdstudio.selftest.\(UUID().uuidString)"
    static var results: [StepResult] = []
    static var metrics: [String: String] = [:]
    static var shots: [String] = []

    static func environment() -> AppEnvironment {
        AppEnvironment(
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: defaultsSuite)!),
            drafts: DraftStore(directory: work.appendingPathComponent("drafts", isDirectory: true)),
            prompter: prompter,
            pasteboard: pasteboard,
            openInBrowser: { openedInBrowser.append($0) })
    }

    /// 자가 점검용 AppDelegate를 만든다.
    public static func makeDelegate(outputDirectory: URL) -> AppDelegate {
        out = outputDirectory
        work = FileManager.default.temporaryDirectory.appendingPathComponent("mdstudio-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let delegate = AppDelegate(environment: { environment() })
        delegate.afterStart = { main in
            // GCD 메인 대기열 블록 안에서 돌리면 그 안에서 예약한 작업이 실행되지 않으므로 타이머로 시작한다.
            let t = Timer(timeInterval: 0.5, repeats: false) { _ in run(main, delegate: delegate) }
            RunLoop.main.add(t, forMode: .common)
        }
        return delegate
    }

    // MARK: - 도구

    /// 기다리는 동안에도 타이머(자동 저장 등)가 돌도록 실행 루프를 돌린다.
    static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            // 창 이벤트(앞으로 나오기, 입력받는 창 바뀜 등)도 실제 앱처럼 처리한다.
            while let e = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
            RunLoop.main.run(mode: .default, before: min(until, Date().addingTimeInterval(0.02)))
        }
    }

    static func check(_ cond: Bool, _ message: @autoclosure () -> String) throws {
        if !cond { throw Failure(description: message()) }
    }

    static func step(_ name: String, _ body: () throws -> String?) {
        let start = Date()
        prompter.currentStep = name
        do {
            let detail = try autoreleasepool { try body() ?? "" }
            results.append(StepResult(name: name, ok: true, detail: detail, ms: Int(Date().timeIntervalSince(start) * 1000)))
            print("  ok  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } catch {
            results.append(StepResult(name: name, ok: false, detail: "\(error)", ms: Int(Date().timeIntervalSince(start) * 1000)))
            print("  FAIL \(name)\n       \(error)")
        }
    }

    /// 창을 PNG로 저장한다(화면 기록 권한 없이 앱이 스스로 그린다).
    static func screenshot(_ main: MainWindowController, _ name: String) {
        guard let view = main.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        main.window?.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = out.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            shots.append(url.lastPathComponent)
        } catch {
            appLog.error("자가 점검", "화면 사진 저장 실패", error)
        }
    }

    static func setEditor(_ main: MainWindowController, _ text: String) {
        main.editor.setText(text, keepHistory: true)
        main.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// 메모리 사용량(활동 상태 보기의 "메모리"와 같은 phys_footprint)
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    // MARK: - 시나리오

    static func run(_ main: MainWindowController, delegate: AppDelegate) {
        print("MD Studio 자가 점검")
        main.window?.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 860), display: true)
        pump(0.3)
        metrics["footprintAtStartMB"] = String(format: "%.1f", footprintMB())

        let folder = work.appendingPathComponent("내 문서", isDirectory: true)
        let exportDir = work.appendingPathComponent("내보내기", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("하위"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".숨김"), withIntermediateDirectories: true)
        try? "# 기존 메모\n\n디스크에 있던 파일".write(to: folder.appendingPathComponent("기존 메모.md"), atomically: true, encoding: .utf8)
        try? "# 깊은 파일".write(to: folder.appendingPathComponent("하위/깊은 파일.md"), atomically: true, encoding: .utf8)
        try? "숨김".write(to: folder.appendingPathComponent(".숨김/안 보여야 함.md"), atomically: true, encoding: .utf8)
        try? "그림".write(to: folder.appendingPathComponent("그림.png"), atomically: true, encoding: .utf8)
        let outside = work.appendingPathComponent("바깥 파일.md")
        try? "# 폴더 밖 파일\n\nFinder에서 연 파일".write(to: outside, atomically: true, encoding: .utf8)

        step("처음 실행: 창이 뜨고 예제 문서와 미리보기가 보인다") {
            try check(main.window?.isVisible == true, "창이 보이지 않습니다")
            try check(main.text == SampleDoc.text, "예제 문서가 열리지 않았습니다")
            try check(main.isEditorPaneVisible && main.isPreviewPaneVisible, "분할 보기가 아닙니다")
            let preview = main.previewPane.textView.string
            try check(preview.contains("MD Studio 사용 안내") && preview.contains("Slack 복사"), "미리보기 내용이 이상합니다: \(preview.prefix(80))")
            try check(main.statusStatsText.contains("자 · 단어"), "상태 표시줄 글자 수가 없습니다")
            let menu = NSApp.mainMenu?.items.map(\.title) ?? []
            try check(menu == ["MD Studio", "파일", "편집", "서식", "보기", "윈도우", "도움말"], "메뉴 막대 구성이 다릅니다: \(menu)")
            let edit = NSApp.mainMenu?.item(withTitle: "편집")?.submenu?.items.map(\.title) ?? []
            try check(edit.contains("Slack용으로 복사") && edit.contains("텍스트로 복사"), "편집 메뉴에 복사 항목이 없습니다")
            screenshot(main, "01-첫실행-분할")
            return "메뉴 \(menu.count)개"
        }

        step("미리보기 3종: 문서 / Slack / 텍스트") {
            main.setPreviewTab(.slack)
            pump(0.1)
            let slack = main.previewPane.textView.string
            try check(slack.contains("오늘") && slack.contains("Slack 입력창에 붙여넣었을 때"), "Slack 미리보기 모양이 이상합니다")
            try check(!slack.contains("| 버튼 |"), "Slack 미리보기에 표 원문이 남았습니다")
            screenshot(main, "02-Slack-미리보기")
            main.setPreviewTab(.plain)
            pump(0.1)
            let plain = main.previewPane.textView.string
            try check(plain.contains("■ MD Studio 사용 안내"), "텍스트 미리보기 결과가 이상합니다")
            try check(plain.hasPrefix(MDConverter.toPlainText(SampleDoc.text).trimmingCharacters(in: .newlines)), "텍스트 미리보기가 텍스트 복사 결과와 다릅니다")
            screenshot(main, "03-텍스트-미리보기")
            main.setPreviewTab(.doc)
            return nil
        }

        step("표 변환 방식 전환이 미리보기에 바로 반영된다") {
            main.setPreviewTab(.plain)
            main.changeSetting { $0.tableMode = "grid" }
            pump(0.1)
            try check(main.previewPane.textView.string.contains("─┼─"), "고정폭 표로 바뀌지 않았습니다")
            main.changeSetting { $0.tableMode = "title" }
            main.setPreviewTab(.doc)
            return nil
        }

        step("서식 명령: 굵게 / 제목 / 목록 / 표 넣기 / 실행 취소") {
            // 실제 앱에서는 키 입력·클릭 하나마다 실행 취소 묶음이 나뉜다. 점검에서는 직접 나눈다.
            let um = main.editor.undoManager!
            um.groupsByEvent = false
            defer { um.groupsByEvent = true }
            func action(_ body: () -> Void) { um.beginUndoGrouping(); body(); um.endUndoGrouping() }
            action { setEditor(main, "abc") }
            main.editor.setSelectedRange(NSRange(location: 0, length: 3))
            action { main.editor.run(.bold) }
            try check(main.text == "**abc**", "굵게: \(main.text)")
            action { main.editor.run(.bold) }
            try check(main.text == "abc", "굵게 해제: \(main.text)")
            action { main.editor.run(.h2) }
            try check(main.text == "## abc", "제목 2: \(main.text)")
            um.undo()
            try check(main.text == "abc", "실행 취소: \(main.text)")
            action { setEditor(main, "하나\n둘") }
            main.editor.setSelectedRange(NSRange(location: 0, length: 5))
            action { main.editor.run(.ol) }
            try check(main.text == "1. 하나\n2. 둘", "번호 목록: \(main.text)")
            action { setEditor(main, "") }
            action { main.editor.run(.table) }
            try check(main.text.hasPrefix("| 항목 | 내용 | 비고 |\n| --- | --- | --- |"), "표 넣기: \(main.text)")
            return nil
        }

        step("단축키: 실제 키 입력으로 메뉴 명령 실행 (⌘B, ⌘⌥1, ⌘⇧8, ⌘\\, ⌘⇧C, ⌘F)") {
            // 실제 키보드(US·한국어 자판)가 만드는 것과 같은 키 이벤트: Shift를 누르면 글자가 바뀐다(c→C, 8→*).
            func press(_ key: String, _ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                               windowNumber: main.window?.windowNumber ?? 0, context: nil, characters: key,
                                               charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode) else { return false }
                // 앱이 키를 처리하는 순서와 같게: 창의 응답 사슬(편집기) → 메뉴
                if main.window?.performKeyEquivalent(with: e) == true { return true }
                return NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
            }
            // 메뉴의 "지금 입력받는 곳으로 보내기" 명령(찾기 등)은 창이 앞에 있을 때만 켜진다.
            NSApp.activate(ignoringOtherApps: true)
            main.window?.makeKeyAndOrderFront(nil)
            pump(0.5)
            metrics["keyWindowDuringShortcuts"] = "\(main.window?.isKeyWindow == true)"
            main.window?.makeFirstResponder(main.editor)
            setEditor(main, "글")
            main.editor.setSelectedRange(NSRange(location: 0, length: 1))
            try check(press("b", [.command], keyCode: 11), "⌘B가 메뉴에 연결되지 않았습니다")
            try check(main.text == "**글**", "⌘B 결과: \(main.text)")
            try check(press("1", [.command, .option], keyCode: 18), "⌘⌥1이 메뉴에 연결되지 않았습니다")
            try check(main.text == "# **글**", "⌘⌥1 결과: \(main.text)")
            try check(press("*", [.command, .shift], keyCode: 28), "⌘⇧8이 메뉴에 연결되지 않았습니다")
            try check(main.text == "- **글**", "⌘⇧8 결과: \(main.text)")
            try check(press("\\", [.command], keyCode: 42) && main.settings.view == .preview, "⌘\\ 보기 전환 이상")
            main.setView(.split)
            main.window?.makeFirstResponder(main.editor)
            main.editor.setSelectedRange(NSRange(location: 0, length: 0))
            pasteboard.clearContents()
            try check(press("C", [.command, .shift], keyCode: 8), "⌘⇧C가 메뉴에 연결되지 않았습니다")
            let copied = pasteboard.string(forType: .html) ?? "(없음)"
            try check(copied.contains("<ul><li><b>글</b></li></ul>"), "⌘⇧C로 Slack 복사가 되지 않았습니다: \(copied)")
            // ⌘F: 메뉴 항목이 단축키와 찾기 명령에 제대로 연결돼 있는지 확인한다.
            let findItem = NSApp.mainMenu?.item(withTitle: "편집")?.submenu?.item(withTitle: "찾기")?.submenu?.item(withTitle: "찾기…")
            try check(findItem?.keyEquivalent == "f" && findItem?.keyEquivalentModifierMask == [.command]
                      && findItem?.action == #selector(NSTextView.performTextFinderAction(_:))
                      && findItem?.tag == NSTextFinder.Action.showFindInterface.rawValue, "⌘F 메뉴 연결이 이상합니다")
            var findNote = ""
            if main.window?.isKeyWindow == true {
                try check(press("f", [.command], keyCode: 3), "⌘F가 메뉴에 연결되지 않았습니다")
            } else {
                // 다른 앱을 쓰는 중이면 맥이 이 창을 앞으로 못 나오게 해서 실제 키 경로는 확인할 수 없다.
                findNote = "창이 앞에 있지 않아 ⌘F는 메뉴 연결과 명령 실행만 확인"
                main.editor.performTextFinderAction(findItem)
            }
            pump(1.0)
            let fieldEditor = main.window?.firstResponder as? NSTextView
            let searchField = fieldEditor?.delegate as? NSView
            let findBar = main.editor.enclosingScrollView?.findBarView
            let inEditorFindBar = searchField != nil && findBar != nil && searchField!.isDescendant(of: findBar!)
            try check(inEditorFindBar || main.editor.enclosingScrollView?.isFindBarVisible == true,
                      "찾기 막대가 열리지 않았습니다 (첫 응답자: \(String(describing: main.window?.firstResponder.map { type(of: $0) })))")
            screenshot(main, "07-찾기")
            main.editor.enclosingScrollView?.isFindBarVisible = false
            return findNote.isEmpty ? nil : findNote
        }

        step("설정·도움말·로그 창이 열린다") {
            main.perform("settings")
            main.perform("help")
            main.perform("logs")
            pump(0.2)
            for (w, name) in [(main.settingsWindow.window, "08-설정"), (main.helpWindow.window, "09-도움말"), (main.logWindow.window, "10-로그")] {
                try check(w?.isVisible == true, "\(name) 창이 보이지 않습니다")
                if let view = w?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: out.appendingPathComponent("\(name).png"))
                        shots.append("\(name).png")
                    }
                }
                w?.close()
            }
            return nil
        }

        step("입력: 한글 글자 넣기, 목록에서 Enter로 기호 이어 쓰기, Tab 들여쓰기") {
            setEditor(main, "- 첫째")
            main.editor.insertText("와 한글", replacementRange: main.editor.selectedRange())
            main.editor.insertNewline(nil)
            main.editor.insertText("둘째", replacementRange: main.editor.selectedRange())
            try check(main.text == "- 첫째와 한글\n- 둘째", "목록 이어 쓰기: \(main.text)")
            main.editor.insertTab(nil)
            try check(main.text == "- 첫째와 한글\n  - 둘째", "Tab 들여쓰기: \(main.text)")
            main.editor.insertNewline(nil)
            main.editor.insertNewline(nil)
            try check(main.text == "- 첫째와 한글\n  - 둘째\n", "빈 항목에서 Enter로 목록 끝내기: \(main.text.debugDescription)")
            return nil
        }

        step("Slack 복사: 클립보드 한 항목에 HTML(표→목록)과 텍스트가 함께 들어간다") {
            setEditor(main, "## 제목\n- a\n\n| x | y | z |\n|---|---|---|\n| 1 | 2 | 3 |")
            main.copy(.slack)
            let html = pasteboard.string(forType: .html) ?? ""
            let text = pasteboard.string(forType: .string) ?? ""
            try check(pasteboard.pasteboardItems?.count == 1, "클립보드 항목이 하나가 아닙니다")
            try check(html.contains("<p><b>제목</b></p><ul><li>a</li></ul><p><br></p><ul><li><b>1</b><ul><li>y: 2</li>"), "Slack HTML: \(html)")
            try check(text == MDConverter.toPlainText(main.text), "텍스트 쪽이 텍스트 복사 결과와 다릅니다")
            try check(main.toasts.history.last?.hasPrefix("Slack용으로 복사했습니다") == true, "알림이 없습니다")
            return nil
        }

        step("서식 복사: HTML(인라인 스타일)·RTF·텍스트, 선택한 부분만 복사") {
            setEditor(main, "# 제목\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] 끝")
            main.copy(.rich)
            let html = pasteboard.string(forType: .html) ?? ""
            try check(html.contains("<table style=") && html.contains("☑ 끝") && !html.contains("<style"), "서식 HTML: \(html.prefix(200))")
            let rtf = pasteboard.data(forType: .rtf)
            try check((rtf?.count ?? 0) > 100, "RTF가 없습니다")
            if let rtf, let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                try check(attr.string.contains("제목") && attr.string.contains("☑"), "RTF 내용이 이상합니다")
            }
            main.editor.setSelectedRange(NSRange(location: 0, length: 4))
            main.copy(.md)
            try check(pasteboard.string(forType: .string) == "# 제목", "선택 영역만 복사되지 않았습니다")
            try check(pasteboard.string(forType: .html) == nil, "MD 복사에는 HTML이 없어야 합니다")
            try check(main.toasts.history.last?.hasSuffix("(선택한 부분만)") == true, "선택 복사 알림이 없습니다")
            main.editor.setSelectedRange(NSRange(location: 0, length: 0))
            main.copy(.plain)
            try check(pasteboard.string(forType: .string) == "■ 제목\n• 1: 2\n\n☑ 끝\n", "텍스트 복사: \(pasteboard.string(forType: .string) ?? "")")
            return nil
        }

        step("붙여넣기: Docs HTML은 마크다운으로, 이미 마크다운인 텍스트는 그대로") {
            setEditor(main, "")
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("<meta charset='utf-8'><b id=\"docs-internal-guid-1\" style=\"font-weight:normal\"><h2>회의록</h2><p>오늘은 <span style=\"font-weight:700\">중요</span>합니다.</p><ul><li>하나</li></ul><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table></b>", forType: .html)
            item.setString("회의록 오늘은 중요합니다.", forType: .string)
            pasteboard.writeObjects([item])
            main.editor.paste(nil)
            let pasted = main.text
            try check(pasted.contains("## 회의록") && pasted.contains("**중요**") && pasted.contains("- 하나") && pasted.contains("| a | b |"), "변환 결과: \(pasted)")
            try check(!pasted.hasPrefix("**"), "Docs 감싸기 태그가 굵게로 바뀌었습니다")
            setEditor(main, "")
            pasteboard.clearContents()
            let item2 = NSPasteboardItem()
            item2.setString("<p><strong>제목</strong></p>", forType: .html)
            item2.setString("## 제목\n\n- 이미 마크다운", forType: .string)
            pasteboard.writeObjects([item2])
            main.editor.paste(nil)
            try check(main.text == "## 제목\n\n- 이미 마크다운", "마크다운 텍스트가 바뀌었습니다: \(main.text)")
            return nil
        }

        step("폴더 열기: 한글 이름 폴더의 파일 목록(하위 폴더 포함, 숨김·다른 확장자 제외)") {
            // 앞 단계에서 저장하지 않은 새 문서가 남아 있으므로 "저장 안 함"으로 비운다.
            prompter.choices = ["discard"]
            main.newDoc()
            try check(main.text.isEmpty, "새 문서가 열리지 않았습니다")
            prompter.folders = [folder]
            main.perform("openFolder")
            pump(0.1)
            let paths = main.files.map(\.path)
            try check(paths == ["기존 메모.md", "하위/깊은 파일.md"], "파일 목록: \(paths)")
            try check(main.sidebar.shown.count == 2, "사이드바 목록 수가 다릅니다")
            screenshot(main, "04-폴더-열기")
            return paths.joined(separator: ", ")
        }

        step("새 문서 저장(⌘S): 첫 제목으로 이름을 제안하고 실제 디스크에 기록된다") {
            main.newDoc()
            setEditor(main, "# 새 보고서\n\n본문입니다.")
            prompter.names = [nil]
            try check(main.save(), "저장 실패")
            let url = folder.appendingPathComponent("새 보고서.md")
            try check(prompter.asked.contains("이름: 새 보고서.md"), "제안한 이름이 다릅니다: \(prompter.asked.suffix(2))")
            try check((try? String(contentsOf: url, encoding: .utf8)) == "# 새 보고서\n\n본문입니다.", "디스크 내용이 다릅니다")
            try check(main.files.contains { $0.path == "새 보고서.md" }, "목록에 나타나지 않았습니다")
            try check(main.file?.path == "새 보고서.md" && !main.isDirty, "열린 파일 상태가 이상합니다")
            try check(main.statusSaveText.hasPrefix("저장됨"), "상태 표시: \(main.statusSaveText)")
            // 같은 이름으로 또 저장하면 번호를 붙인다(덮어쓰기 금지)
            main.newDoc()
            setEditor(main, "# 새 보고서\n\n두 번째")
            prompter.names = [nil]
            try check(main.save(), "두 번째 저장 실패")
            try check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("새 보고서 2.md").path), "번호가 붙지 않았습니다")
            return nil
        }

        step("자동 저장과 안전한 쓰기(임시 파일이 남지 않음)") {
            main.openEntry(main.files.first { $0.path == "기존 메모.md" }!)
            try check(main.text.hasPrefix("# 기존 메모"), "파일이 열리지 않았습니다")
            setEditor(main, "# 기존 메모\n\n자동 저장 확인")
            try check(main.statusSaveText == "변경됨 (곧 자동 저장)", "상태: \(main.statusSaveText)")
            pump(2.2)
            let disk = try String(contentsOf: folder.appendingPathComponent("기존 메모.md"), encoding: .utf8)
            try check(disk == "# 기존 메모\n\n자동 저장 확인", "자동 저장되지 않았습니다: \(disk)")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mdstudio-tmp") }
            try check(leftovers.isEmpty, "임시 파일이 남았습니다: \(leftovers)")
            return nil
        }

        step("다른 앱이 파일을 고치면 창으로 돌아올 때 다시 불러온다 / 편집 중이면 경고만") {
            let url = folder.appendingPathComponent("기존 메모.md")
            try "# 기존 메모\n\n다른 앱에서 고침".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            main.checkExternalChange()
            try check(main.text == "# 기존 메모\n\n다른 앱에서 고침", "다시 불러오지 않았습니다: \(main.text)")
            try check(main.toasts.history.last == "다른 앱에서 바뀐 내용을 불러왔습니다", "알림이 없습니다")
            main.changeSetting { $0.autosave = false }
            setEditor(main, "# 기존 메모\n\n편집 중")
            try "# 기존 메모\n\n또 바뀜".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
            main.checkExternalChange()
            try check(main.text == "# 기존 메모\n\n편집 중", "편집 중인 내용을 덮어썼습니다")
            try check(main.toasts.history.last?.hasPrefix("이 파일이 다른 곳에서도 바뀌었습니다") == true, "경고가 없습니다")
            return nil
        }

        step("자동 저장을 끄면 파일을 바꿀 때 저장 여부를 묻는다 (취소 / 저장 안 함)") {
            try check(main.isDirty, "편집 중 상태가 아닙니다")
            prompter.choices = ["cancel"]
            main.openEntry(main.files.first { $0.path == "하위/깊은 파일.md" }!)
            try check(main.file?.path == "기존 메모.md", "취소했는데 파일이 바뀌었습니다")
            prompter.choices = ["discard"]
            main.openEntry(main.files.first { $0.path == "하위/깊은 파일.md" }!)
            try check(main.file?.path == "하위/깊은 파일.md" && main.text == "# 깊은 파일", "저장 안 함 후 열리지 않았습니다")
            main.changeSetting { $0.autosave = true }
            return nil
        }

        step("HTML 보고서 저장과 미리보기") {
            setEditor(main, "# 분기 보고\n\n## 요약\n본문\n\n## 상세\n\n### 세부\n\n| a | b |\n|---|---|\n| 1 | 2 |")
            let url = exportDir.appendingPathComponent("분기 보고.html")
            prompter.exports = [ExportChoice(action: .save, title: "분기 보고", includeToc: true, includeDate: true)]
            prompter.saveURLs = [url]
            main.perform("exportHtml")
            let html = try String(contentsOf: url, encoding: .utf8)
            try check(html.hasPrefix("<!doctype html>") && html.contains("<nav class=\"toc\">") && html.contains("MD Studio에서 생성"), "보고서 내용이 이상합니다")
            prompter.exports = [ExportChoice(action: .preview, title: "분기 보고", includeToc: true, includeDate: true)]
            main.perform("exportHtml")
            try check(openedInBrowser.last?.pathExtension == "html", "미리보기를 열지 않았습니다")
            try? FileManager.default.copyItem(at: url, to: out.appendingPathComponent("보고서.html"))
            return "\(html.utf8.count)바이트"
        }

        step("PDF로 내보내기: 인쇄 창 없이 A4 PDF 파일이 바로 만들어진다") {
            setEditor(main, SampleDoc.text)
            let url = exportDir.appendingPathComponent("보고서.pdf")
            prompter.exports = [ExportChoice(action: .save, title: "MD Studio 사용 안내", includeToc: true, includeDate: true)]
            prompter.saveURLs = [url]
            main.perform("exportPdf")
            let data = try Data(contentsOf: url)
            try check(data.starts(with: Data("%PDF".utf8)), "PDF 파일이 아닙니다")
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else {
                throw Failure(description: "PDF를 읽지 못했습니다")
            }
            try check(pdf.numberOfPages >= 1, "쪽이 없습니다")
            let box = pdf.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero
            try check(abs(box.width - 595.28) < 1 && abs(box.height - 841.89) < 1, "A4 크기가 아닙니다: \(box)")
            try? FileManager.default.copyItem(at: url, to: out.appendingPathComponent("보고서.pdf"))
            return "\(pdf.numberOfPages)쪽, \(data.count)바이트"
        }

        step("Finder에서 .md 파일 열기 / 끌어다 놓은 파일 확인") {
            main.openFromFinder(outside)
            try check(main.text.hasPrefix("# 폴더 밖 파일") && main.file?.fromFolder == false, "Finder 파일이 열리지 않았습니다")
            try check(main.topFileName == "바깥 파일.md", "파일 이름 표시: \(main.topFileName)")
            main.openDropped(folder.appendingPathComponent("그림.png"))
            try check(main.toasts.history.last == ".md 또는 .txt 파일만 열 수 있습니다", "확장자 확인 알림이 없습니다")
            return nil
        }

        step("보기 모드: 편집만 / 미리보기만 / 보기 전환, 파일 목록 숨기기") {
            main.setView(.edit)
            try check(main.isEditorPaneVisible && !main.isPreviewPaneVisible, "편집만 보기 이상")
            screenshot(main, "05-편집만")
            main.setView(.preview)
            try check(!main.isEditorPaneVisible && main.isPreviewPaneVisible, "미리보기만 보기 이상")
            main.perform("cycleView")
            try check(main.settings.view == .edit, "보기 전환 순서가 다릅니다")
            main.perform("cycleView")
            try check(main.settings.view == .split, "보기 전환 순서가 다릅니다")
            main.perform("toggleSidebar")
            try check(!main.isSidebarVisible, "파일 목록이 숨겨지지 않았습니다")
            main.perform("toggleSidebar")
            try check(main.isSidebarVisible, "파일 목록이 다시 보이지 않습니다")
            return nil
        }

        step("다크 모드 화면") {
            main.changeSetting { $0.theme = .dark }
            setEditor(main, SampleDoc.text)
            main.renderPreview()
            pump(0.2)
            screenshot(main, "06-다크모드")
            main.changeSetting { $0.theme = .system }
            return nil
        }

        step("창을 닫을 때 저장 안 한 내용이 있으면 묻고, \"취소\"면 닫히지 않는다") {
            main.newDoc()
            setEditor(main, "닫기 전 내용")
            prompter.choices = ["cancel"]
            try check(main.canClose() == false, "취소했는데 닫혔습니다")
            prompter.choices = ["close"]
            try check(main.canClose() == true, "저장하지 않고 닫기가 되지 않습니다")
            return nil
        }

        step("임시본: 저장하지 않은 새 문서는 다시 열 때 묻지 않고 복구된다") {
            let env = environment()
            let draft = env.drafts.load("untitled")
            try check(draft?.text == "닫기 전 내용", "임시본이 보관되지 않았습니다")
            let second = MainWindowController(env: env)
            second.start()
            pump(0.2)
            defer { second.window?.orderOut(nil) }
            try check(second.text == "닫기 전 내용", "복구되지 않았습니다: \(second.text)")
            try check(second.toasts.history.contains("지난번에 저장하지 않은 내용을 복구했습니다"), "복구 알림이 없습니다")
            try check(second.folder?.standardizedFileURL == folder.standardizedFileURL, "지난 폴더가 다시 열리지 않았습니다")
            env.drafts.clear("untitled")
            second.loadDoc(text: "")
            return nil
        }

        step("긴 문서(5,000줄)도 입력과 미리보기가 느려지지 않는다") {
            var big = ""
            for i in 0..<1000 {
                big += "## 절 \(i)\n\n본문 **굵게** 와 [링크](https://e.com/\(i)) 그리고 `코드`.\n\n- 항목\n\n"
            }
            let t0 = Date()
            setEditor(main, big)
            let setMs = Date().timeIntervalSince(t0) * 1000
            main.editor.insertText("첫", replacementRange: NSRange(location: 0, length: 0))
            main.window?.displayIfNeeded()
            var typing: [Double] = []
            for i in 0..<5 {
                let t1 = Date()
                main.editor.insertText("가", replacementRange: NSRange(location: i, length: 0))
                main.window?.displayIfNeeded()
                typing.append(Date().timeIntervalSince(t1) * 1000)
            }
            let typeMs = typing.max() ?? 0
            let t2 = Date()
            main.renderPreview()
            let previewMs = Date().timeIntervalSince(t2) * 1000
            metrics["bigDocSetMs"] = String(format: "%.0f", setMs)
            metrics["bigDocTypeMs"] = String(format: "%.0f", typeMs)
            metrics["bigDocPreviewMs"] = String(format: "%.0f", previewMs)
            try check(typeMs < 50, "글자 하나 입력이 느립니다: \(Int(typeMs))ms")
            return "불러오기 \(Int(setMs))ms, 입력 \(Int(typeMs))ms, 미리보기 \(Int(previewMs))ms"
        }

        step("화면 오류·예상하지 못한 질문이 없다") {
            try check(prompter.unexpected.isEmpty, "예상하지 못한 창: \(prompter.unexpected)")
            let errors = appLog.allEntries().filter { $0.level == .error }.map(\.formatted)
            try check(errors.isEmpty, "오류 로그: \(errors)")
            return nil
        }

        // 마무리: 예제 문서 하나만 열린 상태의 메모리
        main.loadDoc(text: SampleDoc.text)
        main.setView(.split)
        pump(1.0)
        metrics["footprintSampleDocMB"] = String(format: "%.1f", footprintMB())

        let passed = results.filter(\.ok).count
        let report = Report(passed: passed, failed: results.count - passed, steps: results, metrics: metrics, screenshots: shots)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(report) {
            try? data.write(to: out.appendingPathComponent("selftest.json"))
        }
        print("\n\(passed) passed, \(results.count - passed) failed  (메모리 \(metrics["footprintSampleDocMB"] ?? "?")MB)")
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: work)
        appLog.flush()
        // 저장 확인 창 없이 끝낸다.
        main.loadDoc(text: "")
        exit(results.count == passed ? 0 : 1)
    }
}
