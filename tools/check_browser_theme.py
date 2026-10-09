"""Replay production tab/navigation methods; stand-ins do not render SwiftUI."""
from pathlib import Path
import argparse
import subprocess
from check_lifecycle import extract

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--generate-only', action='store_true')
parser.add_argument('--output', type=Path, default=ROOT / 'build/browser-theme-check.swift')
args = parser.parse_args()
source = (ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift').read_text(encoding='utf-8')
models = (ROOT / 'Recorder.swiftpm/Sources/RecorderSettings.swift').read_text(encoding='utf-8')
methods = '\n'.join(extract(source, name) for name in [
    'var webView: WKWebView {', 'func startIfNeeded()', 'func select(',
    'func open(', 'func back()', 'func forward()', 'func search(', 'func home()',
    'func pauseMedia()', 'func websiteLogin()', 'private func refresh()',
    'private func updatePage(', 'private func failed(',
    'func webView(_ webView: WKWebView, didStartProvisionalNavigation',
    'func webView(_ webView: WKWebView, didCommit',
    'func webView(_ webView: WKWebView, didFinish',
    'func webView(_ webView: WKWebView, didFail navigation',
    'func webViewWebContentProcessDidTerminate(',
    'func webView(_ webView: WKWebView, decidePolicyFor',
])
code = '''import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
''' + extract(models, 'enum BrowserSection:') + '\n' + extract(models, 'enum BrowserAddress {') + r'''
enum UIColor { case black, white }
final class ScrollView { var backgroundColor: UIColor = .white }
struct HistoryItem { var url: URL }
final class History { var backItem: HistoryItem?, forwardItem: HistoryItem? }
final class WKWebView {
    var url: URL?, customUserAgent: String?
    var isLoading = false, canGoBack = false, canGoForward = false
    var backgroundColor: UIColor = .white, underPageBackgroundColor: UIColor = .white
    var loadCount = 0, pauseCount = 0, scrollPosition = 0
    var loginCompletion: ((Any?, Error?) -> Void)?
    let scrollView = ScrollView(), backForwardList = History()
    func load(_ request: URLRequest) { url = request.url; isLoading = true; loadCount += 1 }
    func goBack() { url = backForwardList.backItem?.url; isLoading = true }
    func goForward() { url = backForwardList.forwardItem?.url; isLoading = true }
    func pauseAllMediaPlayback() { pauseCount += 1 }
    func evaluateJavaScript(_ text: String, completionHandler: @escaping (Any?, Error?) -> Void) { loginCompletion = completionHandler }
}
final class WKNavigation {}
struct WKFrameInfo { var isMainFrame: Bool }
struct WKNavigationAction { var request: URLRequest; var targetFrame: WKFrameInfo? }
enum WKNavigationActionPolicy { case allow, cancel }
final class WKWebpagePreferences {
    enum Mode { case mobile, desktop }
    var preferredContentMode: Mode = .mobile
}
final class Browser {
    var pages: [BrowserSection: WKWebView] = [:]
    var section: BrowserSection = .community, currentURL: URL?
    let desktopUserAgent = "desktop fixture"
    var loading = false, canGoBack = false, canGoForward = false
    var notice: String?, siteLabel = "", isVideoPage = false
    func makeWebView() -> WKWebView { WKWebView() }
    METHODS
    func fail(_ error: Error) { failed(error) }
}
let browser = Browser()
func check(_ dark: Bool) {
    assert(browser.isVideoPage == dark)
    let color: UIColor = dark ? .black : .white
    assert(browser.webView.backgroundColor == color && browser.webView.scrollView.backgroundColor == color
        && browser.webView.underPageBackgroundColor == color)
}
browser.startIfNeeded()
let community = browser.webView
assert(community.url == BrowserAddress.community && community.loadCount == 1)
community.scrollPosition = 345
browser.search("原神 & /?#% 电影")
let postSearch = community.url!
let items = URLComponents(url:postSearch,resolvingAgainstBaseURL:false)!.queryItems!
assert(postSearch.host == "www.xiaoheihe.cn" && postSearch.path == "/app/search/list")
assert(items.first(where:{$0.name == "q"})?.value == "原神 & /?#% 电影")
assert(items.first(where:{$0.name == "search_type"})?.value == "link")
browser.select(.videos)
let video = browser.webView
assert(video !== community && video.url == BrowserAddress.videos && community.pauseCount == 1)
check(true)
browser.search("原神 /?#% +&")
let videoSearch = video.url!
assert(videoSearch.host == "www.douyin.com")
assert(URLComponents(url:videoSearch,resolvingAgainstBaseURL:false)!.percentEncodedPath
    .dropFirst("/search/".count).description.removingPercentEncoding == "原神 /?#% +&")
assert(URLComponents(url:videoSearch,resolvingAgainstBaseURL:false)!.queryItems!.first?.value == "general")
video.scrollPosition = 678
browser.select(.browser)
let general = browser.webView
assert(general !== community && general !== video && general.url == nil && browser.currentURL == nil)
assert(!browser.isVideoPage && !browser.canGoBack)
browser.search("example.com"); check(false)
assert(general.url!.host == "example.com")
browser.search("原神 & Swift")
assert(general.url!.host == "www.bing.com")
assert(URLComponents(url:general.url!,resolvingAgainstBaseURL:false)!.queryItems!.first?.value == "原神 & Swift")
for section in BrowserSection.allCases { assert(BrowserAddress.search(" \n ",in:section) == nil) }
let beforeInvalid = general.url
for invalid in ["file:///private/test", "javascript:alert(1)", "https://name:password@example.com"] {
    browser.search(invalid); assert(general.url == beforeInvalid && browser.notice != nil)
}
let count = community.loadCount
browser.select(.community)
assert(browser.webView === community && community.url == postSearch && community.scrollPosition == 345)
assert(community.loadCount == count)
browser.select(.videos)
assert(browser.webView === video && video.url == videoSearch && video.scrollPosition == 678)
check(true)
// Late callbacks from an offscreen tab must not change the selected tab or errors.
community.url = URL(string:"https://example.com/")!; community.isLoading = false
browser.webView(community, didCommit:WKNavigation()); browser.webView(community, didFinish:WKNavigation())
browser.webView(community,didFail:WKNavigation(),withError:NSError(domain:NSURLErrorDomain,code:NSURLErrorCannotConnectToHost))
browser.webViewWebContentProcessDidTerminate(community)
assert(browser.currentURL == videoSearch && browser.notice == nil); check(true)
let prefs = WKWebpagePreferences()
let inactive = WKNavigationAction(request:URLRequest(url:BrowserAddress.community),targetFrame:WKFrameInfo(isMainFrame:true))
browser.webView(community,decidePolicyFor:inactive,preferences:prefs) { policy,_ in assert(policy == .allow) }
assert(browser.currentURL == videoSearch); check(true)
browser.select(.browser)
for url in [BrowserAddress.community, BrowserAddress.videos, URL(string:"https://live.douyin.com/")!,
            URL(string:"https://douyin.com.example.com/")!, BrowserAddress.community] {
    browser.open(url); check(BrowserAddress.prefersDesktop(url))
}
browser.open(BrowserAddress.videos)
general.url = BrowserAddress.community
browser.webView(general,didStartProvisionalNavigation:WKNavigation()); check(true)
general.url = BrowserAddress.videos
browser.webView(general,didCommit:WKNavigation()); check(true)
general.backForwardList.backItem = HistoryItem(url:BrowserAddress.community)
browser.back(); check(false)
general.backForwardList.forwardItem = HistoryItem(url:BrowserAddress.videos)
browser.forward(); check(true)
browser.open(BrowserAddress.videos)
for main in [false, true] {
    let action = WKNavigationAction(request:URLRequest(url:BrowserAddress.community),targetFrame:WKFrameInfo(isMainFrame:main))
    browser.webView(general,decidePolicyFor:action,preferences:prefs) { policy,_ in assert(policy == .allow) }
    check(!main)
}
browser.open(BrowserAddress.videos)
let blocked = WKNavigationAction(request:URLRequest(url:URL(string:"file:///private/test")!),targetFrame:WKFrameInfo(isMainFrame:true))
browser.webView(general,decidePolicyFor:blocked,preferences:prefs) { policy,_ in assert(policy == .cancel) }
check(true)
general.isLoading = false; general.url = BrowserAddress.community
browser.fail(NSError(domain:NSURLErrorDomain,code:NSURLErrorCannotConnectToHost)); check(false)
assert(browser.notice != nil)
browser.websiteLogin(); general.loginCompletion?(true,nil)
browser.notice = nil
browser.websiteLogin()
browser.select(.community); browser.notice = nil
general.loginCompletion?(false,nil)
assert(browser.notice == nil)
browser.pauseMedia(); assert(browser.pages.values.allSatisfy({ $0.pauseCount > 0 }))
print("PASS: production browser tabs retain independent history/scroll, pause hidden media, ignore late callbacks and route community/video/web searches with safe Unicode encoding")
print("PASS: production browser themes follow open/back/forward/main-frame navigation, preserve pending theme, ignore iframe/blocked links and restore failed navigation")
print("Navigation checks use web-view stand-ins; native rendering is checked separately.")
'''.replace('METHODS', methods)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(code, encoding='utf-8')
if not args.generate_only:
    subprocess.run(['swift', str(args.output)], check=True)
