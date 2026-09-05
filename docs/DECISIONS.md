<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# 决策记录

本文件只记录 `IOS_PORT_PROMPT.md` 未覆盖的决策，一行一条。

## M0

- SHA-256 由 `TsuyomiProtocol/Sha256.swift` 提供纯 Swift 实现并被所有上层复用；`TsuyomiProtocol` 被禁止 import CryptoKit，重复实现违反反冗余规则。
- JSON 统一走 `Codable`；需要严格未知字段拒绝或宽松遗留解析处，`init(from:)` 先解码到 `JSONValue`（本身是 `Codable`）再手写校验。
- `JSONValue` 编码固定 `[.sortedKeys, .withoutEscapingSlashes]`，使规范化输出与摘要在同一平台上确定。
- `ReaderDocument` 采用 `reader-document-v1` schema 形状（`kind`/`identity`/`contentDigest`），而非 Android 运行时的扁平中间形状；扁平形状是扩展宿主边界，由 `TsuyomiSource` 在 M2 转换。
- `ReaderBlock` 的文本上限取 schema 值（paragraph/quote 65536、heading 16384），Android 内存模型的 100000 更宽，不采用。
- `SourceNetworkRequest` 不含 `query`/`queryEncoding`；与 Android 一致，结构化 query 的百分号编码属于 `TsuyomiSource` 的 `SourceExtensionClient` 边界。
- 协议时间戳解析接受 RFC 3339 偏移与小数秒，但在解析时截断到整秒，保证"解析→再序列化"字节稳定。
- 字符串排序统一用 UTF-16 码元序（`CanonicalOrder`），与 Kotlin `String.compareTo` 一致，保证两端导出顺序相同。
- `TransferCodec.encodeBounded` 用"整体编码后比较长度"替代 Android 的流式截断；语义（超限返回 `nil`）相同，避免第二套编码器。
- `ImportPlan` 不含 `forceManualEInk`，Hikari 的 `browsingEInkMode`/`readerEInkMode` 不读取：iOS 无 E-ink profile（第 4 节），无消费者的字段不保留。
- Hikari 凭据字段扫描按规范化键名排序遍历，使警告 ordinal 在 Swift 字典无序的前提下确定。
- `tsuyomi-protocol/fixtures/hxp/**` 的用例在 M2 由其归属类型（`HxpManifestParser`、`SourceExtensionClient`）覆盖，M0 只覆盖 `reader/**` 与 `transfer/**`。

## M1

- `TsuyomiCore` 的 `LibraryRepository` 同时是 `books/library_entries/local_book_tags/history` 的 SQL 归属，不再另设只做转发的 `LibraryCatalogStore` 门面（反冗余规则禁止透传层）。
- `ReaderSettings`、`ReaderPresentation`、`ReaderTheme` 定义在 `TsuyomiCore/Preferences`（持久化它们的层），`TsuyomiReader` 从下层引用；反向会破坏 Package 的依赖方向。
- POST 表单体按键名排序序列化，使字节体在 Swift 字典无序的前提下确定；远端写策略按字典比较参数，与顺序无关。
- `URLSessionHostHttpTransport` 在会话级 delegate 中按 16 MiB 协议上限预检 `Content-Length`，每个授权的更小上限由 `HostNetworkGateway` 二次执行。
- `KeychainAesGcm` 的密钥在模拟器单元测试中不可用（无 keychain 授权），生产实现由集成路径覆盖；单元测试用内存 `AeadPort`。

## M2

- vendored QuickJS-ng 的实际文件集为 `dtoa.c libregexp.c libunicode.c quickjs.c`（0.16.1 无 `cutils.c`，`cutils.h` 为头文件实现），与 Android `CMakeLists.txt` 一致。
- `tsuyomi_qjs_prepare_operation` 每次调用 `JS_UpdateStackTop`，使 actor 串行执行器在不同线程上连续执行时栈上限判定仍然正确；因此不再固定专用线程。
- 桥接新增 `IMPORT_DISALLOWED` 状态并安装拒绝一切说明符的模块加载器（Android JNI 未安装加载器）。
