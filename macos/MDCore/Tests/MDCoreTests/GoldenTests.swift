// 정답 대조 테스트: test/fixtures/golden.json(웹 버전 src/convert.js가 만든 결과)과 Swift 결과를 비교한다.
// 사례 21개 × 출력 8종(title, plain_title/inline/grid, slack_title/grid, *_nobreaks)이 모두 같아야 통과한다.
// 결과가 다르면 정답을 고치지 말고, 출력되는 차이를 사용자에게 보고한다(CLAUDE.md 규칙).
import Foundation
import XCTest
@testable import MDCore

/// golden.json의 사례 하나
private struct GoldenCase: Decodable {
    let name: String
    let markdown: String
    let title: String
    let plain_title: String
    let plain_inline: String
    let plain_grid: String
    let slack_title: String
    let slack_grid: String
    let plain_title_nobreaks: String
    let slack_title_nobreaks: String
}

private struct GoldenFile: Decodable {
    let cases: [GoldenCase]
}

final class GoldenTests: XCTestCase {
    /// 저장소 루트의 golden.json 위치. 이 파일 기준으로 네 단계 위가 저장소 루트다.
    private static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MDCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MDCore
        .deletingLastPathComponent()  // macos
        .deletingLastPathComponent()  // 저장소 루트
        .appendingPathComponent("test/fixtures/golden.json")

    /// 환경 변수 MDCORE_GOLDEN에 다른 정답 파일 경로를 주면 그 파일로 대조한다(추가 경계 사례 점검용).
    private static var overrideURL: URL? {
        ProcessInfo.processInfo.environment["MDCORE_GOLDEN"].map { URL(fileURLWithPath: $0) }
    }

    private func loadCases() throws -> [GoldenCase] {
        let data = try Data(contentsOf: Self.overrideURL ?? Self.goldenURL)
        return try JSONDecoder().decode(GoldenFile.self, from: data).cases
    }

    func testGoldenFileHasExpectedCaseCount() throws {
        try XCTSkipIf(Self.overrideURL != nil, "다른 정답 파일로 점검하는 중")
        XCTAssertEqual(try loadCases().count, 21, "golden.json 사례 수가 바뀌었습니다. 정답 데이터를 확인하세요.")
    }

    func testAllOutputsMatchGolden() throws {
        let cases = try loadCases()
        var mismatches: [String] = []
        var checked = 0

        for c in cases {
            let outputs: [(String, String, String)] = [
                ("title", c.title, MDConverter.extractTitle(c.markdown)),
                ("plain_title", c.plain_title, MDConverter.toPlainText(c.markdown, options: .init(tableMode: .title))),
                ("plain_inline", c.plain_inline, MDConverter.toPlainText(c.markdown, options: .init(tableMode: .inline))),
                ("plain_grid", c.plain_grid, MDConverter.toPlainText(c.markdown, options: .init(tableMode: .grid))),
                ("slack_title", c.slack_title, MDConverter.toSlackHtml(c.markdown, options: .init(tableMode: .title))),
                ("slack_grid", c.slack_grid, MDConverter.toSlackHtml(c.markdown, options: .init(tableMode: .grid))),
                ("plain_title_nobreaks", c.plain_title_nobreaks,
                 MDConverter.toPlainText(c.markdown, options: .init(tableMode: .title, breaks: false))),
                ("slack_title_nobreaks", c.slack_title_nobreaks,
                 MDConverter.toSlackHtml(c.markdown, options: .init(tableMode: .title, breaks: false))),
            ]
            for (kind, expected, actual) in outputs {
                checked += 1
                if expected != actual {
                    mismatches.append("""
                    [\(c.name) / \(kind)]
                      정답: \(debugQuote(expected))
                      결과: \(debugQuote(actual))
                      처음 다른 위치: \(firstDifference(expected, actual))
                    """)
                }
            }
        }

        print("정답 대조: \(checked)개 중 \(checked - mismatches.count)개 일치")
        if !mismatches.isEmpty {
            XCTFail("정답과 다른 결과 \(mismatches.count)개\n" + mismatches.joined(separator: "\n"))
        }
    }

    /// 줄바꿈 같은 보이지 않는 글자를 눈에 보이게 감싼다.
    private func debugQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// 두 글자가 처음 달라지는 위치와 그 주변을 알려 준다.
    private func firstDifference(_ a: String, _ b: String) -> String {
        let ac = Array(a), bc = Array(b)
        var i = 0
        while i < ac.count, i < bc.count, ac[i] == bc[i] { i += 1 }
        let around = { (chars: [Character]) -> String in
            self.debugQuote(String(chars[min(i, chars.count)..<min(i + 15, chars.count)]))
        }
        return "\(i)번째 글자 — 정답 \(around(ac)), 결과 \(around(bc))"
    }
}
