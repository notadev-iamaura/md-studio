// swift-tools-version:5.9
// MD Studio 맥 앱 (AppKit). 브라우저 엔진 없이 맥 기본 부품으로 화면을 그린다.
// - MDStudioKit: 화면·파일·클립보드 등 앱의 모든 기능 (테스트 가능하도록 라이브러리로 분리)
// - MDStudio: 실행 파일 (앱 시작만 담당)
// 변환 규칙은 ../MDCore를 그대로 쓴다.
import PackageDescription

let package = Package(
    name: "MDStudio",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MDStudio", targets: ["MDStudio"]),
    ],
    dependencies: [
        .package(path: "../MDCore"),
    ],
    targets: [
        .target(
            name: "MDStudioKit",
            dependencies: [.product(name: "MDCore", package: "MDCore")]
        ),
        .executableTarget(
            name: "MDStudio",
            dependencies: ["MDStudioKit"]
        ),
        .testTarget(
            name: "MDStudioKitTests",
            dependencies: ["MDStudioKit"]
        ),
    ]
)
