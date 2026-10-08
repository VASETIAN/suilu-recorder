import SwiftUI
import WebKit

@MainActor
final class RecorderBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var notice: String?
    @Published var siteLabel = "小黑盒官方网页"
    @Published var isCommunityPage = true
    @Published var isVideoPage = false

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
                #page-bbs-community::before, #page-bbs-community::after,
                #page-bbs-community .list::before, #page-bbs-community .list::after { content:none!important; display:none!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link)) { min-width:0!important; margin:0!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link)) #app { min-width:0!important; width:100%!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link)) #app > main { padding:0!important; }
                :is(#page-bbs-community, #page-bbs-link) { width:100%!important; max-width:720px!important; margin:0 auto!important; padding:0!important; }
                :is(#page-bbs-community, #page-bbs-link) > .content { display:block!important; }
                :is(#page-bbs-community, #page-bbs-link) > .content > .list { width:100%!important; min-width:0!important; }
                :is(#page-bbs-community, #page-bbs-link) > .content > .right { display:none!important; }
                #page-bbs-community .hb-bbs-home { padding:0!important; }
                #page-bbs-community .bbs-home__topic-list-wrapper { padding:8px 12px!important; margin-bottom:0!important; }
                #page-bbs-community .bbs-home__topic-list { height:auto!important; padding:4px 0 8px!important; }
                #page-bbs-community .bbs-home__topic-item { width:66px!important; }
                #page-bbs-community .bbs-home__topic-item-icon { width:36px!important; height:36px!important; border-radius:8px!important; }
                #page-bbs-community .hb-cpt__pagination-outer { overflow-x:auto!important; }
                #page-bbs-community .hb-cpt__pagination-inner { width:max-content!important; transform:none!important; }
                #page-bbs-community .hb-cpt__pagination--right,
                #page-bbs-community .hb-cpt__pagination--left { display:none!important; }
                #page-bbs-community .hb-bbs-home__splitline::after,
                #page-bbs-community .hb-bbs-home__feed-splitline::after { left:0!important; width:100%!important; }
                #page-bbs-community .bbs-home__content-list { padding:0!important; }
                #page-bbs-community .bbs-home__content-item { padding:0!important; }
                #page-bbs-community .hb-cpt__bbs-list-content { padding:14px 16px!important; }
                #page-bbs-community .bbs-content__title { font-size:17px!important; line-height:1.5!important; }
                #page-bbs-community .bbs-content__imgs-wrapper { display:grid!important; grid-template-columns:repeat(3,minmax(0,1fr)); gap:6px; height:auto!important; overflow:hidden; }
                #page-bbs-community .bbs-content__imgs-wrapper:not(:has(> .bbs-content__image ~ .bbs-content__image)) { grid-template-columns:minmax(0,1fr); }
                #page-bbs-community .bbs-content__imgs-wrapper:has(> .bbs-content__image:nth-child(2)):not(:has(> .bbs-content__image:nth-child(3))) { grid-template-columns:repeat(2,minmax(0,1fr)); }
                #page-bbs-community .bbs-content__image { position:relative!important; inset:auto!important; width:100%!important; height:auto!important; min-width:0; min-height:0; aspect-ratio:1; overflow:hidden; }
                #page-bbs-community .bbs-content__imgs-wrapper:not(:has(> .bbs-content__image ~ .bbs-content__image)) > .bbs-content__image { aspect-ratio:4/3; }
                #page-bbs-community .bbs-content__image > .hb-cpt__image-elem { position:absolute!important; inset:0!important; width:100%!important; height:100%!important; object-fit:cover!important; }
                #page-bbs-community .bbs-content__image-cnt { left:auto!important; right:6px!important; top:6px!important; z-index:1; }
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
        view.scrollView.contentInsetAdjustmentBehavior = .never
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
    func videos() { open(BrowserAddress.videos) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reloadOrStop() { if loading { webView.stopLoading(); refresh() } else { webView.reload() } }
    func pauseMedia() { webView.pauseAllMediaPlayback() }

    private func refresh() {
        loading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let host = webView.url?.host {
            let official = ["www.xiaoheihe.cn", "xiaoheihe.cn"].contains(host)
            siteLabel = official ? "小黑盒官方网页" : host
            isCommunityPage = official && webView.url?.path.hasPrefix("/app/bbs/") == true
            isVideoPage = host == "douyin.com" || host.hasSuffix(".douyin.com")
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
            HStack(spacing: 10) {
                Text("畅游").font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
                    TextField("搜索或输入网址", text: $searchText)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searchFocused)
                        .onSubmit(submitSearch).accessibilityLabel("网页搜索或网址")
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Color(white: 0.95), in: Capsule())
                Menu {
                    Text(browser.siteLabel)
                    Button(action: browser.back) { Label("返回上一页", systemImage: "chevron.left") }.disabled(!browser.canGoBack)
                    Button(action: browser.forward) { Label("前进一页", systemImage: "chevron.right") }.disabled(!browser.canGoForward)
                    Button(action: browser.reloadOrStop) { Label(browser.loading ? "停止加载" : "刷新网页", systemImage: "arrow.clockwise") }
                    Button(action: browser.home) { Label("回到社区首页", systemImage: "house") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("网页导航菜单")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            if !browser.isCommunityPage {
                Text(browser.siteLabel).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.horizontal, 16).padding(.bottom, 6)
            }
            Divider()
            if browser.loading { ProgressView().progressViewStyle(.linear).tint(.gray) }
            if let notice = browser.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("关闭") { browser.notice = nil }.frame(minHeight: 44)
                }.padding(.horizontal, 16).background(Color(white: 0.95))
            }
            RecorderWebPage(browser: browser).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 0) {
                tab("社区", symbol: "square.grid.2x2", selected: browser.isCommunityPage, action: browser.home)
                tab("视频", symbol: "play.rectangle", selected: browser.isVideoPage, action: browser.videos)
                tab("设置", symbol: "gearshape", selected: false, action: settings)
            }.padding(.vertical, 6)
        }
        .background(Color.white.ignoresSafeArea()).foregroundStyle(Color(white: 0.12)).tint(Color(white: 0.12))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear { browser.startIfNeeded() }
        .onDisappear { browser.pauseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            browser.pauseMedia()
        }
    }

    private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 21, weight: selected ? .semibold : .regular))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            .foregroundStyle(selected ? Color(white: 0.12) : Color(white: 0.5))
        }.buttonStyle(.plain)
    }

    private func submitSearch() {
        searchFocused = false
        browser.search(searchText)
    }
}
