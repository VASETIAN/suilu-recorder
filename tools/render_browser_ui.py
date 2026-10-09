"""Render the actual BrowserView in iOS Simulator with synthetic website fixtures.

No camera, account login, live website playback or physical iPhone is tested.
The production SwiftUI and WKWebView code is compiled unchanged.
"""
from pathlib import Path
import json
import os
import platform
import plistlib
import re
import subprocess
import time
from check_browser_layout import build as build_community
from check_douyin_web import build as build_video

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/ui-preview'
OUT.mkdir(parents=True, exist_ok=True)
BUNDLE = ROOT / 'build/BrowserUIPreview.app'
BUNDLE.mkdir(parents=True, exist_ok=True)
build_community(OUT / 'community-fixture.swift', ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift')
build_video(OUT / 'video-fixture.swift')
for section in ['community', 'videos']:
    generated = (OUT / ('community-fixture.swift' if section == 'community' else 'video-fixture.swift')).read_text()
    fixture = re.search(r'(?:let fixture = )?#"""\n(<!doctype html>.*?)\n"""#', generated, re.S).group(1)
    fixture = fixture.replace('<head>', '<head><title>Browser UI fixture</title>')
    if section == 'community':
        fixture = fixture.replace('Test post', '一起聊聊最近在玩的游戏')
    else:
        fixture = fixture.replace('</style>', 'body{background:#000;color:#fff}#video-surface{display:flex;align-items:center;justify-content:center;height:80%;font:22px system-ui}</style>')
        fixture = fixture.replace('>Video</span>', '>视频内容示例</span>').replace('>Like</button>', '>喜欢</button>')
    (BUNDLE / f'{section}.html').write_text(fixture)

harness = r'''
import SwiftUI
import WebKit

@main @MainActor final class PreviewApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let browser = RecorderBrowser()
    let scenario = CommandLine.arguments.last ?? "community"
    var section: BrowserSection { BrowserSection(rawValue: scenario) ?? .community }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        browser.select(section)
        let host = UIHostingController(rootView: BrowserView(browser: browser, settings: {}))
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = host
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.section == .browser { self.ready(["nativeStartPage": true]); return }
            let html = try! String(contentsOf: Bundle.main.url(forResource: self.section.rawValue, withExtension: "html")!)
            self.browser.webView.loadHTMLString(html, baseURL: self.section.home)
            self.check(remaining: 30)
        }
        return true
    }
    func check(remaining: Int) {
        browser.webView.evaluateJavaScript("""
        (() => {
            const ready = document.title === 'Browser UI fixture';
            const search = document.querySelector('#douyin-header, .bbs-community__search-module');
            return {ready, noDuplicateSearch:!!search && getComputedStyle(search).display === 'none',
                noOverflow: document.documentElement.scrollWidth <= innerWidth + 1,
                width:innerWidth};
        })()
        """) { result, error in
            if let value = result as? [String: Any], value["ready"] as? Bool == true {
                guard value["noDuplicateSearch"] as? Bool == true, value["noOverflow"] as? Bool == true else {
                    self.ready(["error": "Duplicate search or horizontal overflow", "values": value]); return
                }
                if self.scenario.hasPrefix("glass-") {
                    let color = self.scenario == "glass-blue" ? "#3b82f6" : "#f97316"
                    self.browser.webView.evaluateJavaScript("""
                    document.querySelectorAll('img').forEach(img => {
                        img.src='data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="1800"><rect width="200" height="1800" fill="\(color)"/></svg>');
                    });
                    """) { _, error in
                        if let error { self.ready(["error":error.localizedDescription]); return }
                        self.browser.webView.scrollView.setContentOffset(CGPoint(x:0,y:200), animated:false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ready(value) }
                    }
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ready(value) } }
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.check(remaining: remaining - 1) }
            } else { self.ready(["error": "Fixture did not load", "details": String(describing:error)]) }
        }
    }
    func ready(_ values: [String: Any]) {
        var value = values
        value["section"] = section.rawValue
        value["scenario"] = scenario
        value["dark"] = browser.isVideoPage
        if section != .browser, let window {
            let page = browser.webView
            let frame = page.convert(page.bounds, to:window)
            let inset = page.scrollView.contentInset
            value["underlapsChrome"] = frame.minY < window.safeAreaInsets.top
                && frame.maxY > window.bounds.height - window.safeAreaInsets.bottom
            value["contentInsets"] = [inset.top, inset.bottom]
            value["pageFrame"] = [frame.minX,frame.minY,frame.width,frame.height]
            value["scrollOffset"] = page.scrollView.contentOffset.y
            value["glassSample"] = [window.bounds.width * 0.2,window.safeAreaInsets.top + 12,window.bounds.width * 0.6,4]
            if value["underlapsChrome"] as? Bool != true || inset.top < window.safeAreaInsets.top + 44
                || inset.bottom < window.safeAreaInsets.bottom + 44 {
                value["error"] = "Web page does not extend behind glass, or visible content insets are missing"
            }
            if scenario == "community", abs(page.scrollView.contentOffset.y + inset.top) > 2 {
                value["error"] = "Initial community content is hidden behind the top controls"
            }
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ready.json")
        try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
}
'''
(OUT / 'PreviewApp.swift').write_text(harness)
info = {'CFBundleExecutable': 'BrowserUIPreview', 'CFBundleIdentifier': 'com.tians.browser-ui-check',
        'CFBundleName': 'Browser UI Check', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1],
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait']}
(BUNDLE / 'Info.plist').write_bytes(plistlib.dumps(info))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
                '-target', platform.machine() + '-apple-ios16.0-simulator',
                str(ROOT / 'Recorder.swiftpm/Sources/RecorderSettings.swift'),
                str(ROOT / 'Recorder.swiftpm/Sources/GlassStyle.swift'),
                str(ROOT / 'Recorder.swiftpm/Sources/BrowserView.swift'), str(OUT / 'PreviewApp.swift'),
                '-o', str(BUNDLE / 'BrowserUIPreview')], check=True, env=dict(os.environ, SDKROOT=sdk))
subprocess.run(['codesign', '--sign', '-', '--force', str(BUNDLE)], check=True)
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
choices = [(runtime, device) for runtime, items in devices.items() if '.iOS-' in runtime
           for device in items if device.get('isAvailable') and device['name'].startswith('iPhone')]
assert choices, 'No available iPhone simulator runtime'
runtime, device = sorted(choices, key=lambda item: ('Pro Max' in item[1]['name'], item[0], item[1]['name']))[-1]
device_id = device['udid']
booted = device['state'] != 'Booted'
if booted: subprocess.run(['xcrun', 'simctl', 'boot', device_id], check=True)
try:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device_id, '-b'], check=True)
    subprocess.run(['xcrun', 'simctl', 'status_bar', device_id, 'override', '--time', '9:41',
                    '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
                    '--batteryState', 'charged', '--batteryLevel', '100'], check=True)
    subprocess.run(['xcrun', 'simctl', 'install', device_id, str(BUNDLE)], check=True)
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device_id, info['CFBundleIdentifier'], 'data'], text=True).strip())
    results = []
    for section in ['community', 'videos', 'browser', 'glass-blue', 'glass-orange']:
        subprocess.run(['xcrun', 'simctl', 'terminate', device_id, info['CFBundleIdentifier']], capture_output=True)
        ready = container / 'Documents/ready.json'
        if ready.exists(): ready.unlink()
        subprocess.run(['xcrun', 'simctl', 'launch', device_id, info['CFBundleIdentifier'], section], check=True)
        deadline = time.monotonic() + 25
        while not ready.exists() and time.monotonic() < deadline: time.sleep(0.25)
        assert ready.exists(), f'Native {section} preview did not become ready'
        result = json.loads(ready.read_text())
        assert 'error' not in result and result['scenario'] == section, result
        assert result['dark'] == (section == 'videos'), result
        subprocess.run(['xcrun', 'simctl', 'io', device_id, 'screenshot', str(OUT / f'{section}.png')], check=True)
        results.append(result)
        if not section.startswith('glass-'):
            print(f'PASS: actual SwiftUI BrowserView rendered in iOS Simulator for {section}, with production WebKit and synthetic page content')
    pixels = r'''
import Cocoa
let values = CommandLine.arguments.dropFirst(3).map { Double($0)! }
var means: [[Double]] = []
for file in CommandLine.arguments[1...2] {
    let bitmap = NSBitmapImageRep(data:try! Data(contentsOf:URL(fileURLWithPath:file)))!
    let scale = Double(bitmap.pixelsWide) / values[4]
    var sum = [0.0,0.0,0.0], count = 0.0
    for y in Int(values[1]*scale)..<Int((values[1]+values[3])*scale) {
        for x in Int(values[0]*scale)..<Int((values[0]+values[2])*scale) {
            let color = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            sum[0] += color.redComponent; sum[1] += color.greenComponent; sum[2] += color.blueComponent; count += 1
        }
    }
    means.append(sum.map { $0/count })
}
let difference = zip(means[0],means[1]).map { abs($0-$1) }.reduce(0,+)/3
print(String(data:try! JSONSerialization.data(withJSONObject:["meanRGB":means,"meanChannelDifference":difference]),encoding:.utf8)!)
'''
    (OUT / 'GlassPixels.swift').write_text(pixels)
    blue = next(r for r in results if r['scenario'] == 'glass-blue')
    orange = next(r for r in results if r['scenario'] == 'glass-orange')
    assert blue['scrollOffset'] == orange['scrollOffset'] == 200, (blue,orange)
    sample = [*blue['glassSample'],blue['pageFrame'][2]]
    change = json.loads(subprocess.check_output(['swift',str(OUT / 'GlassPixels.swift'),
        str(OUT / 'glass-blue.png'),str(OUT / 'glass-orange.png'),*map(str,sample)],text=True))
    assert change['meanChannelDifference'] > 0.01, ('Glass did not react to changed content behind it',change)
    print('PASS: native Liquid Glass changes its sampled color as scrolled WebKit content changes behind the same controls')
    (OUT / 'verification.json').write_text(json.dumps({'device':device['name'], 'runtime':runtime,
        'production_sources_unchanged':True, 'content':'synthetic fixtures; browser native start page',
        'physical_device_test':False, 'sections':results,'dynamic_glass':change}, indent=2))
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', device_id, info['CFBundleIdentifier']], capture_output=True)
    if booted: subprocess.run(['xcrun', 'simctl', 'shutdown', device_id], check=True)
