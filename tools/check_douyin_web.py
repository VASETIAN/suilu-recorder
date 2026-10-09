"""Check the production desktop-video adapter in Apple WebKit, with a fixture.

Public DOM IDs/data attributes and observed min-width reproduce the narrow
desktop-page overflow. Synthetic touch events test the swipe guards. No real
Douyin account, network playback or iPhone browser is claimed.
"""
from pathlib import Path
import argparse
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def build(output: Path):
    source = (ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift').read_text(encoding='utf-8')
    script = re.search(r'let desktopVideo = """\n(.*?)\n        """', source, re.S).group(1)
    script = script.replace("location.hostname === 'douyin.com' || location.hostname.endsWith('.douyin.com')", 'true')
    ua = re.search(r'desktopUserAgent = "([^"]+)"', source).group(1)
    # The production open must select its UA before sending the first HTTP request.
    opened = source.split('func open(_ url: URL)', 1)[1].split('func search(', 1)[0]
    assert opened.index('webView.customUserAgent') < opened.index('webView.load(')
    assert 'preferences.preferredContentMode = desktop ? .desktop : .mobile' in source
    fixture = '''<!doctype html><html><head><meta charset="utf-8"><style>
    *{box-sizing:border-box}body{min-width:580px;margin:0}#dark{display:flex;height:100vh}
    #douyin-navigation{width:72px;flex-shrink:0}#douyin-right-container{flex:1;min-width:0;min-height:450px;padding-top:56px;position:relative}
    #douyin-header{position:absolute;top:0;left:0;right:0;height:56px;white-space:nowrap}
    .live-detail-portal-anchor-wrapper,.parent-route-container{height:100%;position:relative}
    #slidelist{position:relative;height:100%}#slidelist>[data-e2e="slideList"]{position:absolute;width:100%;height:calc(100% - 12px);padding-right:60px;min-height:495px}
    [data-e2e="feed-active-video"]{position:relative;width:100%;height:100%;background:#000;color:white}
    .xg-video-container{position:absolute;inset:0 0 48px}video{width:100%;height:100%;object-fit:contain}
    #video-surface{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font:22px system-ui}
    .xgplayer-controls{position:absolute;bottom:0;left:0;width:100%;height:48px;background:#222;display:flex;align-items:center;justify-content:space-around}
    #interactive{position:absolute;right:12px;top:40%;width:44px;height:44px}
    .recommend-out-switch-btn{position:absolute;right:12px;top:50%;width:36px;height:80px;transform:translateY(-50%)}
    .xgplayer-playswitch-tab{width:36px;height:80px}
    .xgplayer-playswitch-tab>div{width:36px;height:40px;background:#ddd;cursor:pointer}
    #login-modal{display:none;position:fixed;inset:0;align-items:center;justify-content:center;background:#aaa}
    #douyin_login_comp_flat_panel{width:726px;height:483px;background:white}
    #douyin_login_comp_flat_panel>header{display:flex;justify-content:space-between;padding:10px}
    #douyin_login_comp_flat_panel_title{width:264px;font-size:24px}
    #douyin_login_landing_flat_container{display:flex;width:726px}
    #douyin_login_landing_flat_container>div{width:253px;height:264px;margin-left:56px;flex-shrink:0}
    #douyin_login_landing_flat_container>div+div{margin-left:108px}
    </style></head><body><div id="root"><div id="dark"><nav id="douyin-navigation">Desktop nav</nav>
    <main id="douyin-right-container"><header id="douyin-header"><button id="login">登录</button></header>
    <div class="live-detail-portal-anchor-wrapper"><div class="parent-route-container route-scroll-container">
    <div id="slidelist" class="recommend-slidelist"><div data-e2e="slideList"><div data-e2e="feed-active-video">
    <div class="xg-video-container"><video></video><span id="video-surface">Video</span></div><button id="interactive">Like</button>
    <div class="xgplayer-controls"><button>▶</button><span>Playback controls</span><button>⛶</button></div></div></div></div>
    <div class="recommend-out-switch-btn"><div class="xgplayer-playswitch-tab"><div data-e2e="video-switch-prev-arrow">↑</div><div data-e2e="video-switch-next-arrow">↓</div></div></div>
    </div></div></main></div></div>
    <div id="login-modal"><article id="douyin_login_comp_flat_panel"><header><div id="douyin_login_comp_flat_panel_title">Login title</div><button id="close-modal">X</button></header><div id="douyin_login_landing_flat_container"><div>QR</div><div><input id="login-field"></div></div></article></div>
    <script>window.nextCount=0;window.prevCount=0;document.querySelector('[data-e2e="video-switch-next-arrow"]').onclick=()=>nextCount++;
    document.querySelector('[data-e2e="video-switch-prev-arrow"]').onclick=()=>prevCount++;</script></body></html>'''
    query = r'''(() => {
        const feed=document.querySelector('[data-e2e="feed-active-video"]'), next=document.querySelector('[data-e2e="video-switch-next-arrow"]');
        const r=next.getBoundingClientRect(), f=feed.getBoundingClientRect();
        const controls=document.querySelector('.xgplayer-controls').getBoundingClientRect();
        const fillsWidth=Math.abs(f.left)<=1 && Math.abs(f.right-innerWidth)<=1;
        const controlsFit=controls.top>=0 && controls.bottom<=innerHeight+1 && controls.width===f.width;
        const preservesAspect=getComputedStyle(document.querySelector('video')).objectFit==='contain';
        const fits=document.documentElement.scrollWidth<=innerWidth+1 && fillsWidth && controlsFit
            && r.left>=0 && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight
            && document.elementFromPoint(r.x+8,r.y+8)===next;
        function swipe(target,dx,dy,multi=false,cancel=false) {
            const touch={clientX:100,clientY:400};
            const start=new Event('touchstart',{bubbles:true});Object.defineProperty(start,'touches',{value:multi?[touch,touch]:[touch]});target.dispatchEvent(start);
            if(cancel)target.dispatchEvent(new Event('touchcancel',{bubbles:true}));
            const end=new Event('touchend',{bubbles:true});Object.defineProperty(end,'changedTouches',{value:[{clientX:100+dx,clientY:400+dy}]});target.dispatchEvent(end);
        }
        const surface=document.querySelector('#video-surface');
        swipe(surface,0,-150);swipe(surface,0,150);
        swipe(surface,0,-20);swipe(surface,150,-100);swipe(surface,0,-150,true);swipe(surface,0,-150,false,true);
        swipe(document.querySelector('#interactive'),0,-150);swipe(document.querySelector('#login'),0,-150);
        swipe(document.querySelector('.xgplayer-controls'),0,-150);
        next.classList.add('disabled');swipe(surface,0,-150);next.classList.remove('disabled');
        next.setAttribute('aria-disabled','true');swipe(surface,0,-150);
        document.querySelector('#login-modal').style.display='flex';
        const panel=document.querySelector('#douyin_login_comp_flat_panel'), p=panel.getBoundingClientRect();
        const close=document.querySelector('#close-modal').getBoundingClientRect(), field=document.querySelector('#login-field').getBoundingClientRect();
        const loginFits=p.left>=0 && p.right<=innerWidth && close.right<=p.right && field.left>=p.left && field.right<=p.right && panel.scrollWidth<=panel.clientWidth+1;
        const searchHidden=getComputedStyle(document.querySelector('#douyin-header')).display === 'none';
        return {ok:fits && preservesAspect && loginFits && searchHidden && nextCount===1 && prevCount===1 && navigator.userAgent.includes('Macintosh') && !navigator.userAgent.includes('iPhone'),
                fits,fillsWidth,controlsFit,preservesAspect,loginFits,nextCount,prevCount,width:innerWidth,height:innerHeight,feedWidth:f.width,scrollWidth:document.documentElement.scrollWidth};
    })()'''
    swift = r'''
import Cocoa
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
@MainActor final class VideoPageCheck: NSObject, WKNavigationDelegate {
    let sizes = [NSSize(width:320,height:760), NSSize(width:430,height:760), NSSize(width:768,height:430), NSSize(width:956,height:260)]
    var index = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
    let view: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: #"""
ADAPTER
"""#, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 430, height: 760), configuration: configuration)
        super.init()
        view.customUserAgent = "USER_AGENT"
        view.navigationDelegate = self
        window.contentView = view; window.orderFront(nil)
    }
    func run() {
        let size = sizes[index]
        window.setContentSize(size); view.setFrameSize(size)
        view.loadHTMLString(#"""
FIXTURE
"""#, baseURL: URL(string: "https://www.douyin.com/?recommend=1"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        view.evaluateJavaScript(#"""
QUERY
"""#) { result, error in
            guard error == nil, let values = result as? [String: Any], values["ok"] as? Bool == true else { self.fail("\(String(describing: result)), \(String(describing: error))"); return }
            print("PASS: production Douyin WebKit adapter at \(self.sizes[self.index].width)x\(self.sizes[self.index].height) fills the viewport width, keeps playback controls visible, fits arrows and login fields; vertical swipe changes video, taps/controls/disabled arrows/multi-touch are protected; desktop UA selected")
            self.index += 1
            if self.index == self.sizes.count { exit(0) }
            self.run()
        }
    }
    func fail(_ reason: String) { print("FAIL: \(reason)"); exit(1) }
}
DispatchQueue.main.async {
    let check = VideoPageCheck(); check.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { check.fail("WebKit video check timed out") }
}
app.run()
'''.replace('ADAPTER', script).replace('FIXTURE', fixture).replace('QUERY', query).replace('USER_AGENT', ua)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(swift, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'build/douyin-web-check.swift')
    p.add_argument('--generate-only', action='store_true')
    args = p.parse_args()
    build(args.output)
    if not args.generate_only:
        subprocess.run(['swift', str(args.output)], check=True)
