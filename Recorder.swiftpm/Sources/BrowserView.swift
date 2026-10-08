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
            const viewport = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
            viewport.name = 'viewport';
            viewport.content = 'width=device-width, initial-scale=1.0';
            if (!viewport.parentNode) document.head.appendChild(viewport);
            const style = document.createElement('style');
            style.textContent = `
                body:has(:is(#page-bbs-community, #page-bbs-link)) #app > nav,
                #page-bbs-community > .bbs-community__search-module { display:none!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link)) { min-width:0!important; margin:0!important; }
                    body:has(:is(#page-bbs-community, #page-bbs-link)) #app { min-width:0!important; width:100%!important; }
                    body:has(:is(#page-bbs-community, #page-bbs-link)) #app > main { padding:0!important; }
                    :is(#page-bbs-community, #page-bbs-link) { width:100%!important; max-width:720px!important; margin:0 auto!important; padding:0!important; }
                    :is(#page-bbs-community, #page-bbs-link) > .content { display:block!important; }
                    :is(#page-bbs-community, #page-bbs-link) > .content > .list { width:100%!important; min-width:0!important; }
                    :is(#page-bbs-community, #page-bbs-link) > .content > .right { display:none!important; }
                    #page-bbs-community .bbs-home__topic-list-wrapper { padding:12px 0!important; }
                    #page-bbs-community .hb-cpt__pagination-outer { overflow-x:auto!important; }
                    #page-bbs-community .hb-cpt__pagination-inner { width:max-content!important; transform:none!important; }
                    #page-bbs-community .hb-cpt__pagination--right,
                    #page-bbs-community .hb-cpt__pagination--left { display:none!important; }
                    #page-bbs-community .bbs-home__content-item { padding:16px!important; }
                    #page-bbs-community .bbs-content__title { font-size:17px!important; line-height:1.5!important; }
                    #page-bbs-community .bbs-content__imgs-wrapper { display:flex!important; gap:6px; height:auto!important; overflow:hidden; }
                    #page-bbs-community .bbs-content__image { position:relative!important; inset:auto!important; width:auto!important; height:auto!important; flex:1 1 0; min-width:0; aspect-ratio:1; }
                    #page-bbs-community .bbs-content__video_wrapper { max-width:100%!important; }
                    #page-bbs-link .hb-bbs-link { width:100%!important; box-sizing:border-box!important; }
                    #page-bbs-link .hb-bbs-link img { max-width:100%!important; }
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
        refresh(); notice = "网页进程已退出，请刷新页面；录制状态可在设置中查看。"
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
    @ObservedObject var browser: RecorderBrowser
    let settings: () -> Void
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("畅游").font(.headline)
                TextField("搜索内容或输入网址", text: $searchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($searchFocused)
                    .onSubmit(submitSearch)
                    .padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("网页搜索或网址")
                Button(action: submitSearch) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                    .accessibilityLabel("搜索或打开网址")
                Button(action: settings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .accessibilityLabel("设置")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .background(Color(white: 0.08))
            if browser.loading { ProgressView().progressViewStyle(.linear).tint(.gray) }
            if let notice = browser.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("关闭") { browser.notice = nil }.frame(minHeight: 44)
                }.padding(.horizontal, 12).background(Color(white: 0.15))
            }
            RecorderWebPage(browser: browser)
            HStack(spacing: 16) {
                Button(action: browser.home) { Image(systemName: "house").frame(width: 44, height: 44) }
                    .accessibilityLabel("社区首页")
                Button(action: browser.back) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!browser.canGoBack).accessibilityLabel("上一页")
                Button(action: browser.forward) { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(!browser.canGoForward).accessibilityLabel("下一页")
                Spacer()
                Text(browser.siteLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(action: browser.reloadOrStop) {
                    Image(systemName: browser.loading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel(browser.loading ? "停止加载网页" : "刷新网页")
            }.padding(.horizontal, 12).background(Color(white: 0.08))
        }
        .background(Color.black).foregroundStyle(.white)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear { browser.startIfNeeded() }
        .onDisappear { browser.pauseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            browser.pauseMedia()
        }
    }

    private func submitSearch() {
        searchFocused = false
        browser.search(searchText)
    }
}
