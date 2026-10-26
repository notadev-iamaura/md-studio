// 표를 목록 구조나 고정폭 표 글자로 바꾼다. 텍스트·Slack 두 출력이 함께 쓴다.
// - tableItems: 제목형/한 줄형 목록 구조 (convert.js의 tableToItems)
// - tableGrid: 열 너비를 맞춘 고정폭 표 (convert.js의 tableToGrid)
// 목록 구조는 칸의 서식 조각을 그대로 들고 있어서, 텍스트·Slack 렌더러가 각자 서식을 입힌다.
// 의존성: 없음 (MDCore 내부)
import Foundation

/// 목록 한 줄을 이루는 조각
struct TablePart: Equatable {
    enum Kind: Equatable {
        /// 굵게 표시할 조각(첫 칸)
        case bold
        /// 그냥 글자(": ", " — " 같은 이음 글자)
        case text
        /// 칸 내용
        case cell
    }

    var kind: Kind
    /// 칸 내용이면 서식 조각, 아니면 nil
    var inlines: [Inline]?
    /// 고정 글자이면 그 글자, 아니면 nil
    var text: String?

    static func bold(_ inlines: [Inline]) -> TablePart { TablePart(kind: .bold, inlines: inlines, text: nil) }
    static func bold(text: String) -> TablePart { TablePart(kind: .bold, inlines: nil, text: text) }
    static func text(_ text: String) -> TablePart { TablePart(kind: .text, inlines: nil, text: text) }
    static func cell(_ inlines: [Inline]) -> TablePart { TablePart(kind: .cell, inlines: inlines, text: nil) }
}

/// 목록 항목 하나와 그 하위 항목
struct TableItem: Equatable {
    var parts: [TablePart]
    var children: [TableItem]
}

enum TableLayout {
    /// 칸의 글자를 텍스트로 뽑는다. 칸 안의 줄바꿈은 " / "가 된다.
    private static func cellText(_ cell: [Inline]?) -> String {
        TextUtils.jsTrim(PlainRenderer.inlineText(cell ?? [], inCell: true))
    }

    private static func cellIsEmpty(_ cell: [Inline]?) -> Bool {
        cellText(cell).isEmpty
    }

    /// 표를 목록 구조로 바꾼다.
    ///
    /// - Parameters:
    ///   - table: 표
    ///   - mode: .title(제목형) 또는 .inline(한 줄형). .grid는 이 함수를 쓰지 않는다.
    /// - Returns: 목록 항목들. 빈 칸은 생략한다.
    static func tableItems(_ table: TableNode, mode: MDOptions.TableMode) -> [TableItem] {
        let headers = table.header
        let cols = headers.count
        // 머리글이 비어 있으면 "항목 N"으로 부른다.
        func headerText(_ i: Int) -> String {
            let t = i < headers.count ? cellText(headers[i]) : ""
            return t.isEmpty ? "항목 \(i + 1)" : t
        }

        var items: [TableItem] = []
        for (ri, row) in table.rows.enumerated() {
            let first: [Inline]? = row.first ?? nil
            let titleParts: [TablePart] = cellIsEmpty(first)
                ? [.bold(text: "\(headerText(0)) \(ri + 1)")]
                : [.bold(first ?? [])]

            if cols <= 1 {
                // 1열 표: 칸마다 항목 하나
                if !cellIsEmpty(first) { items.append(TableItem(parts: [.cell(first ?? [])], children: [])) }
                continue
            }

            var rest: [(label: String, inlines: [Inline])] = []
            for i in 1..<cols {
                let cell: [Inline]? = i < row.count ? row[i] : nil
                if cellIsEmpty(cell) { continue }
                rest.append((headerText(i), cell ?? []))
            }

            if cols == 2 {
                // 2열 표는 "키: 값" 한 줄이 가장 읽기 좋다.
                var parts = titleParts
                if let value = rest.first { parts += [.text(": "), .cell(value.inlines)] }
                items.append(TableItem(parts: parts, children: []))
                continue
            }

            if mode == .inline {
                var parts = titleParts
                for (idx, r) in rest.enumerated() {
                    parts.append(.text(idx == 0 ? " — " : " · "))
                    parts += [.text("\(r.label): "), .cell(r.inlines)]
                }
                items.append(TableItem(parts: parts, children: []))
                continue
            }

            let children = rest.map { r in
                TableItem(parts: [.text("\(r.label): "), .cell(r.inlines)], children: [])
            }
            items.append(TableItem(parts: titleParts, children: children))
        }
        return items
    }

    /// 열 너비를 맞춘 고정폭 표 글자를 만든다. 열 사이는 " │ ", 머리글 아래는 "─┼─"로 구분한다.
    static func tableGrid(_ table: TableNode) -> String {
        let headers = table.header.map { cellText($0) }
        let rows = table.rows.map { row in row.map { cellText($0) } }
        let cols = headers.count
        let widths: [Int] = (0..<cols).map { i in
            let rowMax = rows.map { TextUtils.textWidth(i < $0.count ? $0[i] : "") }.max() ?? 0
            return max(TextUtils.textWidth(headers[i]), rowMax, 3)
        }
        func line(_ cells: [String]) -> String {
            TextUtils.jsTrimEnd(
                cells.enumerated().map { i, c in TextUtils.padEnd(c, widths[i]) }.joined(separator: " │ ")
            )
        }
        let sep = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")
        let body = rows.map { r in line((0..<cols).map { i in i < r.count ? r[i] : "" }) }
        return ([line(headers), sep] + body).joined(separator: "\n")
    }
}
