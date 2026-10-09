import SwiftUI
import WebKit

@MainActor
final class RecorderBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var section: BrowserSection = .community
    @Published private(set) var currentURL: URL?
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var notice: String?
    @Published var siteLabel = "小黑盒官方网页"
    @Published var isVideoPage = false

    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private var pages: [BrowserSection: WKWebView] = [:]
    var webView: WKWebView {
        if let view = pages[section] { return view }
        let view = makeWebView()
        pages[section] = view
        return view
    }

    private func makeWebView() -> WKWebView {
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
                body:has(:is(#page-bbs-community, #page-bbs-link, #page-bbs-list)) #app > nav,
                #page-bbs-community > .bbs-community__search-module,
                #page-bbs-list > .search-wrapper { display:none!important; }
                :is(#page-bbs-community, #page-bbs-list)::before, :is(#page-bbs-community, #page-bbs-list)::after,
                :is(#page-bbs-community, #page-bbs-list) .list::before, :is(#page-bbs-community, #page-bbs-list) .list::after { content:none!important; display:none!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link, #page-bbs-list)) { min-width:0!important; margin:0!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link, #page-bbs-list)) #app { min-width:0!important; width:100%!important; }
                body:has(:is(#page-bbs-community, #page-bbs-link, #page-bbs-list)) #app > main { padding:0!important; }
                :is(#page-bbs-community, #page-bbs-link, #page-bbs-list) { width:100%!important; max-width:720px!important; margin:0 auto!important; padding:0!important; }
                :is(#page-bbs-community, #page-bbs-link, #page-bbs-list) > .content { display:block!important; }
                :is(#page-bbs-community, #page-bbs-link, #page-bbs-list) > .content > .list { width:100%!important; min-width:0!important; }
                :is(#page-bbs-community, #page-bbs-link, #page-bbs-list) > .content > .right { display:none!important; }
                #page-bbs-list .search-result__tab-header { padding:0 12px!important; overflow-x:auto!important; }
                #page-bbs-list .hb-cpt__pagination-outer { overflow-x:auto!important; }
                #page-bbs-list .hb-cpt__pagination-inner { width:max-content!important; transform:none!important; }
                #page-bbs-list .search-result__link { width:100%!important; min-width:0!important; }
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
                :is(#page-bbs-community, #page-bbs-list) .hb-cpt__bbs-list-content { padding:14px 16px!important; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__title { font-size:17px!important; line-height:1.5!important; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__imgs-wrapper { display:grid!important; grid-template-columns:repeat(3,minmax(0,1fr)); gap:6px; height:auto!important; overflow:hidden; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__imgs-wrapper:not(:has(> .bbs-content__image ~ .bbs-content__image)) { grid-template-columns:minmax(0,1fr); }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__imgs-wrapper:has(> .bbs-content__image:nth-child(2)):not(:has(> .bbs-content__image:nth-child(3))) { grid-template-columns:repeat(2,minmax(0,1fr)); }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__image { position:relative!important; inset:auto!important; width:100%!important; height:auto!important; min-width:0; min-height:0; aspect-ratio:1; overflow:hidden; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__imgs-wrapper:not(:has(> .bbs-content__image ~ .bbs-content__image)) > .bbs-content__image { aspect-ratio:4/3; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__image > .hb-cpt__image-elem { position:absolute!important; inset:0!important; width:100%!important; height:100%!important; object-fit:cover!important; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__image-cnt { left:auto!important; right:6px!important; top:6px!important; z-index:1; }
                :is(#page-bbs-community, #page-bbs-list) .bbs-content__video_wrapper { max-width:100%!important; }
                #page-bbs-link .hb-bbs-link { width:100%!important; box-sizing:border-box!important; }
                #page-bbs-link .hb-bbs-link img { max-width:100%!important; }
            `;
            document.documentElement.appendChild(style);
        }
        """
        configuration.userContentController.addUserScript(WKUserScript(
            source: mobileCommunity, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let desktopVideo = """
        if (location.hostname === 'douyin.com' || location.hostname.endsWith('.douyin.com')) {
            const viewport = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
            viewport.name = 'viewport';
            viewport.content = 'width=device-width, initial-scale=1.0';
            if (!viewport.parentNode) document.head.appendChild(viewport);
            const style = document.createElement('style');
            style.textContent = `
                @media (max-width: 1024px) {
                    html, body, #root, #dark { min-width:0!important; width:100%!important; }
                    #douyin-navigation { display:none!important; }
                    #douyin-right-container { width:100%!important; margin-left:0!important; padding-top:0!important; }
                    #douyin-header { display:none!important; }
                    #search-body-container, #search-content-area, #search-result-container { width:100%!important; min-width:0!important; }
                    #search-content-area { margin:0!important; padding:0 12px!important; }
                    #search-toolbar-container { position:sticky!important; top:0!important; width:100%!important; margin:0!important; padding:0!important; overflow-x:auto!important; }
                    #dark:has(#slidelist.recommend-slidelist) { height:100vh!important; }
                    #douyin-right-container:has(#slidelist.recommend-slidelist),
                    #douyin-right-container div:has(#slidelist.recommend-slidelist) { height:100%!important; min-height:0!important; }
                    #slidelist.recommend-slidelist [data-e2e="slideList"] { padding:0!important; min-height:0!important; }
                    .recommend-out-switch-btn { right:8px!important; top:12px!important; bottom:auto!important; transform:none!important; z-index:2; }
                    #douyin_login_comp_flat_panel { max-width:calc(100vw - 24px)!important; max-height:90vh!important; height:auto!important; overflow:auto!important; }
                    #douyin_login_comp_flat_panel_title { max-width:calc(100% - 54px)!important; font-size:18px!important; }
                    #douyin_login_landing_flat_container { width:100%!important; flex-direction:column!important; align-items:center!important; gap:24px!important; padding:16px 12px 24px!important; }
                    #douyin_login_landing_flat_container > div { margin:0!important; max-width:100%!important; }
                }
            `;
            document.documentElement.appendChild(style);
            let start = null;
            document.addEventListener('touchstart', event => {
                const target = event.target;
                start = event.touches.length === 1 && target.closest('#slidelist')
                    && !target.closest('button, a, input, textarea, [role="button"], .xgplayer-controls')
                    ? { x:event.touches[0].clientX, y:event.touches[0].clientY } : null;
            }, {passive:true});
            document.addEventListener('touchend', event => {
                const previous = start; start = null;
                if (!previous || !event.changedTouches.length) return;
                const dx = event.changedTouches[0].clientX - previous.x;
                const dy = event.changedTouches[0].clientY - previous.y;
                if (Math.abs(dy) < 80 || Math.abs(dx) > Math.abs(dy) * 0.6) return;
                const direction = dy < 0 ? 'next' : 'prev';
                const arrow = document.querySelector('[data-e2e="video-switch-' + direction + '-arrow"]');
                if (arrow && !arrow.classList.contains('disabled') && arrow.getAttribute('aria-disabled') !== 'true') arrow.click();
            }, {passive:true});
            document.addEventListener('touchcancel', () => { start = null; }, {passive:true});
        }
        """
        configuration.userContentController.addUserScript(WKUserScript(
            source: desktopVideo, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        return view
    }

    func startIfNeeded() { if webView.url == nil, !webView.isLoading, let url = section.home { open(url) } }
    func select(_ next: BrowserSection) {
        guard next != section else { return }
        pauseMedia()
        section = next
        notice = nil
        currentURL = webView.url
        isVideoPage = next == .videos || currentURL.map(BrowserAddress.prefersDesktop) == true
        siteLabel = currentURL?.host ?? next.title
        refresh()
        startIfNeeded()
    }
    func open(_ url: URL) {
        guard BrowserAddress.allows(url) else { notice = "只能打开网页网址。"; return }
        notice = nil
        updatePage(for: url)
        // Set before the first request too: mobile redirects can happen before the delegate returns.
        webView.customUserAgent = BrowserAddress.prefersDesktop(url) ? desktopUserAgent : nil
        webView.load(URLRequest(url: url))
    }
    func search(_ text: String) {
        guard let url = BrowserAddress.search(text, in: section) else {
            notice = section == .browser ? "请输入搜索内容或有效的 http／https 网址。" : "请输入站内搜索内容。"; return
        }
        open(url)
    }
    func home() { if let url = section.home { open(url) } }
    func back() {
        if let url = webView.backForwardList.backItem?.url {
            updatePage(for: url)
            webView.customUserAgent = BrowserAddress.prefersDesktop(url) ? desktopUserAgent : nil
        }
        webView.goBack()
    }
    func forward() {
        if let url = webView.backForwardList.forwardItem?.url {
            updatePage(for: url)
            webView.customUserAgent = BrowserAddress.prefersDesktop(url) ? desktopUserAgent : nil
        }
        webView.goForward()
    }
    func reloadOrStop() { if loading { webView.stopLoading(); refresh() } else { webView.reload() } }
    func pauseMedia() { for view in pages.values { view.pauseAllMediaPlayback() } }
    func websiteLogin() {
        guard let url = currentURL, BrowserAddress.isCommunity(url) || BrowserAddress.prefersDesktop(url) else { return }
        let view = webView
        // Keep the official login dialog accessible when its desktop header is hidden.
        view.evaluateJavaScript("""
        (() => {
            const button = Array.from(document.querySelectorAll('#app > nav button, #douyin-header button'))
                .find(e => e.textContent.trim() === '登录');
            if (!button) return false;
            button.click(); return true;
        })()
        """) { [weak self, weak view] result, error in
            guard let self, let view, view === self.webView else { return }
            if error != nil || result as? Bool != true { self.notice = "当前网页的登录入口尚未就绪，请加载完成后重试。" }
        }
    }

    private func refresh() {
        loading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if !loading, let url = webView.url { updatePage(for: url) }
    }
    private func updatePage(for url: URL) {
        currentURL = url
        if let host = url.host?.lowercased() {
            let official = BrowserAddress.isCommunity(url)
            siteLabel = official ? "小黑盒官方网页" : host
        }
        isVideoPage = section == .videos || BrowserAddress.prefersDesktop(url)
        let background: UIColor = isVideoPage ? .black : .white
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.underPageBackgroundColor = background
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        notice = nil; refresh()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if let url = webView.url { updatePage(for: url) }
        refresh()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === self.webView { refresh() } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === self.webView { failed(error) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === self.webView { failed(error) } }
    private func failed(_ error: Error) {
        refresh()
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        notice = "网页未能加载：\(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        refresh(); notice = "网页进程已退出，请刷新页面；录制状态可在设置中查看。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url, BrowserAddress.allows(url) else {
            if webView === self.webView, navigationAction.targetFrame?.isMainFrame != false {
                notice = "此链接要打开其他 App，浏览模式仅打开网页。"
            }
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            if webView === self.webView { updatePage(for: url) }
            let desktop = BrowserAddress.prefersDesktop(url)
            preferences.preferredContentMode = desktop ? .desktop : .mobile
            webView.customUserAgent = desktop ? desktopUserAgent : nil
        }
        decisionHandler(.allow, preferences)
    }
    // Links that request a new window stay within their own tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, BrowserAddress.allows(url) {
            if webView === self.webView { open(url) }
            else {
                webView.customUserAgent = BrowserAddress.prefersDesktop(url) ? desktopUserAgent : nil
                webView.load(URLRequest(url: url))
            }
        }
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
    let insets: UIEdgeInsets
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        let page = browser.webView
        let scroll = page.scrollView
        scroll.contentInsetAdjustmentBehavior = .never
        if scroll.contentInset != insets {
            let offset = scroll.contentOffset
            let previous = scroll.contentInset
            scroll.contentInset = insets
            scroll.verticalScrollIndicatorInsets = insets
            // Preserve the visible document position when bars or orientation change.
            scroll.setContentOffset(CGPoint(x: offset.x, y: offset.y + previous.top - insets.top), animated: false)
        }
        guard page.superview !== view else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

private struct BrowserChromeHeight: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
struct BrowserView: View {
    @ObservedObject var browser: RecorderBrowser
    let settings: () -> Void
    @State private var searchText = ""
    @State private var searches: [BrowserSection: String] = [:]
    @FocusState private var searchFocused: Bool
    @State private var chromeHeights: [String: CGFloat] = ["top": 64, "bottom": 68]
    @Namespace private var tabSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if browser.section == .browser && browser.currentURL == nil && !browser.loading {
                    VStack(spacing: 16) {
                        Image(systemName: "safari").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                        Text("浏览器").font(.title2.weight(.semibold))
                        Text("输入网址，或搜索整个互联网").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("小黑盒") { browser.open(BrowserAddress.community) }
                            Button("抖音") { browser.open(BrowserAddress.videos) }
                        }.buttonStyle(.bordered).padding(.top, 8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browser.isVideoPage {
                    // A viewport-sized player needs real layout space, not scroll insets behind the bars.
                    RecorderWebPage(browser: browser, insets: .zero)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .recorderExtendedBackground()
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear.frame(height: chromeHeights["top", default: 64])
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: chromeHeights["bottom", default: 68])
                        }
                } else {
                    RecorderWebPage(browser: browser, insets: UIEdgeInsets(
                        top: geometry.safeAreaInsets.top + chromeHeights["top", default: 64], left: 0,
                        bottom: geometry.safeAreaInsets.bottom + chromeHeights["bottom", default: 68], right: 0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                }
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        topBar
                        if let notice = browser.notice {
                            HStack {
                                Text(notice).font(.caption)
                                Spacer()
                                Button("关闭") { browser.notice = nil }.frame(minHeight: 44)
                            }.padding(.horizontal, 16).padding(.vertical, 4)
                                .recorderGlass(in: RoundedRectangle(cornerRadius: 20))
                        }
                    }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
                        .frame(maxWidth: 900)
                        .background(GeometryReader { size in
                            Color.clear.preference(key: BrowserChromeHeight.self, value: ["top": size.size.height])
                        })
                    Spacer(minLength: 0)
                    bottomBar.padding(.horizontal, 12).padding(.bottom, 8)
                        .frame(maxWidth: 500)
                        .background(GeometryReader { size in
                            Color.clear.preference(key: BrowserChromeHeight.self, value: ["bottom": size.size.height])
                        })
                }
            }
            .onPreferenceChange(BrowserChromeHeight.self) { chromeHeights = $0 }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea()).foregroundStyle(Color.primary).tint(Color.primary)
        .preferredColorScheme(browser.isVideoPage ? .dark : .light)
        .onAppear {
            browser.startIfNeeded()
            if browser.section == .browser { searchText = browser.currentURL?.absoluteString ?? "" }
        }
        .onChange(of: browser.currentURL) { url in
            if browser.section == .browser && !searchFocused { searchText = url?.absoluteString ?? "" }
        }
        .onDisappear { browser.pauseMedia() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            browser.pauseMedia()
        }
    }

    private var bottomBar: some View {
        recorderGlassGroup {
            VStack(spacing: 8) {
                if browser.section == .browser {
                    HStack {
                        Button(action: browser.back) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .foregroundStyle(browser.canGoBack ? Color.primary : Color.secondary)
                            .disabled(!browser.canGoBack).accessibilityLabel("返回上一页")
                        Spacer()
                        Button(action: browser.forward) { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .foregroundStyle(browser.canGoForward ? Color.primary : Color.secondary)
                            .disabled(!browser.canGoForward).accessibilityLabel("前进一页")
                        Spacer()
                        Text(browser.currentURL?.host ?? "新页面").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(action: browser.reloadOrStop) {
                            Image(systemName: browser.loading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44)
                        }.foregroundStyle(browser.currentURL == nil ? Color.secondary : Color.primary)
                            .disabled(browser.currentURL == nil).accessibilityLabel(browser.loading ? "停止加载" : "刷新网页")
                    }.font(.system(size: 18)).padding(.horizontal, 12)
                        .recorderGlass(in: Capsule(), interactive: true)
                }
                HStack(spacing: 0) {
                    tab(.community, symbol: "square.grid.2x2", selectedSymbol: "square.grid.2x2.fill")
                    tab(.videos, symbol: "play.rectangle", selectedSymbol: "play.rectangle.fill")
                    tab(.browser, symbol: "safari", selectedSymbol: "safari.fill")
                }.padding(6).recorderGlass(in: Capsule(), interactive: true)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if browser.section != .browser {
                if browser.canGoBack {
                    Button(action: browser.back) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    }.accessibilityLabel("返回上一页")
                } else {
                    Text(browser.section == .videos ? "推荐" : "社区")
                        .font(.system(size: 20, weight: .bold)).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: browser.section == .browser ? "globe" : "magnifyingglass")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                TextField(browser.section.searchPrompt, text: $searchText)
                    .font(.system(size: 15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(browser.section == .browser ? .webSearch : .default)
                    .submitLabel(.search).focused($searchFocused).onSubmit(submitSearch)
                    .accessibilityLabel(browser.section.searchPrompt)
                if !searchText.isEmpty {
                    Button(action: submitSearch) {
                        Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 44)
                    }.accessibilityLabel("提交搜索")
                }
            }
            .padding(.leading, 12).padding(.trailing, searchText.isEmpty ? 12 : 2).frame(height: 44)
            Menu {
                Text(browser.siteLabel)
                Button(action: browser.back) { Label("返回上一页", systemImage: "chevron.left") }.disabled(!browser.canGoBack)
                Button(action: browser.forward) { Label("前进一页", systemImage: "chevron.right") }.disabled(!browser.canGoForward)
                Button(action: browser.reloadOrStop) { Label(browser.loading ? "停止加载" : "刷新网页", systemImage: "arrow.clockwise") }
                    .disabled(browser.currentURL == nil)
                if browser.section != .browser {
                    Button { searchText = ""; browser.home() } label: {
                        Label(browser.section == .community ? "回到社区首页" : "回到推荐视频", systemImage: "house")
                    }
                }
                if let url = browser.currentURL, BrowserAddress.isCommunity(url) || BrowserAddress.prefersDesktop(url) {
                    Button(action: browser.websiteLogin) { Label("网站登录", systemImage: "person.crop.circle") }
                }
                Divider()
                Button(action: settings) { Label("设置", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("更多选项")
        }.padding(.leading, browser.canGoBack && browser.section != .browser ? 6 : 16)
            .padding(.trailing, 6).padding(.vertical, 6)
            .recorderGlass(in: Capsule(), interactive: true)
            .overlay(alignment: .bottom) {
                if browser.loading {
                    ProgressView().progressViewStyle(.linear).tint(.secondary).frame(height: 2)
                        .padding(.horizontal, 20).padding(.bottom, 2)
                }
            }
    }

    private func tab(_ section: BrowserSection, symbol: String, selectedSymbol: String) -> some View {
        let selected = browser.section == section
        return Button { select(section) } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedSymbol : symbol).font(.system(size: 21, weight: .regular))
                Text(section.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.vertical, 2)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.1)).matchedGeometryEffect(id: "selection", in: tabSelection)
                }
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ section: BrowserSection) {
        guard section != browser.section else { return }
        searches[browser.section] = searchText
        searchFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { browser.select(section) }
        searchText = section == .browser ? browser.currentURL?.absoluteString ?? searches[section, default: ""]
            : searches[section, default: ""]
    }

    private func submitSearch() {
        searchFocused = false
        browser.search(searchText)
    }
}
