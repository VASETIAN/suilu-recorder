"""Replay the website's fixed-mask bug with the production adapter in WebKit.

The fixture reproduces the public CSS pattern with synthetic posts. macOS
WebKit is a rendering check, not an iPhone or camera hardware test.
"""
from pathlib import Path
import argparse
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def build(output: Path):
    source = (ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift').read_text(encoding='utf-8')
    script = re.search(r'let mobileCommunity = """\n(.*?)\n        """', source, re.S).group(1)
    script = script.replace("location.hostname === 'www.xiaoheihe.cn' || location.hostname === 'xiaoheihe.cn'", 'true')
    # The removed desktop header still had this fixed 146px mask above the feed.
    css = '''*{box-sizing:border-box}body{margin:0;font:16px system-ui}#app{min-width:800px}#app>nav{height:64px}#app>main{padding:0 12px}#page-bbs-community{width:1032px;margin:auto;padding:16px 0}#page-bbs-community:before{content:"";display:block;position:fixed;top:0;width:100%;height:146px;background:#f7f8f9;z-index:5}#page-bbs-community:after{content:"";display:block;position:fixed;bottom:0;width:100%;height:22px;background:#f7f8f9;z-index:5}.content{display:flex}.list{width:660px}.list:before{content:"";display:block;position:sticky;top:138px;height:8px;background:white;z-index:10}.list:after{content:"";display:block;position:sticky;bottom:16px;height:8px;background:white;z-index:10}.right{width:356px}.hb-cpt__pagination-outer{overflow:hidden}.hb-cpt__pagination-inner{display:flex;width:800px}.bbs-home__topic-item{flex-shrink:0}.bbs-home__content-list{padding:0 16px}.bbs-home__content-item{position:relative;margin-bottom:4px}.hb-bbs-home__feed-splitline:after{content:"";position:absolute;top:100%;left:-28px;width:calc(100% + 56px);height:4px;background:#eee}.hb-cpt__bbs-list-content{display:block;padding:12px;background:white}.bbs-content__title{margin:0 0 12px}.bbs-content__imgs-wrapper{position:relative;height:190px}.bbs-content__image{position:absolute;width:190px;height:190px;left:0;background:#d6dde2}'''
    topics = ''.join(f'<button class="bbs-home__topic-item"><span class="bbs-home__topic-item-icon" style="display:block;background:#ddd"></span>社区 {i}</button>' for i in range(8))
    cards = ''.join('<div class="bbs-home__content-item hb-bbs-home__feed-splitline"><a class="hb-cpt__bbs-list-content"><h2 class="bbs-content__title">Test post</h2><div class="bbs-content__imgs-wrapper"><div class="bbs-content__image"></div></div></a></div>' for _ in range(8))
    html = '<!doctype html><html><head><style>'+css+'</style></head><body><div id="app"><nav>Desktop navigation</nav><main><section id="page-bbs-community"><div class="bbs-community__search-module">Search</div><div class="content"><main class="list"><div class="hb-bbs-home"><div class="bbs-home__topic-list-wrapper"><div class="hb-cpt__pagination bbs-home__topic-list"><div class="hb-cpt__pagination-outer"><div class="hb-cpt__pagination-inner">'+topics+'</div></div></div></div><div class="bbs-home__content-list">'+cards+'</div></div></main><aside class="right">Sidebar</aside></div></section></main></div></body></html>'
    swift = r'''
import Cocoa
import WebKit

let adapter = #"""
ADAPTER
"""#
let fixture = #"""
FIXTURE
"""#
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
@MainActor
final class LayoutCheck: NSObject, WKNavigationDelegate {
    let widths = [320, 430, 768]
    var index = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 830),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: adapter,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 430, height: 830), configuration: configuration)
        super.init()
        view.navigationDelegate = self
        window.contentView = view
        window.orderFront(nil)
    }
    func run() {
        let size = NSSize(width: widths[index], height: 830)
        window.setContentSize(size)
        view.setFrameSize(size)
        view.loadHTMLString(fixture, baseURL: URL(string: "https://www.xiaoheihe.cn/app/bbs/home"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        check(scrolled: false)
    }
    func check(scrolled: Bool) {
        let query = """
        (() => {
            const page = document.querySelector('#page-bbs-community'), list = document.querySelector('.list');
            const topic = document.querySelector('.bbs-home__topic-item');
            const r = topic.getBoundingClientRect(), hit = document.elementFromPoint(r.x + 8, r.y + 8);
            return {
                pageMask: getComputedStyle(page, '::before').display,
                bottomMask: getComputedStyle(page, '::after').display,
                listMask: getComputedStyle(list, '::before').display,
                listBottomMask: getComputedStyle(list, '::after').display,
                width: document.documentElement.clientWidth,
                scrollWidth: document.documentElement.scrollWidth,
                firstPostY: document.querySelector('.bbs-home__content-item').getBoundingClientRect().y,
                topicCanBeTapped: hit?.closest('.bbs-home__topic-item') === topic
            };
        })()
        """
        view.evaluateJavaScript(query) { result, error in
            guard error == nil, let values = result as? [String: Any],
                  let width = values["width"] as? Int, let scrollWidth = values["scrollWidth"] as? Int,
                  ["pageMask", "bottomMask", "listMask", "listBottomMask"].allSatisfy({ values[$0] as? String == "none" }),
                  scrollWidth <= width + 1 else { self.fail("Masks or overflow: \(String(describing: result)), \(String(describing: error))"); return }
            if !scrolled {
                guard values["topicCanBeTapped"] as? Bool == true,
                      let y = values["firstPostY"] as? Double, y < 120 else { self.fail("Top content is covered: \(values)"); return }
                self.view.evaluateJavaScript("window.scrollTo(0, 250)") { _, error in
                    if let error { self.fail(error.localizedDescription); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.check(scrolled: true) }
                }
            } else {
                print("PASS: production WebKit adapter at \(self.widths[self.index])px removes the fixed masks, keeps categories tappable and avoids overflow before/after scrolling")
                self.index += 1
                if self.index == self.widths.count { exit(0) }
                self.run()
            }
        }
    }
    func fail(_ reason: String) { print("FAIL: \(reason)"); exit(1) }
}
let check = LayoutCheck()
DispatchQueue.main.async { check.run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { check.fail("WebKit check timed out") }
app.run()
'''.replace('ADAPTER', script).replace('FIXTURE', html)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(swift, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'build/browser-layout-check.swift')
    p.add_argument('--generate-only', action='store_true')
    args = p.parse_args()
    build(args.output)
    if not args.generate_only:
        subprocess.run(['swift', str(args.output)], check=True)
