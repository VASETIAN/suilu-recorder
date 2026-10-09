"""Replay production navigation/theme methods; web-view stand-ins do not render SwiftUI."""
from pathlib import Path
import argparse
import subprocess
from check_lifecycle import extract

ROOT = Path(__file__).resolve().parent.parent


parser = argparse.ArgumentParser()
parser.add_argument('--generate-only', action='store_true')
parser.add_argument('--output', type=Path, default=ROOT / 'build/browser-theme-check.swift')
args = parser.parse_args()
browser = (ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift').read_text(encoding='utf-8')
models = (ROOT / 'Recorder.swiftpm/Sources/RecorderSettings.swift').read_text(encoding='utf-8')
methods = '\n'.join(extract(browser, name) for name in [
    'func open(', 'func back()', 'func forward()', 'func search(', 'private func refresh()',
    'private func updatePage(', 'private func failed(',
    'func webView(_ webView: WKWebView, didStartProvisionalNavigation',
    'func webView(_ webView: WKWebView, didCommit',
    'func webView(_ webView: WKWebView, decidePolicyFor',
])
code = '''import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
''' + extract(models, 'enum BrowserAddress {') + r'''
enum UIColor { case black, white }
final class ScrollView { var backgroundColor: UIColor = .white }
struct HistoryItem { var url: URL }
final class History { var backItem: HistoryItem?, forwardItem: HistoryItem? }
final class WKWebView {
    var url: URL?, customUserAgent: String?
    var isLoading = false, canGoBack = false, canGoForward = false
    var backgroundColor: UIColor = .white, underPageBackgroundColor: UIColor = .white
    let scrollView = ScrollView(), backForwardList = History()
    func load(_ request: URLRequest) { url = request.url; isLoading = true }
    func goBack() { url = backForwardList.backItem?.url; isLoading = true }
    func goForward() { url = backForwardList.forwardItem?.url; isLoading = true }
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
    let webView = WKWebView()
    let desktopUserAgent = "desktop fixture"
    var loading = false, canGoBack = false, canGoForward = false
    var notice: String?, siteLabel = "", isCommunityPage = true, isVideoPage = false
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
for url in [BrowserAddress.community, BrowserAddress.videos, URL(string:"https://live.douyin.com/")!,
            URL(string:"https://douyin.com.example.com/")!, BrowserAddress.community] {
    browser.open(url)
    check(BrowserAddress.prefersDesktop(url))
}
browser.open(BrowserAddress.videos)
// Provisional navigation can still expose the old URL; keep the requested theme until commit.
browser.webView.url = BrowserAddress.community
browser.webView(browser.webView, didStartProvisionalNavigation: WKNavigation())
check(true)
browser.webView.url = BrowserAddress.videos
browser.webView(browser.webView, didCommit: WKNavigation())
check(true)
browser.webView.backForwardList.backItem = HistoryItem(url: BrowserAddress.community)
browser.back(); check(false)
browser.webView.backForwardList.forwardItem = HistoryItem(url: BrowserAddress.videos)
browser.forward(); check(true)
browser.search("example.com"); check(false)
browser.open(BrowserAddress.videos)
let preferences = WKWebpagePreferences()
for main in [false, true] {
    let action = WKNavigationAction(request: URLRequest(url:BrowserAddress.community), targetFrame:WKFrameInfo(isMainFrame:main))
    browser.webView(browser.webView, decidePolicyFor:action, preferences:preferences) { policy, _ in assert(policy == .allow) }
    check(!main)
}
browser.open(BrowserAddress.videos)
let blocked = WKNavigationAction(request:URLRequest(url:URL(string:"file:///private/test")!), targetFrame:WKFrameInfo(isMainFrame:true))
browser.webView(browser.webView, decidePolicyFor:blocked, preferences:preferences) { policy, _ in assert(policy == .cancel) }
check(true)
browser.webView.isLoading = false
browser.webView.url = BrowserAddress.community
browser.fail(NSError(domain:NSURLErrorDomain, code:NSURLErrorCannotConnectToHost))
check(false)
assert(browser.notice != nil)
print("PASS: production browser themes follow open/back/forward/search/main-frame navigation, preserve pending theme, ignore iframe/blocked links and restore failed navigation")
print("Theme checks use web-view stand-ins; SwiftUI/status-bar rendering on iPhone is not tested.")
'''.replace('METHODS', methods)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(code, encoding='utf-8')
if not args.generate_only:
    subprocess.run(['swift', str(args.output)], check=True)
