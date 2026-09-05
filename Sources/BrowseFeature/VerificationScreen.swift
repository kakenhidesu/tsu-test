// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI
import WebKit

public struct BlockedNavigation: Sendable {
    public let url: URL
    public let reason: WebNavigationBlock

    var explanation: String {
        switch reason {
        case .plaintextAccepted:
            return "\(url.host ?? "该站点") 把这一页放在 http 上。页面已放行，但你在其中输入的内容"
                + "与随后保存的登录态都以明文经过网络，请只在你能接受这一点时继续。"
        case .originNotDeclared:
            return "已拦截前往 \(url.host ?? "该地址") 的跳转：它不在该来源声明的站点范围内。"
        }
    }

    var isRefusal: Bool { reason == .originNotDeclared }
}

/// The user completes a login or a site challenge here by hand. The host never scripts the page,
/// never solves a challenge, and writes nothing remotely; closing the sheet stores nothing.
@MainActor
public final class VerificationModel: ObservableObject {
    @Published public private(set) var webView: WKWebView?
    @Published public private(set) var failure: String?
    @Published public private(set) var blocked: BlockedNavigation?
    @Published public private(set) var isFinished = false

    private let sourceId: String
    private let origins: Set<HttpsOrigin>
    private let initialUrl: String
    private let userAgent: String
    private let sessions: VerifiedBrowserSessionStore
    private var session: ControlledWebLoginSession?

    public init(
        sourceId: String,
        origins: Set<HttpsOrigin>,
        initialUrl: String,
        userAgent: String,
        sessions: VerifiedBrowserSessionStore
    ) {
        self.sourceId = sourceId
        self.origins = origins
        self.initialUrl = initialUrl
        self.userAgent = userAgent
        self.sessions = sessions
    }

    public func start() async {
        guard session == nil else { return }
        do {
            let opened = try ControlledWebLoginSession(
                sourceId: sourceId,
                allowedOrigins: origins,
                sessions: sessions,
                onBlockedNavigation: { [weak self] url, reason in
                    Task { @MainActor in self?.blocked = BlockedNavigation(url: url, reason: reason) }
                }
            )
            session = opened
            webView = try await opened.open(initialUrl: initialUrl, userAgent: userAgent)
        } catch {
            failure = SafeWebCode.of(error)
        }
    }

    /// The only path that stores anything. It runs on an explicit user action, never on dismissal.
    public func finish() async {
        guard let session else { return }
        do {
            try await session.finish()
            isFinished = true
        } catch {
            failure = SafeWebCode.of(error)
        }
    }

    public func cancel() async {
        await session?.cancel()
        isFinished = true
    }
}

enum SafeWebCode {
    static func of(_ error: any Error) -> String {
        guard let failure = error as? WebLoginSessionError else { return "UNEXPECTED_FAILURE" }
        switch failure {
        case .alreadyActive: return "SESSION_ALREADY_ACTIVE"
        case .notActive: return "SESSION_NOT_ACTIVE"
        case .originNotDeclared: return "ORIGIN_NOT_DECLARED"
        case .emptyCapture: return "EMPTY_CAPTURE"
        case .noSettledPage: return "NO_SETTLED_PAGE"
        }
    }
}

public struct VerificationScreen: View {
    @ObservedObject private var model: VerificationModel
    private let onClose: () -> Void

    public init(model: VerificationModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            notice
            StateView(state) { WebViewContainer(webView: $0) }
        }
        .navigationTitle("站点验证")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { Task { await model.cancel(); onClose() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("我已完成") { Task { await model.finish(); onClose() } }
                    .disabled(model.webView == nil)
            }
        }
        .task { await model.start() }
    }

    private var state: TsuyomiScreenState<WKWebView> {
        if let webView = model.webView { return .content(webView) }
        if let failure = model.failure { return .failed(code: failure, detail: "无法打开受控浏览器。") }
        return .loading
    }

    @ViewBuilder
    private var notice: some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            Text("请在下面自行完成登录或人工验证。应用不会替你点击、填写或绕过任何验证。")
            if let blocked = model.blocked {
                Text(blocked.explanation)
                    .foregroundStyle(
                        blocked.isRefusal ? TsuyomiTheme.Palette.warning : TsuyomiTheme.Palette.danger
                    )
            }
        }
        .font(TsuyomiTheme.Typography.caption)
        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TsuyomiTheme.Metrics.gutter)
        .background(TsuyomiTheme.Palette.raisedSurface)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
