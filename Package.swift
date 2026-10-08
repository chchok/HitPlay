// swift-tools-version: 5.9
import PackageDescription

// HitPlaySourceKit —— 猫源 / py源 引擎套件（开源发布版）。
// 三个库 + 一个测试目标；宿主脚本（Node/Python）作为模块资源随包分发，
// 引擎运行时按「模块资源优先、App 主包兜底」定位，独立使用零配置。
let package = Package(
    name: "HitPlaySourceKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15)
    ],
    products: [
        .library(name: "HitPlayKit", targets: ["HitPlayKit"]),
        .library(name: "HitPlayPySource", targets: ["HitPlayPySource"]),
        .library(name: "HitPlayCatSource", targets: ["HitPlayCatSource"])
    ],
    targets: [
        // 跨模块公共件（钥匙串令牌存取、URL 字符集）。
        .target(name: "HitPlayKit"),
        // py源宿主契约与模型；宿主脚本 py-source-host.py 随模块资源分发。
        .target(
            name: "HitPlayPySource",
            resources: [
                .copy("py-source-host.py")
            ]
        ),
        // 猫源引擎：订阅/站点编排 + 引擎进程管理 + 协议客户端 + 原生 CMS 引擎
        // （JSON/XML 直连）+ HLS 去广告；宿主脚本族（Node）随模块资源分发。
        .target(
            name: "HitPlayCatSource",
            dependencies: [
                "HitPlayKit",
                "HitPlayPySource"
            ],
            resources: [
                .copy("cat-source-host.js"),
                .copy("tvbox-js-host")
            ]
        ),
        .testTarget(
            name: "HitPlaySourceKitTests",
            dependencies: [
                "HitPlayKit",
                "HitPlayPySource",
                "HitPlayCatSource"
            ]
        )
    ]
)
