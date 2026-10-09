"""Exercise the unchanged production gallery/controller with native XCUITest.

Only the entry point is replaced with a four-item fixture in a separate app
sandbox. It never opens the camera or installs anything on a physical device.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
from generate_project import generate, identifier, openstep

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/library-ui-check'
APP_ID = 'com.tians.library-ui-check'
UI_OUT = ROOT / 'build/ui-preview'

app_source = r'''
import CryptoKit
import SwiftUI
import UIKit

@main @MainActor struct LibraryFixtureApp: App {
    @StateObject private var recorder: RecorderController
    init() {
        try! Self.makeFixtures()
        _recorder = StateObject(wrappedValue: RecorderController())
    }
    var body: some Scene { WindowGroup { LibraryView(recorder:recorder) } }
    static func makeFixtures() throws {
        precondition(Bundle.main.bundleIdentifier == "com.tians.library-ui-check")
        try MediaLibrary.prepare()
        let kinds: [CaptureMode] = [.photo,.video,.livePhoto,.photo]
        let colors: [UIColor] = [.systemIndigo,.systemTeal,.systemOrange,.systemBlue]
        var records: [[String:Any]] = []
        for index in 0..<4 {
            let id = UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",101+index))!
            let item = MediaItem(id:id,kind:kinds[index],createdAt:Date(timeIntervalSince1970:1700000000+Double(index)),
                camera:"测试内容",resolution:"400 × 300",fps:nil,hasAudio:false,location:nil)
            // Only these known fixture IDs inside this separate app are reset.
            if FileManager.default.fileExists(atPath:item.folder.path) { try FileManager.default.removeItem(at:item.folder) }
            let folder = try MediaLibrary.begin(item)
            let image = UIGraphicsImageRenderer(size:CGSize(width:400,height:300)).image { context in
                colors[index].setFill(); context.fill(CGRect(x:0,y:0,width:400,height:300))
                let symbol = UIImage(systemName:kinds[index] == .video ? "video.fill" : "photo.fill")!.withTintColor(.white,renderingMode:.alwaysOriginal)
                symbol.draw(in:CGRect(x:140,y:85,width:120,height:110))
            }.jpegData(compressionQuality:0.9)!
            for resource in item.resourceURLs {
                let data = resource.pathExtension == "jpg" ? image : Data("Synthetic movie \(id)".utf8)
                try data.write(to:folder.appendingPathComponent(resource.lastPathComponent))
            }
            try image.write(to:folder.appendingPathComponent("thumbnail.jpg"))
            try MediaLibrary.finish(item)
            let resources = try item.resourceURLs.map { url -> [String:String] in
                let hash = SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
                return ["path":url.path,"sha256":hash]
            }
            records.append(["id":id.uuidString,"resources":resources])
        }
        let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try JSONSerialization.data(withJSONObject:["libraryRoot":MediaLibrary.directory.path,"items":records])
            .write(to:documents.appendingPathComponent("library-fixture.json"))
    }
}
'''

test_source = r'''
import XCTest

final class LibraryUITests: XCTestCase {
    let app = XCUIApplication()
    func item(_ value: Int) -> XCUIElement { app.buttons[String(format:"library-item-00000000-0000-0000-0000-%012d",value)] }
    func attach(_ name: String) {
        let image = XCTAttachment(screenshot:app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func count(_ value: Int) { XCTAssertTrue(app.staticTexts["已选择 \(value) 项"].waitForExistence(timeout:5)) }
    func testLongPressMultiSelectExportAndDelete() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        XCTAssertTrue(item(101).waitForExistence(timeout:10))
        item(101).tap()
        XCTAssertTrue(app.navigationBars["拍摄详情"].waitForExistence(timeout:5))
        app.navigationBars["拍摄详情"].buttons.element(boundBy:0).tap()
        item(101).press(forDuration:0.8); count(1)
        XCTAssertEqual(item(101).value as? String,"已选中")
        XCTAssertFalse(app.navigationBars["拍摄详情"].exists)
        item(103).tap(); count(2)
        item(103).tap(); count(1)
        item(103).tap(); count(2)
        app.segmentedControls.buttons["拍照"].tap(); count(0)
        XCTAssertFalse(app.buttons["library-delete"].isEnabled)
        app.buttons["全选当前结果"].tap(); count(2)
        app.buttons["library-select"].tap()
        app.segmentedControls.buttons["全部"].tap()
        item(101).press(forDuration:0.8); item(103).tap(); count(2)
        attach("library-selection")
        app.buttons["library-export"].tap()
        XCTAssertTrue(app.buttons["导出到系统照片"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["原件与拍摄信息"].exists)
        attach("library-export-options")
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        count(2)
        app.buttons["library-delete"].tap()
        XCTAssertTrue(app.buttons["删除 2 项"].waitForExistence(timeout:5))
        attach("library-delete-confirmation")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else { app.navigationBars.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap() }
        count(2)
        XCTAssertTrue(item(101).exists && item(103).exists && item(102).exists && item(104).exists)
        app.buttons["library-delete"].tap()
        app.buttons["删除 2 项"].tap()
        XCTAssertTrue(app.navigationBars["内置图库 · 2"].waitForExistence(timeout:10))
        XCTAssertFalse(item(101).exists || item(103).exists)
        XCTAssertTrue(item(102).exists && item(104).exists)
        app.buttons["全选当前结果"].tap(); count(2)
        attach("library-after-delete")
    }
}
'''


def run(device):
    OUT.mkdir(parents=True, exist_ok=True)
    UI_OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'LibraryFixtureApp.swift').write_text(app_source)
    (OUT / 'LibraryUITests.swift').write_text(test_source)
    generate()
    project = ROOT / 'Recorder.xcodeproj'
    pbx = project / 'project.pbxproj'
    data = json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(pbx)]))
    objects = data['objects']
    app_target = identifier('target')
    objects[identifier('source:RecorderApp.swift')].update(path=str(OUT/'LibraryFixtureApp.swift'),sourceTree='<absolute>')
    objects[app_target]['buildPhases'].remove(identifier('embed-controls'))
    objects[app_target]['dependencies'] = []
    for name in ['Debug','Release']:
        objects[identifier('target-'+name)]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = APP_ID
    def add(label, isa, **values):
        key = identifier('library-ui:'+label)
        assert key not in objects
        objects[key] = {'isa':isa,**values}
        return key
    ref = add('source','PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(OUT/'LibraryUITests.swift'),sourceTree='<absolute>')
    objects[identifier('main')]['children'].append(ref)
    build = add('build','PBXBuildFile',fileRef=ref)
    phase = add('sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=[build],runOnlyForDeploymentPostprocessing='0')
    framework = add('frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0')
    product = add('product','PBXFileReference',explicitFileType='wrapper.cfbundle',includeInIndex='0',path='LibraryUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
    objects[identifier('products')]['children'].append(product)
    config = add('Debug','XCBuildConfiguration',name='Debug',buildSettings={
        'PRODUCT_NAME':'LibraryUITests','PRODUCT_BUNDLE_IDENTIFIER':'com.tians.library-ui-tests',
        'GENERATE_INFOPLIST_FILE':'YES','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal',
        'SDKROOT':'iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET':'16.0','TARGETED_DEVICE_FAMILY':'1,2',
        'CODE_SIGNING_ALLOWED':'NO','CODE_SIGNING_REQUIRED':'NO','TEST_TARGET_NAME':'Recorder',
    })
    configs = add('configs','XCConfigurationList',buildConfigurations=[config],defaultConfigurationName='Debug',defaultConfigurationIsVisible='0')
    proxy = add('proxy','PBXContainerItemProxy',containerPortal=data['rootObject'],proxyType='1',remoteGlobalIDString=app_target,remoteInfo='Recorder')
    dependency = add('dependency','PBXTargetDependency',target=app_target,targetProxy=proxy)
    target = add('target','PBXNativeTarget',name='LibraryUITests',productName='LibraryUITests',productReference=product,
        buildConfigurationList=configs,buildPhases=[phase,framework],buildRules=[],dependencies=[dependency],productType='com.apple.product-type.bundle.ui-testing')
    objects[data['rootObject']]['targets'] = [app_target,target]
    pbx.write_text('// !$*UTF8*$!\n'+openstep(data))
    scheme = ET.Element('Scheme',version='1.3',LastUpgradeVersion='2630')
    def reference(parent, identifier, name, product):
        return ET.SubElement(parent,'BuildableReference',BuildableIdentifier='primary',BlueprintIdentifier=identifier,
            BuildableName=product,BlueprintName=name,ReferencedContainer='container:Recorder.xcodeproj')
    action = ET.SubElement(scheme,'BuildAction',parallelizeBuildables='YES',buildImplicitDependencies='YES')
    entries = ET.SubElement(action,'BuildActionEntries')
    for key,name,product_name in [(app_target,'Recorder','Recorder.app'),(target,'LibraryUITests','LibraryUITests.xctest')]:
        entry = ET.SubElement(entries,'BuildActionEntry',buildForTesting='YES',buildForRunning='NO',buildForProfiling='NO',buildForArchiving='NO',buildForAnalyzing='NO')
        reference(entry,key,name,product_name)
    testing = ET.SubElement(scheme,'TestAction',buildConfiguration='Debug',shouldUseLaunchSchemeArgsEnv='YES',
        selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB')
    reference(ET.SubElement(testing,'MacroExpansion'),app_target,'Recorder','Recorder.app')
    testable = ET.SubElement(ET.SubElement(testing,'Testables'),'TestableReference',skipped='NO')
    reference(testable,target,'LibraryUITests','LibraryUITests.xctest')
    ET.ElementTree(scheme).write(project/'xcshareddata/xcschemes/LibraryCheck.xcscheme',encoding='utf-8',xml_declaration=True)
    result = OUT / 'Library.xcresult'
    assert not result.exists(), 'Use a fresh build folder for this check'
    command = ['xcodebuild','test','-project',str(project),'-scheme','LibraryCheck','-sdk','iphonesimulator',
        '-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO',
        '-derivedDataPath',str(OUT/'DerivedData'),'-resultBundlePath',str(result),
        'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO']
    completed = subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    (OUT/'xcodebuild.log').write_text(completed.stdout)
    if completed.returncode: print(completed.stdout[-24000:])
    attachments = UI_OUT / 'library-attachments'
    if result.exists():
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(attachments)],check=True)
    completed.check_returncode()
    container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,APP_ID,'data'],text=True).strip()).resolve()
    fixture = json.loads((container/'Documents/library-fixture.json').read_text())
    assert Path(fixture['libraryRoot']).resolve().is_relative_to(container)
    deleted = {'00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000103'}
    for item in fixture['items']:
        for resource in item['resources']:
            path = Path(resource['path']).resolve()
            assert path.is_relative_to(container)
            if item['id'] in deleted: assert not path.exists(), path
            else: assert hashlib.sha256(path.read_bytes()).hexdigest() == resource['sha256'], path
    assert len([p for p in attachments.rglob('*') if p.suffix.lower() in ['.png','.jpg','.jpeg']]) >= 4, 'Expected native selection/export/confirmation/after-delete screenshots'
    (UI_OUT/'library-verification.json').write_text(json.dumps({'production_gallery_controller_unchanged':True,
        'fixture_app_id':APP_ID,'physical_device_test':False,'native_ui_test':'passed',
        'workflow':'tap detail; long press selects without opening; multi-select/toggle; filter clears; select all; export menu; cancel/confirm bulk delete',
        'synthetic_items_deleted':sorted(deleted),'unselected_originals_unchanged':True},indent=2))
    print('PASS: actual native gallery long-press/tap selection, filtered select-all, export menu, cancelled and confirmed bulk deletion; paired Live Photo removed and unselected original hashes unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--device',required=True)
    args = parser.parse_args()
    run(args.device)
