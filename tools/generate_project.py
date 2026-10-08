"""Wrap the existing App Playground sources in a native, unsigned Xcode target.

Only Python's standard library is needed. Apple credentials are not used here.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / 'Recorder.swiftpm'


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def openstep(value):
    if isinstance(value, dict):
        return '{\n' + '\n'.join(f'{json.dumps(k)} = {openstep(v)};' for k, v in value.items()) + '\n}'
    if isinstance(value, list):
        return '(' + ', '.join(openstep(v) for v in value) + ')'
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    manifest = (PACKAGE / 'Package.swift').read_text(encoding='utf-8')
    def field(name):
        return re.search(r'\b' + name + r':\s*"([^"]+)"', manifest).group(1)
    info = {
        'CFBundleDevelopmentRegion': 'zh_CN', 'CFBundleDisplayName': '随录',
        'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': '$(PRODUCT_NAME)',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': field('displayVersion'),
        'CFBundleVersion': field('bundleVersion'), 'LSRequiresIPhoneOS': True,
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'UIApplicationSupportsIndirectInputEvents': True, 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait',
            'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft',
            'UIInterfaceOrientationLandscapeRight'],
    }
    for capability, key in [('camera', 'NSCameraUsageDescription'),
                            ('microphone', 'NSMicrophoneUsageDescription'),
                            ('photoLibraryAdd', 'NSPhotoLibraryAddUsageDescription'),
                            ('locationWhenInUse', 'NSLocationWhenInUseUsageDescription')]:
        info[key] = re.search(r'\.' + capability + r'\(purposeString:\s*"([^"]+)"', manifest).group(1)
    info.update(plistlib.loads((PACKAGE / 'AdditionalInfo.plist').read_bytes()))
    assert info['UIBackgroundModes'] == ['audio']
    config = ROOT / 'Config'
    config.mkdir(exist_ok=True)
    (config / 'Info.plist').write_bytes(plistlib.dumps(info))
    objects = {}
    def add(label, isa, **values):
        key = identifier(label)
        assert key not in objects
        objects[key] = {'isa': isa, **values}
        return key
    sources = sorted((PACKAGE / 'Sources').glob('*.swift'))
    assert len(sources) == 13 and sum('@main' in p.read_text(encoding='utf-8') for p in sources) == 1
    refs, files = [], []
    for path in sources:
        ref = add('source:' + path.name, 'PBXFileReference', lastKnownFileType='sourcecode.swift',
                  path=path.name, sourceTree='<group>')
        refs.append(ref)
        files.append(add('build:' + path.name, 'PBXBuildFile', fileRef=ref))
    source_group = add('sources', 'PBXGroup', children=refs, path='Recorder.swiftpm/Sources', sourceTree='<group>')
    assets = add('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog',
                 path='Assets.xcassets', sourceTree='<group>')
    asset_build = add('build-assets', 'PBXBuildFile', fileRef=assets)
    resource_group = add('resources', 'PBXGroup', children=[assets], path='Recorder.swiftpm/Resources', sourceTree='<group>')
    info_ref = add('info', 'PBXFileReference', lastKnownFileType='text.plist.xml', path='Info.plist', sourceTree='<group>')
    config_group = add('config', 'PBXGroup', children=[info_ref], path='Config', sourceTree='<group>')
    product = add('product', 'PBXFileReference', explicitFileType='wrapper.application',
                  includeInIndex='0', path='Recorder.app', sourceTree='BUILT_PRODUCTS_DIR')
    products = add('products', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
    main = add('main', 'PBXGroup', children=[source_group, resource_group, config_group, products], sourceTree='<group>')
    source_phase = add('source-phase', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=files, runOnlyForDeploymentPostprocessing='0')
    resource_phase = add('resource-phase', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=[asset_build], runOnlyForDeploymentPostprocessing='0')
    framework_phase = add('framework-phase', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
    project_configs, target_configs = [], []
    for name in ['Debug', 'Release']:
        project_configs.append(add('project-' + name, 'XCBuildConfiguration', name=name, buildSettings={
            'CLANG_ENABLE_MODULES': 'YES', 'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0'}))
        settings = {
            'PRODUCT_NAME': 'Recorder', 'PRODUCT_BUNDLE_IDENTIFIER': field('bundleIdentifier'),
            'INFOPLIST_FILE': 'Config/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'SWIFT_VERSION': '5.0',
            'SWIFT_STRICT_CONCURRENCY': 'minimal', 'TARGETED_DEVICE_FAMILY': '1,2',
            'CODE_SIGNING_ALLOWED': 'NO', 'CODE_SIGNING_REQUIRED': 'NO',
            'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
            'SUPPORTS_MACCATALYST': 'NO', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
            'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O',
        }
        target_configs.append(add('target-' + name, 'XCBuildConfiguration', name=name, buildSettings=settings))
    project_list = add('project-configs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
    target_list = add('target-configs', 'XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
    target = add('target', 'PBXNativeTarget', buildConfigurationList=target_list,
                 buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[],
                 name='Recorder', productName='Recorder', productReference=product,
                 productType='com.apple.product-type.application')
    project_id = add('project', 'PBXProject', buildConfigurationList=project_list, compatibilityVersion='Xcode 14.0',
        developmentRegion='zh_CN', hasScannedForEncodings='0', knownRegions=['zh_CN', 'en', 'Base'],
        mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
    # Validate every object link before submitting anything to Xcode.
    for value in objects.values():
        for key in ['fileRef', 'buildConfigurationList', 'productReference', 'mainGroup', 'productRefGroup']:
            if key in value: assert value[key] in objects
        for key in ['children', 'files', 'buildPhases', 'buildConfigurations', 'targets']:
            for ref in value.get(key, []): assert ref in objects
    project = ROOT / 'Recorder.xcodeproj'
    project.mkdir(exist_ok=True)
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + openstep({
        'archiveVersion': '1', 'classes': {}, 'objectVersion': '56',
        'objects': objects, 'rootObject': project_id}), encoding='utf-8')
    scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')
    build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
    entries = ET.SubElement(build, 'BuildActionEntries')
    entry = ET.SubElement(entries, 'BuildActionEntry', **{k: 'YES' for k in [
        'buildForTesting', 'buildForRunning', 'buildForProfiling', 'buildForArchiving', 'buildForAnalyzing']})
    def reference(parent):
        return ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=target,
            BuildableName='Recorder.app', BlueprintName='Recorder', ReferencedContainer='container:Recorder.xcodeproj')
    reference(entry)
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug',
        selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
        selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', allowLocationSimulation='YES')
    reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'))
    ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
    scheme_path = project / 'xcshareddata/xcschemes'
    scheme_path.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(scheme_path / 'Recorder.xcscheme', encoding='utf-8', xml_declaration=True)
    assert ET.parse(scheme_path / 'Recorder.xcscheme').getroot().tag == 'Scheme'
    print(f'Generated native Xcode project: {len(sources)} production Swift files; no Apple credentials required')


if __name__ == '__main__':
    generate()
