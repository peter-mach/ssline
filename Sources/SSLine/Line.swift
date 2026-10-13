import AppKit
import Combine
import os
import SwiftUI

let log = Logger(subsystem: "app.ssline.SSLine", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Known before the thumbnail is made, so the card can be laid out at once.
    var pixelSize: CGSize
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    let hungAt: Date
    /// Bumped when the file changed, so the card loads the new pixels.
    var version = 0
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false {
        didSet {
            gustTimer?.invalidate()
            gustTimer = nil
            if revealed { scheduleGust() }
        }
    }

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch the mouse where the photos hang, and to know
    /// where a capture lands.
    var hitRects: [UUID: CGRect] = [:] {
        didSet { hitBottom = hitRects.values.reduce(nil) { max($0 ?? $1.maxY, $1.maxY) } }
    }
    private(set) var hitBottom: CGFloat?

    private let thumbs = NSCache<NSString, NSImage>()
    private var gustTimer: Timer?

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.reduce(0) { $0 + ($1.falling ? 0 : 1) } }

    private let storeKey = "pegged"

    init() {
        thumbs.totalCostLimit = 24 * 1024 * 1024
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let size = imagePixelSize(url) else { return nil }
        var item = Pegged(url: url, pixelSize: size, hungAt: Date())
        item.flying = flying
        // Not animated: the strip takes its new width at once, so scrolling to
        // the new card and measuring where the capture lands see the final
        // layout instead of one still sliding.
        withTransaction(\.disablesAnimations, true) { items.insert(item, at: 0) }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    func hangExisting(_ urls: [URL], restoring: Bool) async {
        let firstID = items.first?.id
        let saved = restoring ? UserDefaults.standard.stringArray(forKey: storeKey) ?? [] : []
        var known = Set(items.filter { !$0.falling }.map(\.url))
        let pending = (saved.reversed().map { URL(fileURLWithPath: $0) } + urls)
            .filter { known.insert($0).inserted }
        let batch = await Task.detached(priority: .utility) {
            pending.compactMap { url -> Pegged? in
                autoreleasepool {
                    guard let size = imagePixelSize(url) else { return nil }
                    return Pegged(url: url, pixelSize: size, hungAt: .distantPast)
                }
            }
        }.value
        guard !Task.isCancelled else { return }
        let live = Set(items.filter { !$0.falling }.map(\.url))
        let additions = batch.reversed().filter { !live.contains($0.url) }
        guard !additions.isEmpty else { return }
        let index = firstID.flatMap { id in items.firstIndex { $0.id == id } } ?? items.endIndex
        withTransaction(\.disablesAnimations, true) { items.insert(contentsOf: additions, at: index) }
        save()
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// Inbox files go to the Trash as well, or the folder would hang them
    /// all again at the next launch. The caller confirms first.
    func clear() {
        let live = items.filter { !$0.falling }
        let doomed = live.filter { isInInbox($0.id) }.map(\.url)
        if !doomed.isEmpty {
            if soundOn { Line.trashSound?.play() }
            DispatchQueue.global(qos: .utility).async {
                for url in doomed { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
        }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(min(n, 20))) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune(listings: [URL: Set<String>]) {
        for item in items where !item.falling {
            let folder = item.url.deletingLastPathComponent().standardizedFileURL
            let exists = listings[folder]?.contains(item.url.path)
                ?? FileManager.default.fileExists(atPath: item.url.path)
            if !exists { drop(item.id, quietly: true) }
        }
    }

    func prune(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              !FileManager.default.fileExists(atPath: item.url.path) else { return }
        drop(id, quietly: true)
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        if let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in SSLine's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let size = imagePixelSize(url) else { return }
        thumbs.removeObject(forKey: url.path as NSString)
        items[i].pixelSize = size
        items[i].version += 1
    }

    /// Made off the main thread; cards keep their own copy once loaded, so
    /// the cache only spares a reload when a card scrolls back into view.
    func thumbnail(for url: URL) async -> NSImage? {
        if let image = cachedThumbnail(for: url) { return image }
        let image = await Task.detached(priority: .utility) { makeThumbnail(url) }.value
        guard !Task.isCancelled else { return nil }
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            thumbs.setObject(image, forKey: url.path as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        thumbs.object(forKey: url.path as NSString)
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        gustTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 7...16), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.revealed else { return }
                if !self.hitRects.isEmpty && self.draggingID == nil { self.gust += 1 }
                self.scheduleGust()
            }
        }
    }

    // MARK: Persistence

    private var saveScheduled = false

    /// Coalesced: hanging a whole folder at start would otherwise write the
    /// list once per file.
    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let paths = self.items.filter { !$0.falling }.map(\.url.path)
            UserDefaults.standard.set(paths, forKey: self.storeKey)
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Read from the file's header, without decoding the image.
func imagePixelSize(_ url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
    // Orientations 5 to 8 turn the image a quarter, and thumbnails are made upright.
    let quarterTurn = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
    return quarterTurn ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
}

func makeThumbnail(_ url: URL, maxPixels: Int = 320) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
