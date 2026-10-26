// swift-tools-version:5.9
// MDCore: 마크다운을 텍스트 복사용 글자, Slack용 HTML로 바꾸는 변환 엔진.
// 웹 버전 src/convert.js의 규칙을 그대로 옮긴 것이며, test/fixtures/golden.json과 대조해 검증한다.
import PackageDescription

let package = Package(
    name: "MDCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MDCore", targets: ["MDCore"]),
    ],
    dependencies: [
        // Apple의 마크다운 분석기 (cmark-gfm 기반, 표·취소선·할 일 목록 지원). 버전을 정확히 고정한다.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MDCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(
            name: "MDCoreTests",
            dependencies: ["MDCore"]
        ),
    ]
)
