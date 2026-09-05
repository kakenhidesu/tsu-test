<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 验收记录

编译与测试在 GitHub Actions `macos-15` runner 上执行（Xcode 16.4，iPhone 模拟器）。命令：

```text
xcodebuild build -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild test  -scheme Tsuyomi -destination "id=<iPhone simulator>" -skipMacroValidation
```

## M0 工程与协议 — 通过

| 项 | 结果 |
|---|---|
| 零警告构建 | `** BUILD SUCCEEDED **`，`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| `TsuyomiProtocol` 测试 | `Executed 29 tests, with 0 failures` |
| `reader/**` fixture | `valid-reader-locator.json`、`valid-forum-navigation.json`、`valid-thread-page-document.json` 解析成功且再序列化语义相等 |
| `transfer/**` fixture | `valid-minimal.json` 往返、`noncanonical-order.json` 导出规范化、`duplicate-book-identity.json` 拒绝、`conformance-progress-conflict.json` 四条用例逐条断言 |
| `SmartRule` 违规码 | `empty-group`、`invalid-term-count`、`invalid-rating-range`、`invalid-time-window`、`invalid-text-length`、`max-depth`、`max-nodes` 与 Android 一致 |

## M1 宿主基础 — 通过

| 项 | 结果 |
|---|---|
| `TsuyomiCore` 测试 | `Executed 45 tests, with 0 failures` / `** TEST SUCCEEDED **` |
| 网络策略 | 未授权 origin、Cookie 头、重定向到未声明 origin、响应上限、gb18030 解码、POST 不入缓存与 64 KiB 体上限、按扩展版本分区的缓存与 Cookie 隔离 |
| 远端写面 | direct-action 令牌单次生效、拒绝时零传输、通用上下文无法到达签名 add 面、字面量/游标/声明重定向逐条校验 |
| 存储与凭据 | 路径遍历拒绝、持久根拒绝为写入牺牲已有数据、cache 根 LRU、AAD 绑定 source/origin、损坏记录就地作废 |
| 数据库 | `user_version = 4` 与 15 张表逐一存在、外键级联、`display_order` 重排幂等且要求全集、进度冲突（更新者胜/等值保留）、智能书架编译为参数化查询并命中预期集合、远端合并租约、导出→导入逐字段相等 |

## M2 扩展运行时 — 通过

| 项 | 结果 |
|---|---|
| `TsuyomiSource` 测试 | `Executed 22 tests, with 0 failures`（QuickJS 8 + HXP 校验 8 + wenku8 回放 6），另加 `package-policy-cases` 表驱动用例 |
| QuickJS-ng 0.16.1 | 作为 `CQuickJS` C target 内嵌并在 iOS 模拟器上构建通过；源码 SHA-256 见 `Sources/CQuickJS/quickjs-ng/UPSTREAM.md` |
| 运行时上限 | 死循环在 300 ms 墙钟内被中断、内存上限触发、栈深受限、取消后 context 丢弃并由已验证模块重建、`import` 被模块加载器拒绝、非 JSON 返回与缺失函数是不同错误 |
| `wenku8-fixture.hxp` | 校验通过（发布者指纹、`integrity.files`、RFC 8785 `contentDigest`、Ed25519 签名）；翻转一个字节后拒绝；未知/已撤销发布者、已撤销包摘要、不兼容 hostApi 各自拒绝 |
| HTML 回放 | search/detail/directory/chapter 的字段值与 `tsuyomi-extensions/test/wenku8.test.mjs` 的断言一致；challenge 页转为类型化 `SourceException` 且诊断不含原始 HTML；远端书架读取零 POST、零请求体 |
| 更新策略 | `package-policy-cases.json` 七条用例全部通过（无能力增长接受、新增 webLogin/home 需授权、已撤销先于版本判定、已确认轮换接受、未确认换钥拒绝、回滚拒绝） |

## M3 阅读闭环 — 进行中

| 项 | 结果 |
|---|---|
| reader engine | `Executed 10 tests`：精确/降级/邻近锚点解析、三种呈现共享同一 locator、capture 只推进时钟、降级捕获不顶替精确捕获、快照必须自证溯源、切换事务只接受自己的当前见证、陈旧代取消、文档缓存 LRU |
| TextKit 2 分页 | 页面计划恰好划分排版文本（无重叠、无空隙、末页对齐存储长度）；除末页外每页不超过视口高度；字号变更产生新 layout key 且语义位置仍可解析；仅换主题不改变 layout key；星际字符的码点/UTF-16 偏移换算正确 |
| 受控 WebView | 导航溯源测试 7 条：宿主发起的加载落定并绑定、观察到的服务端重定向保留请求溯源、用户手势导航作废绑定、无显式请求时不绑定、Cookie 主机匹配跟随声明 origin |
| 端到端旅程 | `SourceJourneyTests`：装签名 fixture 扩展 → 搜索（写入 `search_history`）→ 详情+目录 → `加入书架`（断言远端写入计数为 0）→ 打开章节 → flush 得到带 `blockId` 与 `textAnchorDigest` 的精确 locator → 跨到相邻章 → 以全新 model 重读详情，续读章节与已读章节集合正确；另一条断言 challenge 页只产出稳定错误码，不含 HTML 或站点名 |
| Xcode App target | `App/Tsuyomi.xcodeproj` 通过本地 SPM 包依赖 `TsuyomiApp`；CI 单独一步在模拟器上构建该 target |

## M4 书架与迁移 — 已交付

| 项 | 结果 |
|---|---|
| 三布局 | 网格三列 / 列表 / 紧凑；长按进入多选，选择栏含计数、全选、清空、批量移入收藏夹、本地删除 |
| 拖拽 | 书拖到书建收藏夹；书拖入收藏夹；"排序整理"模式下拖拽落位并持久化 `display_order`，插入位让位由 `Layout` 协议实现 |
| 快捷栏 | 重排（编辑列表 + `onMove`）、锁定、内联收折（≥44pt 整宽手柄，点击或拖拽悬停展开） |
| 系统节点 | 六个节点可隐藏可恢复，隐藏集合持久化到偏好 |
| 收藏夹与智能规则 | 真实控件（组合子、谓词类型、取反、词条/天数/状态/进度），违规按 `path` 内联定位，未保存返回二次确认 |
| Transfer | 导出规范 `tsuyomi-transfer`；导入按文件内容自辨格式 → 预览计划 → 显式执行 → 报告，警告超 50 条折叠；会话写入 `import_sessions`/`import_warnings` |

## M5 扩展市场 — 已交付

| 项 | 结果 |
|---|---|
| 六条拒绝输入 | `RepositoryIndexTests` 全绿：HTTP 基址、过期索引、错误签名、`sha256` 不匹配、能力与 manifest 不一致、版本回滚；另加不安全包路径（绝对路径 / `..` / 跨主机 / 空格）|
| 索引格式 | `tsuyomi-repository` v0，Ed25519 detached 验签（`"tsuyomi-repository-v0"` 加 NUL 再接 RFC 8785 规范化）；撤销条目必须由该仓库自己的发布者密钥签名 |
| 五个屏幕 | `extensions`、`extensionRepository`、`extensionPackage`、`extensionInstallReview`、`publisherKeys` 全部可达（来源列表顶栏进入）|
| 工具 | `tools/repository/build-index.mjs`，Node 标准库，规范化函数复制自 `tsuyomi-extensions/tools/build-fixture.mjs` 并注明来源 |
| 端到端 | `MarketJourneyTests`：假 HTTPS 主机（只服务 index.json/index.sig/*.hxp，其余 404）→ 添加仓库并确认发布者 → 安装 → 索引升到 99.0.0 → 状态变可更新 → 更新 → 索引带撤销条目 → 已装包停止验签、来源置为不可用；另一条断言移除仓库后已装扩展与发布者信任都还在 |

## M6 设置与打磨 — 进行中

| 项 | 结果 |
|---|---|
| 设置屏 | 显示（外观，无 profile）、阅读器默认值（排版/翻页/导航分组）、数据（明写迁移含与不含项）、帮助（可搜索折叠）、关于（许可证全文）|
| 文档 | `docs/OPTION_APPLICABILITY_IOS.md` 逐项记录可见性判定；`THIRD_PARTY_NOTICES.md` 记录 QuickJS-ng 与源码摘要；README 重写 |
| Reduce Motion | 插入位让位与快捷栏收折在 Reduce Motion 下降级为无动画切换 |
| `NSUserActivity` | 阅读页发布活动（只含书与章，不含进度，不参与 Handoff），根视图接管续读并切到浏览 tab |
| VoiceOver | 装饰性图标全部隐藏；选中态用 `.isSelected` trait 表达而非朗读勾图标；封面、筛选、分页、阅读进度均有标签与值 |
| 纪律回归 | `RepositoryHygieneTests` 6 条：SPDX 头、400 行上限、无 TODO / `@unchecked` / `try!` / `swiftlint:disable` / `#if false`、无 iOS 17 API、无 E-ink 残留符号、无 Kotlin 提交 |
| 尚未完成 | Dynamic Type `.accessibility3` 与深浅色的模拟器人工截图核对（需真机/模拟器目视，CI 不覆盖）|

## 未完成项

| 项 | 原因 |
|---|---|
| `KeychainAesGcm` 单元测试 | 模拟器 SPM 测试无 keychain 授权；分区语义由内存 `AeadPort` 覆盖，生产实现走集成路径 |
| Dynamic Type `.accessibility3` 与深浅色目视核对 | 需要在模拟器上人工看，CI 不覆盖 |

## 反向 import 验证（M0 门，已完成）

一次性建立 `ReverseImportCheck` target（不声明任何依赖，内含 `import TsuyomiCore`）并作为 product 暴露，
使其进入 `Tsuyomi-Package` 的构建图。CI run `33966419562` 报出预期错误：

```
Sources/ReverseImportCheck/ReverseImport.swift:5:8: error: no such module 'TsuyomiCore'
```

确认 SwiftPM 强制依赖边界后该 target 已删除。第一次尝试只加 target 未加 product，目标未被构建、
CI 误报为通过——只加 target 不足以验证，必须让它进入构建图。
