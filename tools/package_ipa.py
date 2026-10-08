"""Package an actual arm64 iPhoneOS build, never a simulator / source ZIP."""
from pathlib import Path
import hashlib
import json
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parent.parent
app = ROOT / 'build/DerivedData/Build/Products/Release-iphoneos/Recorder.app'
assert app.is_dir(), 'Device App build is missing'
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
assert info['UIBackgroundModes'] == ['audio']
for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
            'NSPhotoLibraryAddUsageDescription', 'NSLocationWhenInUseUsageDescription']:
    assert info.get(key), f'Missing purpose string: {key}'
executable = app / info['CFBundleExecutable']
magic, cpu = struct.unpack('<II', executable.read_bytes()[:8])
assert magic == 0xFEEDFACF and cpu == 0x0100000C, 'Expected a real arm64 Mach-O executable'
output = ROOT / 'build/artifacts'
output.mkdir(parents=True, exist_ok=True)
ipa = output / f'Recorder-{info["CFBundleShortVersionString"]}-unsigned.ipa'
files = sorted(p for p in app.rglob('*') if p.is_file())
assert files and not any(p.is_symlink() for p in app.rglob('*'))
with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, 'Payload/Recorder.app/' + path.relative_to(app).as_posix())
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist()) == len(files)
result = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'bundle_identifier': info['CFBundleIdentifier'], 'platform': 'iPhoneOS', 'architecture': 'arm64',
    'ipa_bytes': ipa.stat().st_size, 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
    'signing': 'unsigned; sign locally with your own account before installing',
    'hardware_test': 'not run'}
(output / 'build-verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
