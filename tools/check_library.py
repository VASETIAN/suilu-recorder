"""Replay production selection/deletion methods; storage uses disposable fixtures.

Queues are controlled and one delete failure is injected. No user files,
Photos permission or actual SwiftUI gestures are tested by this script.
"""
from pathlib import Path
import argparse
import re
import subprocess
from check_lifecycle import extract

ROOT = Path(__file__).resolve().parent.parent


def build(output):
    sources = ROOT / 'Recorder.swiftpm/Sources'
    view = (sources / 'LibraryView.swift').read_text(encoding='utf-8')
    controller = (sources / 'RecorderController.swift').read_text(encoding='utf-8')
    library = (sources / 'MediaLibrary.swift').read_text(encoding='utf-8')
    library = re.sub(r'static var root: URL \{.*?\n    \}', 'static var root: URL { checkDirectory }', library, count=1, flags=re.S)
    library = library.replace('enum MediaLibrary {', 'enum DiskLibrary {')
    library = library.replace('FileManager.default.temporaryDirectory', 'checkDirectory')
    settings = (sources / 'RecorderSettings.swift').read_text(encoding='utf-8')
    selection = '\n'.join(extract(view, name) for name in ['private func beginSelection(', 'private func openOrSelect('])
    methods = '\n'.join(extract(controller, name) for name in ['func deleteMedia(_ item:', 'func deleteMedia(_ items:', 'func prepareShare('])
    assert '!deletingMediaIDs.contains($0.id)' in extract(controller, 'func exportToPhotos(_ items:')
    swift = r'''
import Foundation
let checkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderLibraryCheck-"+UUID().uuidString)
SETTINGS
LIBRARY
enum MediaLibrary {
    static var directory: URL { DiskLibrary.directory }
    static var failureID: UUID?
    static func delete(_ item: MediaItem) throws {
        if item.id == failureID { throw LibraryError("Injected storage failure") }
        try DiskLibrary.delete(item)
    }
    static func prepareExport(_ items: [MediaItem]) throws -> MediaExport { try DiskLibrary.prepareExport(items) }
}
final class Queue {
    var work: [() -> Void] = []
    func async(_ action: @escaping () -> Void) { work.append(action) }
    func drain() { while !work.isEmpty { work.removeFirst()() } }
}
final class Selection {
    var selecting = false, selectedIDs: Set<UUID> = [], path: [UUID] = []
    SELECTION
    func longPress(_ id: UUID) { beginSelection(id) }
    func tap(_ id: UUID) { openOrSelect(id) }
}
final class Recorder {
    let captureQueue = Queue(), uiQueue = Queue(), mediaQueue = Queue()
    var canConfigure = true, capturePhase: RecordingPhase = .idle
    var libraryItems: [MediaItem] = [], deletingMediaIDs: Set<UUID> = [], exportingPhotoIDs: Set<UUID> = []
    var preparingShare = false, shareExport: MediaExport?, preparedShare: MediaExport?
    var messages: [String] = []
    func publish(_ action: @escaping () -> Void) { uiQueue.async(action) }
    func showMessage(_ title: String, _ detail: String) { messages.append(title+detail) }
    func report(_ title: String, _ detail: String) { publish { self.showMessage(title,detail) } }
    func refreshLibraryOnQueue() { let values = DiskLibrary.items(); publish { self.libraryItems = values } }
    METHODS
}
try FileManager.default.createDirectory(at: checkDirectory,withIntermediateDirectories:false)
defer { try? FileManager.default.removeItem(at:checkDirectory) }
let original = Data([0,1,2,5,7,128,255])
func make(_ kind: CaptureMode) throws -> MediaItem {
    let item = MediaItem(id:UUID(),kind:kind,createdAt:Date(),camera:"fixture",resolution:"fixture",fps:nil,hasAudio:false,location:nil)
    let folder = try DiskLibrary.begin(item)
    for resource in item.resourceURLs { try original.write(to:folder.appendingPathComponent(resource.lastPathComponent)) }
    try DiskLibrary.finish(item)
    return item
}
let photo = try make(.photo), movie = try make(.video), live = try make(.livePhoto)
let selected = Selection()
selected.tap(photo.id); assert(selected.path == [photo.id] && !selected.selecting)
selected.path = []
selected.longPress(photo.id); selected.longPress(photo.id)
assert(selected.selecting && selected.selectedIDs == [photo.id] && selected.path.isEmpty)
selected.tap(live.id); assert(selected.selectedIDs == [photo.id,live.id] && selected.path.isEmpty)
selected.tap(photo.id); assert(selected.selectedIDs == [live.id])
print("PASS: production selection enters on long press, keeps the pressed item selected, toggles on taps, and opens details only outside selection mode")

let recorder = Recorder(); recorder.libraryItems = DiskLibrary.items()
recorder.exportingPhotoIDs = [photo.id]; recorder.deleteMedia([photo,live])
assert(recorder.deletingMediaIDs.isEmpty && recorder.captureQueue.work.isEmpty)
recorder.exportingPhotoIDs = []; recorder.preparingShare = true; recorder.deleteMedia(photo)
assert(recorder.deletingMediaIDs.isEmpty); recorder.preparingShare = false
recorder.shareExport = MediaExport(folder:checkDirectory,urls:[]); recorder.deleteMedia(photo)
assert(recorder.deletingMediaIDs.isEmpty); recorder.shareExport = nil
recorder.canConfigure = false; recorder.deleteMedia(photo)
assert(recorder.deletingMediaIDs.isEmpty); recorder.canConfigure = true
recorder.deleteMedia([photo,photo,live])
assert(recorder.deletingMediaIDs == [photo.id,live.id] && recorder.captureQueue.work.count == 1)
recorder.prepareShare([photo]); assert(!recorder.preparingShare && recorder.mediaQueue.work.isEmpty)
recorder.deleteMedia(movie); assert(recorder.captureQueue.work.count == 1)
recorder.capturePhase = .recording; recorder.captureQueue.drain(); recorder.uiQueue.drain()
assert(recorder.deletingMediaIDs.isEmpty && DiskLibrary.items().count == 3)
recorder.capturePhase = .idle; recorder.messages = []
MediaLibrary.failureID = photo.id
recorder.deleteMedia([photo,photo,live]); recorder.captureQueue.drain(); recorder.uiQueue.drain()
assert(recorder.deletingMediaIDs.isEmpty && recorder.libraryItems.count == 2)
assert(recorder.libraryItems.contains(where:{$0.id == photo.id}) && recorder.libraryItems.contains(where:{$0.id == movie.id}))
assert(!FileManager.default.fileExists(atPath:live.folder.path))
assert(recorder.messages.count == 1 && recorder.messages[0].contains("已删除 1 项，1 项未删除"))
for resource in photo.resourceURLs+movie.resourceURLs { assert(try Data(contentsOf:resource) == original) }
MediaLibrary.failureID = nil
recorder.deleteMedia([photo]); recorder.captureQueue.drain(); recorder.uiQueue.drain()
assert(recorder.libraryItems.map(\.id) == [movie.id] && recorder.deletingMediaIDs.isEmpty)
assert(try Data(contentsOf:movie.movieURL) == original)
recorder.deleteMedia([]); recorder.deleteMedia([photo]); assert(recorder.captureQueue.work.isEmpty)
print("PASS: production bulk deletion de-duplicates IDs, protects active export/share/capture, clears busy state after a queue race, reports partial failure, removes both Live Photo resources, retries failure and preserves unselected originals")
'''.replace('SETTINGS', settings).replace('LIBRARY', library).replace('SELECTION', selection).replace('METHODS', methods)
    # Throwing reads cannot be placed inside assert's non-throwing autoclosure.
    swift = swift.replace('assert(try Data(contentsOf:resource) == original)', 'let bytes = try Data(contentsOf:resource); assert(bytes == original)')
    swift = swift.replace('assert(try Data(contentsOf:movie.movieURL) == original)', 'let bytes = try Data(contentsOf:movie.movieURL); assert(bytes == original)')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(swift, encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=ROOT/'build/library-check.swift')
    parser.add_argument('--generate-only',action='store_true')
    args = parser.parse_args()
    build(args.output)
    if not args.generate_only: subprocess.run(['swift',str(args.output)],check=True)
