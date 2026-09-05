<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 验收记录

编译与测试在 GitHub Actions `macos-15` runner 上执行（Xcode 16.4）。命令：

```text
xcodebuild build -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild test  -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation
```

## M0 工程与协议

| 项 | 结果 |
|---|---|
| `swift build` 零警告 | `** BUILD SUCCEEDED **`，`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| `TsuyomiProtocol` 全量测试 | `Executed 29 tests, with 0 failures` / `** TEST SUCCEEDED **` |
| `reader/**` fixture | `valid-reader-locator.json`、`valid-forum-navigation.json`、`valid-thread-page-document.json` 解析成功且再序列化语义相等 |
| `transfer/**` fixture | `valid-minimal.json` 往返、`noncanonical-order.json` 导出规范化、`duplicate-book-identity.json` 拒绝、`conformance-progress-conflict.json` 四条用例逐条断言 |
| `SmartRule` 违规码 | `empty-group`、`invalid-term-count`、`invalid-rating-range`、`invalid-time-window`、`invalid-text-length`、`max-depth`、`max-nodes` 与 Android 一致 |
| `hxp/**` fixture | 归属类型在 M2，见 `docs/DECISIONS.md` |
| 反向 import 编译失败验证 | 待 M1（当前只有 `TsuyomiProtocol` 一个目标，尚无可反向的依赖边） |
| 模拟器冷启动 | 待 App target 建立（M1） |
