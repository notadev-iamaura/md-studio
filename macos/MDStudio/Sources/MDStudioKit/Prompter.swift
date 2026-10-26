// 사용자에게 묻는 창(확인·이름 입력·내보내기 옵션·파일 선택)을 한곳에 모았다.
// 실제 앱은 맥 기본 창(NSAlert, NSOpenPanel, NSSavePanel)을 쓰고,
// 자가 점검(SelfTest)은 정해진 답을 돌려주는 Prompter로 바꿔 끼워 사람 없이 끝까지 실행한다.
// 의존성: AppKit
import AppKit

/// 확인 창의 버튼 하나
public struct ChoiceButton {
    public var value: String
    public var label: String
    public var isDestructive = false
    public var isDefault = false

    public init(_ value: String, _ label: String, destructive: Bool = false, isDefault: Bool = false) {
        self.value = value
        self.label = label
        self.isDestructive = destructive
        self.isDefault = isDefault
    }
}

/// 내보내기 창에서 고른 값
public struct ExportChoice {
    public enum Action { case save, preview }
    public var action: Action
    public var title: String
    public var includeToc: Bool
    public var includeDate: Bool
}

public protocol Prompter: AnyObject {
    /// 버튼 중 하나를 고르게 한다. 창을 닫으면 "cancel".
    func askChoice(title: String, message: String, buttons: [ChoiceButton], window: NSWindow?) -> String
    /// 파일 이름을 묻는다. 취소하면 nil.
    func askName(defaultName: String, hint: String, window: NSWindow?) -> String?
    /// 보고서 내보내기 옵션을 묻는다. 취소하면 nil.
    func askExport(isPDF: Bool, defaultTitle: String, window: NSWindow?) -> ExportChoice?
    func pickFolder(window: NSWindow?) -> URL?
    func pickFileToOpen(window: NSWindow?) -> URL?
    /// 저장 위치를 고르게 한다. ext는 "md" "html" "pdf".
    func pickSaveURL(suggestedName: String, ext: String, directory: URL?, window: NSWindow?) -> URL?
}

/// 맥 기본 창을 쓰는 Prompter
public final class SystemPrompter: Prompter {
    public init() {}

    public func askChoice(title: String, message: String, buttons: [ChoiceButton], window: NSWindow?) -> String {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        // NSAlert는 첫 버튼이 기본(Enter) 버튼이다. 기본 버튼을 맨 앞에 둔다.
        let ordered = buttons.filter(\.isDefault) + buttons.filter { !$0.isDefault }
        for b in ordered {
            let button = alert.addButton(withTitle: b.label)
            if b.isDestructive { button.hasDestructiveAction = true }
            if b.value == "cancel" { button.keyEquivalent = "\u{1b}" }
        }
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0 && index < ordered.count else { return "cancel" }
        return ordered[index].value
    }

    public func askName(defaultName: String, hint: String, window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = "파일 이름"
        alert.informativeText = hint
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            // 확장자 앞까지만 선택해 바로 고쳐 쓰게 한다.
            let base = (defaultName as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return FileStore.cleanFileName(field.stringValue)
    }

    public func askExport(isPDF: Bool, defaultTitle: String, window: NSWindow?) -> ExportChoice? {
        let alert = NSAlert()
        alert.messageText = isPDF ? "PDF로 저장" : "HTML 보고서로 저장"
        alert.informativeText = "보고서 제목과 넣을 항목을 고르세요."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        if !isPDF { alert.addButton(withTitle: "브라우저로 미리보기") }

        let title = NSTextField(string: defaultTitle)
        title.placeholderString = "보고서 제목"
        let toc = NSButton(checkboxWithTitle: "목차 넣기 (소제목이 3개 이상일 때)", target: nil, action: nil)
        toc.state = .on
        let date = NSButton(checkboxWithTitle: "작성 날짜 넣기", target: nil, action: nil)
        date.state = .on
        let label = NSTextField(labelWithString: "보고서 제목")
        let stack = NSStackView(views: [label, title, toc, date])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 110)
        title.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = title

        let response = alert.runModal()
        let action: ExportChoice.Action
        switch response {
        case .alertFirstButtonReturn: action = .save
        case .alertThirdButtonReturn: action = .preview
        default: return nil
        }
        let t = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExportChoice(action: action, title: t.isEmpty ? "보고서" : t, includeToc: toc.state == .on, includeDate: date.state == .on)
    }

    public func pickFolder(window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "폴더 열기"
        panel.prompt = "이 폴더 열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func pickFileToOpen(window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "마크다운 파일 열기"
        panel.prompt = "열기"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.delegate = MarkdownOpenFilter.shared
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func pickSaveURL(suggestedName: String, ext: String, directory: URL?, window: NSWindow?) -> URL? {
        let panel = NSSavePanel()
        panel.title = ext == "pdf" ? "PDF로 저장" : ext == "html" ? "HTML 보고서 저장" : "저장"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != ext && !(ext == "md" && FileStore.isMarkdown(url)) {
            url = url.appendingPathExtension(ext)
        }
        return url
    }
}

/// 열기 창에서 마크다운·텍스트 파일만 고를 수 있게 한다.
final class MarkdownOpenFilter: NSObject, NSOpenSavePanelDelegate {
    static let shared = MarkdownOpenFilter()

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return true }
        return FileStore.isMarkdown(url)
    }
}
