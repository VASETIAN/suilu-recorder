import SwiftUI
import WebKit

@MainActor
final class RecorderBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var notice: String?
    @Published var siteLabel = "小黑盒官方网页"

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsPictureInPictureMediaPlayback = false
        // ponytail: these public page selectors follow the current website;
        // update the small CSS adapter if its layout changes, not its private API.
        let mobileCommunity = """
        if (location.hostname === 'www.xiaoheihe.cn' || location.hostname === 'xiaoheihe.cn') {
            const style = document.createElement('style');
            style.textContent = `
                body:has(#page-bbs-community) #app > nav,
                #page-bbs-community > .bbs-community__search-module { display:none!important; }
                @media (max-width:700px) {
                    body:has(#page-bbs-community) #app { min-width:0!important; width:100%!important; }
                    body:has(#page-bbs-community) #app > main { padding:0!important; }
                    #page-bbs-community { width:100%!important; margin:0!important; padding:0!important; }
                    #page-bbs-community > .content { display:block!important; }
                    #page-bbs-community > .content > .list { width:100%!important; min-width:0!important; }
                    #page-bbs-community > .content > .right { display:none!important; }
                }
            `;
            document.documentElement.appendChild(style);
        }
        """
        configuration.userContentController.addUserScript(WKUserScript(
            source: mobileCommunity, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    func startIfNeeded() { if webView.url == nil { open(BrowserAddress.community) } }
    func open(_ url: URL) {
        guard BrowserAddress.allows(url) else { notice = "只能打开网页网址。"; return }
        notice = nil
        webView.load(URLRequest(url: url))
    }
    func search(_ text: String) {
        guard let url = BrowserAddress.destination(text) else {
            notice = "请输入搜索内容或有效的 http／https 网址。"; return
        }
        open(url)
    }
    func home() { open(BrowserAddress.community) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reloadOrStop() { if loading { webView.stopLoading(); refresh() } else { webView.reload() } }
    func pauseMedia() { webView.pauseAllMediaPlayback() }

    private func refresh() {
        loading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let host = webView.url?.host {
            siteLabel = ["www.xiaoheihe.cn", "xiaoheihe.cn"].contains(host) ? "小黑盒官方网页" : host
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        notice = nil; refresh()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        refresh()
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        notice = "网页未能加载：\(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        refresh(); notice = "网页进程已退出，请刷新页面；相机状态见上方。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, BrowserAddress.allows(url) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                notice = "此链接要打开其他 App，浏览模式仅打开网页。"
            }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    // Links that request a new window stay in this single web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { open(url) }
        return nil
    }
    // Websites cannot take the recorder's camera or microphone permission.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

@MainActor
private struct RecorderWebPage: UIViewRepresentable {
    let browser: RecorderBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor
struct BrowserView: View {
    @ObservedObject var recorder: RecorderController
    @ObservedObject var browser: RecorderBrowser
    let capture: () -> Void
    let settings: () -> Void
    let library: () -> Void
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("畅游 · 浏览").font(.headline)
                    Spacer(minLength: 4)
                    Button { browser.pauseMedia(); recorder.setInterfaceMode(.camera) } label: {
                        Image(systemName: "camera.fill").frame(width: 44, height: 44)
                    }.disabled(!canChangeInterface).accessibilityLabel("返回相机界面")
                    Button(action: library) { Image(systemName: "photo.on.rectangle").frame(width: 44, height: 44) }
                        .disabled(!recorder.canConfigure).accessibilityLabel("内置图库")
                    Button(action: settings) { Image(systemName: "gearshape.fill").frame(width: 44, height: 44) }
                        .disabled(!recorder.canConfigure).accessibilityLabel("拍摄设置")
                }
                HStack(spacing: 10) {
                    if recorder.phase == .recording {
                        Label("REC", systemImage: "record.circle.fill").foregroundStyle(.red).font(.headline)
                        Text(recorder.elapsedLabel).monospacedDigit().font(.headline)
                    } else {
                        Text(recorder.phase == .idle ? recorder.status : recorder.phase.title)
                            .font(.subheadline).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(action: capture) {
                        Label(recorder.phase == .recording ? "停止" : "录像",
                              systemImage: recorder.phase == .recording ? "stop.fill" : "record.circle")
                            .font(.headline).frame(minHeight: 44)
                            .padding(.horizontal, 12).background(.red, in: Capsule())
                    }
                    .disabled(!(recorder.canRecord || recorder.phase == .recording))
                    .accessibilityLabel(recorder.phase == .recording ? "停止录像并保存" : "开始录像")
                }
                HStack {
                    Text(recorder.settings.mode.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("剩余 \(RecorderFiles.sizeLabel(recorder.availableSpace))").lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
                if let warning = recorder.captureLoad.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button(action: browser.home) { Image(systemName: "house.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("小黑盒官方主页")
                    TextField("搜索内容或输入网址", text: $searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searchFocused)
                        .onSubmit(submitSearch)
                        .padding(10).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("网页搜索或网址")
                    Button(action: submitSearch) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel("搜索或打开网址")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .background(Color.black)
            if browser.loading { ProgressView().progressViewStyle(.linear).tint(.red) }
            if let notice = browser.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("关闭") { browser.notice = nil }.frame(minHeight: 44)
                }.padding(.horizontal, 12).background(Color(white: 0.15))
            }
            RecorderWebPage(browser: browser)
            HStack(spacing: 24) {
                Button(action: browser.back) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!browser.canGoBack).accessibilityLabel("上一页")
                Button(action: browser.forward) { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(!browser.canGoForward).accessibilityLabel("下一页")
                Spacer()
                Text(browser.siteLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(action: browser.reloadOrStop) {
                    Image(systemName: browser.loading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel(browser.loading ? "停止加载网页" : "刷新网页")
            }.padding(.horizontal, 12).background(Color.black)
        }
        .background(Color.black).foregroundStyle(.white)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear { browser.startIfNeeded() }
        .onDisappear { browser.pauseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            browser.pauseMedia()
        }
    }

    private var canChangeInterface: Bool {
        !recorder.isConfiguring && (recorder.phase == .idle || recorder.phase == .recording)
    }
    private func submitSearch() {
        searchFocused = false
        browser.search(searchText)
    }
}
