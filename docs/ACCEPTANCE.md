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
| 拒绝输入 | `RepositoryIndexTests` 全绿：HTTP 目录地址 / 带 query 的地址 / 非 32 字节根公钥、过期目录、超过 30 天有效期、错误签名或错误根公钥、HTTP 下载地址（另加带凭据 / 片段 / 空格的 URL）、未列出的发布者、`sha256` 不匹配、发布者与 manifest 不一致、版本回滚 |
| 目录格式 | `tsuyomi-repository` v1（与 `tsuyomi-extensions` 线上一致）：根密钥 Ed25519 签名（`"tsuyomi-repository-v1"` 加 NUL 再接 RFC 8785(`signed`)），目录列出发布者公钥，撤销按发布者指纹与归档 SHA-256，刷新拒绝更低的 `sequence` |
| 内置官方仓库 | `OfficialRepository`：`OfficialRepositoryTests` 用内置根公钥验签已发布的目录快照（`Fixtures/official-index-v1-sequence-1.json`），换一把密钥即失败；`OfficialRepositorySeedTests` 断言首次启动预添加仓库与 `builtInOfficial` 发布者，且移除后下次启动不再回填 |
| 官方包准入 | `CapabilityAdmissionTests`：官方 Wenku8 0.2.31 的能力声明（`updateCheck`、`targets`/`remove`/`move` policy、GET 的 `add`）被接受；非 GET 或越界 origin 的 `updateCheck`、无 `targetId` 的 `move`、GET 的 `remove`、未授予操作的 policy 全部拒绝 |
| 五个屏幕 | `extensions`、`extensionRepository`、`extensionPackage`、`extensionInstallReview`、`publisherKeys` 全部可达（来源列表顶栏进入）；添加仓库输入协议规定的订阅链接（协议 `subscription-link-cases.json` 合法/非法向量全部按规范判定），仓库详情页可逐个信任目录新增的发布者 |
| 协议向量 | `valid-catalog.json` 在 `fixture-root-key.json` 下验签通过；`invalid-catalog-duplicate-key`/`unknown-field` 被拒；等序号不同内容 `INDEX_EQUIVOCATION`；用户根携带 `legacyMigration` 的目录 `UNAUTHORIZED_MIGRATION`；移除后以不同根重添同一标识 `REPOSITORY_IDENTITY_MISMATCH`；卸载后发布者钉住仍拒绝换发布者、命中迁移才放行 |
| 端到端 | `MarketJourneyTests`：假 HTTPS 主机（只服务 index-v1.json/*.hxp，其余 404）→ 添加仓库并确认根密钥与发布者 → 从缓存读到目录 → 安装 → 目录升到 99.0.0 → 状态变可更新 → 更新 → 目录带撤销 → 已装包停止验签、来源置为不可用；更低 `sequence` 的目录被拒（`INDEX_ROLLBACK`）；换发布者的包先因未信任被拒、信任后因未授权轮换被拒、目录带 `legacyMigration` 后才可更新；另一条断言移除仓库后已装扩展与发布者信任都还在 |

## M6 设置与打磨 — 进行中

| 项 | 结果 |
|---|---|
| 设置屏 | 显示（外观，无 profile）、阅读器设置（排版/翻页/导航分组，与阅读器内同一份控件与同一份存储）、数据（明写迁移含与不含项）、帮助（可搜索折叠）、关于（许可证全文）|
| 文档 | `docs/OPTION_APPLICABILITY_IOS.md` 逐项记录可见性判定；`THIRD_PARTY_NOTICES.md` 记录 QuickJS-ng 与源码摘要；README 重写 |
| Reduce Motion | 插入位让位与快捷栏收折在 Reduce Motion 下降级为无动画切换 |
| `NSUserActivity` | 阅读页发布活动（只含书与章，不含进度，不参与 Handoff），根视图接管续读并切到浏览 tab |
| VoiceOver | 装饰性图标全部隐藏；选中态用 `.isSelected` trait 表达而非朗读勾图标；封面、筛选、分页、阅读进度均有标签与值 |
| 纪律回归 | `RepositoryHygieneTests` 5 条：SPDX 头、无 TODO / `@unchecked` / `try!` / `swiftlint:disable` / `#if false`、无 iOS 17 API、无 E-ink 残留符号、无 Kotlin 提交 |
| 尚未完成 | Dynamic Type `.accessibility3` 与深浅色的模拟器人工截图核对（需真机/模拟器目视，CI 不覆盖）|

## 未完成项

| 项 | 原因 |
|---|---|
| 上游 2026-09-04 → 09-12 的协议增量：`tsuyomi-transfer` v2/v3（完读章节、本地钉住状态、更多阅读器偏好）、作者搜索入口、`update-check-v2` 解析器模型 | 需要先决定 iOS 数据模型是否引入章节完读与"保留未钉住记录"；4C 更新协调中心按规范不在范围 |
| 上游 Phase 4B/4C 产品改动（远端 REMOVE/MOVE 与目标发现、网站书库镜像、更新收件箱与调度、本地书架搜索、Room v10 钉住/保留分离、Detail 六行布局与作者链接、书架筛选面板） | 规范第 84 行明确 4B/4C 不在范围；其余为产品决策，待用户圈定 |
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

## 上游同步 S1–S6（Xfire233/Tsuyomi@c704480 + tsuyomi-extensions@1d7062e）— 通过（S6 界面待用户把关）

CI run 35094873410：`** BUILD SUCCEEDED **`（`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`，Swift 6 严格并发）、`Test Suite 'All tests' passed`，213 个用例全部通过。

| 项 | 结果 |
|---|---|
| S2 数据库 | `user_version = 10`，Room v5–v10 全部表存在；镜像快照要求租约不变且从不钉住；对账状态机；移除只解钉且保留标签/进度；章节完读精确且先到先得；v4 库就地迁移 |
| S3 来源运行时 | READ/TARGETS/ADD/REMOVE/MOVE/UPDATE_CHECK 逐操作签名策略与受保护写面；`update-check-v2` 准入（基线、追加、重排/截断不重置、错书失败）；transfer v2/v3 严格解析 |
| S4 扩展生命周期 | 非官方包无授权即拒绝（`PACKAGE_GRANT_REQUIRED`）；未知发布者本地包要公钥、错钥不留痕、审批拒绝不留钥；卸载一次休眠且不抖动代号；官方仓库只停用不移除；复合解析器层级与撤销并集 |
| S5a 网站书架 | 拉取入镜像不钉住、目录与归属正确、分组不移动数据；复制每来源只问一次且零远程写；ADD 需授权、只发一次、被记住；接受后失败留 UNRESOLVED 并阻塞，重试关闭整链；`仅解除锁定` 不对 ADD；定向 ADD→MOVE 两次请求；未登录零请求 |
| S5b 更新检查 | 首检静默基线，追加章节入收件箱（`10003`，`2026-09-07`）；全部完读才消失；忽略可撤销且不写进度；排除按书/按来源；镜像书在候选内；会话不重叠、取消持久 |
| S5c 书架 | 智能排序分区规则、本地搜索规范化与顺序、推荐顺序、分段默认展示、`mirror:` 快捷入口 |
| S6 界面 | `InterfaceSnapshotTests` 产出 18 张截图（浏览已安装/可安装、仓库确认、安装审批、发布者公钥、书架有更新、镜像根、详情身份模块、更新设置/报告）；交用户把关 |
