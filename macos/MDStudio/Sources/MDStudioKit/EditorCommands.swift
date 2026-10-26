// 편집기 서식 명령 (src/editor.js의 commands를 옮김). 화면과 분리된 순수 함수라 테스트할 수 있다.
// - wrap: 굵게·기울임·취소선·인라인 코드 (감싸기, 이미 감싸져 있으면 해제, 선택이 없으면 자리표시 글자)
// - toggleLinePrefix: 제목·글머리·번호·할 일·인용 (선택한 모든 줄, 전부 같은 형식이면 해제)
// - insertBlock: 코드 블록·표·구분선
// - link: [텍스트](https://)
// - continueList: 목록에서 Enter → 다음 기호 자동 입력, 빈 항목에서 Enter → 목록 끝내기
// - indent: Tab / ⇧Tab 줄 들여쓰기 (2칸)
// 위치와 길이는 NSTextView와 같은 UTF-16 단위(NSRange)를 쓴다.
// 의존성: Foundation
import Foundation

/// 글 한 군데를 바꾸는 작업
public struct TextEdit: Equatable {
    public var range: NSRange
    public var replacement: String
}

/// 명령 결과: 바꿀 곳들(원래 글 기준 위치, 겹치지 않음)과 바꾼 뒤의 선택 영역
public struct CommandResult: Equatable {
    public var edits: [TextEdit]
    public var selection: NSRange

    /// 결과를 글에 적용한다(테스트와 화면이 같은 방식으로 쓴다).
    public func apply(to text: String) -> String {
        let ns = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: e.range, with: e.replacement)
        }
        return ns as String
    }
}

public enum FormatCommand: String, CaseIterable {
    case bold, italic, strike, code, link
    case h1, h2, h3
    case ul, ol, task, quote
    case codeBlock, table, hr
}

public enum EditorCommands {
    // MARK: - 진입점

    /// 명령을 실행한 결과를 돌려준다.
    ///
    /// - Parameters:
    ///   - command: 서식 명령
    ///   - text: 편집기의 전체 글
    ///   - selections: 선택 영역들 (여러 군데 선택 가능)
    public static func run(_ command: FormatCommand, text: String, selections: [NSRange]) -> CommandResult {
        let sel = selections.first ?? NSRange(location: 0, length: 0)
        switch command {
        case .bold: return wrap(text, sel, "**", "**", placeholder: "굵은 글씨")
        case .italic: return wrap(text, sel, "*", "*", placeholder: "기울임")
        case .strike: return wrap(text, sel, "~~", "~~", placeholder: "취소선")
        case .code: return wrap(text, sel, "`", "`", placeholder: "code")
        case .link: return link(text, sel)
        case .h1: return toggleLinePrefix(text, selections, kind: .heading(1))
        case .h2: return toggleLinePrefix(text, selections, kind: .heading(2))
        case .h3: return toggleLinePrefix(text, selections, kind: .heading(3))
        case .ul: return toggleLinePrefix(text, selections, kind: .bullet)
        case .ol: return toggleLinePrefix(text, selections, kind: .ordered)
        case .task: return toggleLinePrefix(text, selections, kind: .task)
        case .quote: return toggleLinePrefix(text, selections, kind: .quote)
        case .codeBlock: return codeBlock(text, sel)
        case .table:
            return insertBlock(text, sel, "| 항목 | 내용 | 비고 |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |", cursorOffset: 2)
        case .hr: return insertBlock(text, sel, "---")
        }
    }

    // MARK: - 감싸기

    static func wrap(_ text: String, _ sel: NSRange, _ before: String, _ after: String, placeholder: String) -> CommandResult {
        let ns = text as NSString
        let b = (before as NSString).length, a = (after as NSString).length
        let selected = ns.substring(with: sel)
        let outerFrom = sel.location - b
        let outerTo = NSMaxRange(sel) + a
        // 이미 바깥이 감싸져 있으면 해제
        if outerFrom >= 0, outerTo <= ns.length,
           ns.substring(with: NSRange(location: outerFrom, length: b)) == before,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: a)) == after {
            return CommandResult(
                edits: [TextEdit(range: NSRange(location: outerFrom, length: b), replacement: ""),
                        TextEdit(range: NSRange(location: NSMaxRange(sel), length: a), replacement: "")],
                selection: NSRange(location: outerFrom, length: sel.length))
        }
        // 선택 안쪽이 감싸져 있으면 해제
        let selLen = (selected as NSString).length
        if selected.hasPrefix(before), selected.hasSuffix(after), selLen >= b + a {
            let inner = (selected as NSString).substring(with: NSRange(location: b, length: selLen - b - a))
            return CommandResult(edits: [TextEdit(range: sel, replacement: inner)],
                                 selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        let body = selected.isEmpty ? placeholder : selected
        return CommandResult(edits: [TextEdit(range: sel, replacement: before + body + after)],
                             selection: NSRange(location: sel.location + b, length: (body as NSString).length))
    }

    // MARK: - 줄 앞 기호

    enum LineKind: Equatable {
        case heading(Int), bullet, ordered, task, quote
    }

    // 줄 앞의 블록 기호: 들여쓰기 + (제목 | 인용 | 할 일 | 글머리 | 번호)
    private static let blockPrefix = try! NSRegularExpression(
        pattern: "^([ \\t]*)(#{1,6}[ \\t]+|>[ \\t]?|[-*+][ \\t]+\\[[ xX]\\][ \\t]+|[-*+][ \\t]+|\\d+[.)][ \\t]+)")

    /// 선택 영역들이 걸친 줄의 범위 목록(줄바꿈 제외). 원본처럼 선택 끝이 줄 시작이어도 그 줄을 포함한다.
    static func lineRanges(_ ns: NSString, _ selections: [NSRange]) -> [NSRange] {
        var starts = Set<Int>()
        var out: [NSRange] = []
        for r in selections {
            var pos = r.location
            repeat {
                let line = lineRange(ns, at: pos)
                if !starts.contains(line.location) {
                    starts.insert(line.location)
                    out.append(line)
                }
                pos = NSMaxRange(line) + 1
            } while pos <= NSMaxRange(r) && pos <= ns.length
        }
        return out.sorted { $0.location < $1.location }
    }

    /// pos가 들어 있는 줄(줄바꿈 제외)
    static func lineRange(_ ns: NSString, at pos: Int) -> NSRange {
        let p = min(max(pos, 0), ns.length)
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: p, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func toggleLinePrefix(_ text: String, _ selections: [NSRange], kind: LineKind) -> CommandResult {
        let ns = text as NSString
        let lines = lineRanges(ns, selections)

        func prefix(for i: Int) -> String {
            switch kind {
            case .heading(let level): return String(repeating: "#", count: level) + " "
            case .bullet: return "- "
            case .ordered: return "\(i + 1). "
            case .task: return "- [ ] "
            case .quote: return "> "
            }
        }
        func isKind(_ p: String) -> Bool {
            let t = p.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .heading(let level): return t == String(repeating: "#", count: level)
            case .task: return p.range(of: "\\[[ xX]\\]", options: .regularExpression) != nil
            case .bullet: return p.range(of: "^[-*+][ \\t]+$", options: .regularExpression) != nil
            case .ordered: return p.range(of: "^\\d+[.)][ \\t]+$", options: .regularExpression) != nil
            case .quote: return p.hasPrefix(">")
            }
        }

        let matches: [NSTextCheckingResult?] = lines.map { line in
            blockPrefix.firstMatch(in: ns.substring(with: line), range: NSRange(location: 0, length: line.length))
        }
        let allSame = zip(lines, matches).allSatisfy { line, m in
            guard let m else { return false }
            return isKind((ns.substring(with: line) as NSString).substring(with: m.range(at: 2)))
        }

        var edits: [TextEdit] = []
        for (i, (line, m)) in zip(lines, matches).enumerated() {
            let lineText = ns.substring(with: line) as NSString
            let indent: String
            let replaceLen: Int
            if let m {
                indent = lineText.substring(with: m.range(at: 1))
                replaceLen = m.range.length
            } else {
                let ws = lineText.range(of: "^[ \\t]*", options: .regularExpression)
                indent = ws.location == NSNotFound ? "" : lineText.substring(with: ws)
                replaceLen = (indent as NSString).length
            }
            edits.append(TextEdit(range: NSRange(location: line.location, length: replaceLen),
                                  replacement: indent + (allSame ? "" : prefix(for: i))))
        }
        let main = selections.first ?? NSRange(location: 0, length: 0)
        let start = mapPosition(main.location, through: edits, after: main.length == 0)
        let end = mapPosition(NSMaxRange(main), through: edits, after: true)
        return CommandResult(edits: edits, selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// 원래 글의 위치를 바꾼 뒤의 위치로 옮긴다.
    /// after가 참이면 같은 자리에 글이 들어갈 때 그 글 뒤로 간다(커서가 새 기호 뒤에 오도록).
    static func mapPosition(_ pos: Int, through edits: [TextEdit], after: Bool) -> Int {
        var shift = 0
        for e in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let start = e.range.location, end = NSMaxRange(e.range)
            let newLen = (e.replacement as NSString).length
            if pos < start { break }
            if e.range.length == 0 && pos == start {
                // 같은 자리에 글이 들어감: after면 그 뒤로, 아니면 앞에 머문다.
                if after { shift += newLen; continue }
                break
            }
            if pos >= end {
                shift += newLen - e.range.length
                continue
            }
            // 바뀌는 자리 안쪽: 새 글의 끝(after) 또는 시작으로
            return start + shift + (after ? newLen : 0)
        }
        return pos + shift
    }

    // MARK: - 블록 넣기

    static func insertBlock(_ text: String, _ sel: NSRange, _ block: String, cursorOffset: Int? = nil) -> CommandResult {
        let ns = text as NSString
        let line = lineRange(ns, at: sel.location)
        let lineText = ns.substring(with: line)
        let needsBreak = lineText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n\n"
        let insert = needsBreak + block + "\n"
        let from = needsBreak.isEmpty ? line.location : NSMaxRange(line)
        let range = NSRange(location: from, length: NSMaxRange(line) - from)
        let anchor = from + (needsBreak as NSString).length + (cursorOffset ?? (block as NSString).length)
        return CommandResult(edits: [TextEdit(range: range, replacement: insert)],
                             selection: NSRange(location: anchor, length: 0))
    }

    static func codeBlock(_ text: String, _ sel: NSRange) -> CommandResult {
        let selected = (text as NSString).substring(with: sel)
        if selected.contains("\n") {
            let insert = "```\n" + selected + "\n```"
            return CommandResult(edits: [TextEdit(range: sel, replacement: insert)],
                                 selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        }
        return insertBlock(text, sel, "```\n" + selected + "\n```", cursorOffset: 4)
    }

    // MARK: - 링크

    static func link(_ text: String, _ sel: NSRange) -> CommandResult {
        let selected = (text as NSString).substring(with: sel)
        let isURL = selected.range(of: "^https?://\\S+$", options: .regularExpression) != nil
        let label = isURL || selected.isEmpty ? "링크 텍스트" : selected
        let url = isURL ? selected : "https://"
        let insert = "[\(label)](\(url))"
        let labelLen = (label as NSString).length, urlLen = (url as NSString).length
        // 글자를 골랐으면 주소 부분을, 주소를 골랐으면(또는 아무것도 안 골랐으면) 글자 부분을 선택한다.
        let selection = isURL || selected.isEmpty
            ? NSRange(location: sel.location + 1, length: labelLen)
            : NSRange(location: sel.location + labelLen + 3, length: urlLen)
        return CommandResult(edits: [TextEdit(range: sel, replacement: insert)], selection: selection)
    }

    // MARK: - 목록 이어 쓰기 (Enter)

    private static let listLine = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])([ \\t]+)(\\[[ xX]\\][ \\t]+)?|(\\d+)([.)])([ \\t]+)|(>)([ \\t]?))")

    /// 커서가 코드 블록(``` 안)에 있는지
    static func isInsideFence(_ ns: NSString, _ pos: Int) -> Bool {
        var inside = false
        var lineStart = 0
        while lineStart < ns.length {
            let line = lineRange(ns, at: lineStart)
            if line.location >= lineRange(ns, at: pos).location { break }
            let t = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inside.toggle() }
            lineStart = NSMaxRange(line) + 1
        }
        return inside
    }

    /// Enter를 눌렀을 때 목록 기호를 이어 준다. 목록 줄이 아니면 nil(평소처럼 줄바꿈).
    ///
    /// - 내용이 있는 항목: 줄바꿈 + 같은 기호(번호는 +1, 할 일은 빈 칸)
    /// - 기호만 있는 빈 항목: 기호를 지워 목록을 끝낸다
    public static func continueList(text: String, selection: NSRange) -> CommandResult? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let pos = selection.location
        let line = lineRange(ns, at: pos)
        let lineText = ns.substring(with: line) as NSString
        guard let m = listLine.firstMatch(in: lineText as String, range: NSRange(location: 0, length: lineText.length)) else {
            return nil
        }
        // 커서가 기호 앞에 있으면 평소처럼
        guard pos - line.location >= m.range.length else { return nil }
        if isInsideFence(ns, pos) { return nil }

        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : lineText.substring(with: r)
        }
        let indent = group(1)
        let rest = lineText.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            // 빈 항목: 기호를 지우고 목록을 끝낸다.
            return CommandResult(edits: [TextEdit(range: line, replacement: "")],
                                 selection: NSRange(location: line.location, length: 0))
        }
        let next: String
        if !group(2).isEmpty {
            next = indent + group(2) + group(3) + (group(4).isEmpty ? "" : "[ ] ")
        } else if !group(5).isEmpty {
            next = indent + "\((Int(group(5)) ?? 0) + 1)" + group(6) + group(7)
        } else {
            next = indent + "> "
        }
        let insert = "\n" + next
        return CommandResult(edits: [TextEdit(range: selection, replacement: insert)],
                             selection: NSRange(location: pos + (insert as NSString).length, length: 0))
    }

    // MARK: - 들여쓰기 (Tab / ⇧Tab)

    public static let indentUnit = "  "

    /// 선택한 줄들을 2칸 들여쓰거나(outdent가 거짓) 내어쓴다.
    public static func indent(text: String, selections: [NSRange], outdent: Bool) -> CommandResult {
        let ns = text as NSString
        let lines = lineRanges(ns, selections)
        var edits: [TextEdit] = []
        for line in lines {
            if outdent {
                let lineText = ns.substring(with: line)
                var remove = 0
                for ch in lineText.utf16.prefix(2) {
                    if ch == 0x20 { remove += 1 } else if ch == 0x09 { remove += 1; break } else { break }
                }
                if remove > 0 { edits.append(TextEdit(range: NSRange(location: line.location, length: remove), replacement: "")) }
            } else {
                edits.append(TextEdit(range: NSRange(location: line.location, length: 0), replacement: indentUnit))
            }
        }
        let main = selections.first ?? NSRange(location: 0, length: 0)
        let start = mapPosition(main.location, through: edits, after: true)
        let end = mapPosition(NSMaxRange(main), through: edits, after: true)
        return CommandResult(edits: edits, selection: NSRange(location: start, length: max(0, end - start)))
    }
}
