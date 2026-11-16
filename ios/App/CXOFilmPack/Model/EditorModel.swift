import SwiftUI
import UIKit
import CxoShared

enum SheetKind: String, Identifiable {
    case library, adjust, grain, edge, export, contactSheet, settings, photos
    var id: String { rawValue }
}

/// What a batch apply/paste overwrote, so it can be undone.
struct BatchUndo {
    var text: String
    var items: [(id: UUID, look: Look, filmID: String)]
}

enum ExportScope: Hashable { case current, selected, all }

struct ExportStatus: Equatable {
    var text: String
    var ok: Bool
}

/// One open photograph with its own film and look.
struct Photo: Identifiable {
    let id = UUID()
    let source: SourceImage
    let name: String
    let thumb: PixelBuffer           // small display original (RAW Original tone when calibrated)
    let originalThumb: UIImage?
    var look = Look()
    var filmID: String
    var stripImage: UIImage?         // small render with this photo's look
    var sheetVertical = false        // contact sheet: stay upright (centre-cropped) instead of turning into the window
    var sheetCrop = SheetCrop()      // contact sheet: the user's framing
}

@MainActor @Observable
final class EditorModel {
    var runtime: FilmRuntime?
    var startupError: String?

    // Open photographs (Lightroom-style strip). `look` / `selectedFilm` mirror the current photo.
    var photos: [Photo] = []
    var currentID: UUID?
    var original: UIImage?
    var result: UIImage?
    var photoToken = 0

    var selectedFilm: FilmEntry? {
        didSet { if !isSwitching, selectedFilm != oldValue { commit(); scheduleRender() } }
    }
    var look = Look() {
        didSet { if !isSwitching, look != oldValue { commit(); scheduleRender() } }
    }

    var isRendering = false
    var message: String? = nil { didSet { scheduleMessageDismiss() } }
    var importProgress: String?
    var showOriginal = false
    var sheet: SheetKind? {
        didSet { if sheet != .photos && sheet != .export && sheet != .contactSheet { clearSelection() } }   // selection only lives with the grid / export sheets
    }
    var showPhotoPicker = false
    var showFileImporter = false

    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    var exportOptions = ExportOptions()
    var cameraRawPipeline = UserDefaults.standard.string(forKey: "cameraRawPipeline") ?? "original" {
        didSet {
            guard cameraRawPipeline != oldValue else { return }
            UserDefaults.standard.set(cameraRawPipeline, forKey: "cameraRawPipeline")
            thumbs.removeAll()
            queue.cancel(keyPrefix: "strip-")
            for i in photos.indices { photos[i].stripImage = nil }
            if let id = currentID { selectPhoto(id) }
            for photo in photos { refreshStrip(photo.id) }
        }
    }

    var isExporting = false
    var exportProgress = ""
    var exportedURLs: [URL] = []
    var exportStatus: ExportStatus?
    var clipboard: (look: Look, filmID: String)?

    // Multi-select (batch apply settings / batch export)
    var selection: Set<UUID> = []
    var lastBatch: BatchUndo?
    var photosPanelRequest = 0       // iPad: asks the side panel to switch to the photo grid

    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var previewBuffer: PixelBuffer?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let queue = RenderQueue()      // the only place rendering happens
    @ObservationIgnored private var thumbs: [String: UIImage] = [:]

    init() {
        do {
            let rt = try FilmRuntime()
            runtime = rt
            selectedFilm = rt.films.first
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// Toasts clear themselves: confirmations quickly, errors a bit later.
    private func scheduleMessageDismiss() {
        messageTask?.cancel()
        guard let text = message else { return }
        let isError = text.contains("：") || text.contains("失败") || text.contains("无法")
        let nanos: UInt64 = isError ? 6_000_000_000 : 2_500_000_000
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.message == text else { return }
            self.message = nil
        }
    }

    // MARK: Current photo

    var currentIndex: Int? { photos.firstIndex { $0.id == currentID } }
    var source: SourceImage? { currentIndex.map { photos[$0].source } }
    private var thumbBuffer: PixelBuffer? { currentIndex.map { photos[$0].thumb } }

    private func commit() {
        guard let i = currentIndex else { return }
        photos[i].look = look
        if let film = selectedFilm { photos[i].filmID = film.id }
    }

    // MARK: Importing

    /// Files are already on disk (temporary copies); decoding the full image waits until a photo is selected.
    func importPhotos(_ items: [(url: URL, name: String)]) {
        guard let runtime, let defaultFilm = runtime.films.first?.id else { return }
        let originalRaw = cameraRawPipeline == "original"
        Task {
            defer { importProgress = nil }
            var added: [Photo] = []
            for (n, item) in items.enumerated() {
                importProgress = "正在导入 \(n + 1) / \(items.count)…"
                do {
                    let source = try await Task.detached(priority: .userInitiated) { try SourceImage(url: item.url) }.value
                    let decoded = await queue.run(priority: .strip, runtime: runtime, film: nil, look: Look(),
                                                  input: { try source.makeBuffer(maxEdge: 360, runtime: runtime, originalRaw: originalRaw) },
                                                  finish: { $0 })
                    let thumb: PixelBuffer
                    switch decoded {
                    case .success(let buffer?): thumb = buffer
                    case .success(nil): continue
                    case .failure(let error): throw error
                    }
                    let photo = Photo(source: source, name: item.name, thumb: thumb, originalThumb: thumb.uiImage(), filmID: defaultFilm)
                    added.append(photo)
                } catch {
                    message = "\(item.name)：\(error.localizedDescription)"
                }
            }
            guard let first = added.first else { return }
            photos.append(contentsOf: added)
            selectPhoto(first.id)
        }
    }

    func selectPhoto(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }), let runtime else { return }
        let photo = photos[i]
        renderTask?.cancel()                    // drop any preview still queued for the previous photo
        queue.cancel(keyPrefix: "preview")
        isRendering = false
        isSwitching = true
        currentID = id
        look = photo.look
        selectedFilm = runtime.films.first { $0.id == photo.filmID } ?? runtime.films.first
        isSwitching = false
        previewBuffer = nil
        result = photo.stripImage
        original = photo.originalThumb
        photoToken += 1
        let selectionToken = photoToken
        message = nil
        let originalRaw = cameraRawPipeline == "original"
        Task {
            do {
                var decoded: PixelBuffer?
                let r = await queue.run(priority: .preview, key: "preview-original", runtime: runtime, film: nil, look: Look(),
                                        input: {
                                            let buffer = try photo.source.makeBuffer(maxEdge: 2000, runtime: runtime, originalRaw: originalRaw)
                                            decoded = buffer
                                            return buffer
                                        }, finish: { ($0.uiImage(), decoded!) })
                let buffer: PixelBuffer
                let display: UIImage?
                switch r {
                case .success(let pair?): display = pair.0; buffer = pair.1
                case .success(nil): return
                case .failure(let error): throw error
                }
                guard currentID == id, photoToken == selectionToken else { return }
                previewBuffer = buffer
                original = display
                scheduleRender()
            } catch {
                guard currentID == id, photoToken == selectionToken else { return }
                message = error.localizedDescription
            }
        }
    }

    func removePhoto(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = id == currentID
        photos.remove(at: i)
        selection.remove(id)
        queue.cancel(keyPrefix: "strip-\(id)")
        thumbs = thumbs.filter { !$0.key.hasPrefix("\(id)-") }
        guard wasCurrent else { return }
        renderTask?.cancel()
        queue.cancel(keyPrefix: "preview")
        if photos.isEmpty {
            currentID = nil; previewBuffer = nil; original = nil; result = nil; isRendering = false
        } else {
            selectPhoto(photos[min(i, photos.count - 1)].id)
        }
    }

    // MARK: Copy / paste / sync settings

    func copySettings(from id: UUID) {
        guard let p = photos.first(where: { $0.id == id }) else { return }
        clipboard = (p.look, p.filmID)
    }

    func pasteSettings(to id: UUID) {
        guard let c = clipboard else { return }
        apply(look: c.look, filmID: c.filmID, to: id)
    }

    /// Opens the all-photos grid for multi-select (iPad: in the side panel, otherwise a sheet), current photo picked.
    func openPhotoGrid(inPanel: Bool) {
        selection = currentID.map { [$0] } ?? []
        lastBatch = nil
        if inPanel { photosPanelRequest += 1 } else { sheet = .photos }
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        lastBatch = nil
    }

    private func snapshot(_ ids: [UUID]) -> [(id: UUID, look: Look, filmID: String)] {
        var out: [(id: UUID, look: Look, filmID: String)] = []
        for id in ids {
            if let p = photos.first(where: { $0.id == id }) { out.append((id: id, look: p.look, filmID: p.filmID)) }
        }
        return out
    }

    func undoLastBatch() {
        guard let batch = lastBatch else { return }
        for item in batch.items { apply(look: item.look, filmID: item.filmID, to: item.id) }
        lastBatch = nil
        message = "已撤销"
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAllPhotos() { selection = Set(photos.map(\.id)) }

    /// The current photo's film and look, applied to every selected photo.
    func applyCurrent(toSelected ids: Set<UUID>) {
        guard let currentID, let p = photos.first(where: { $0.id == currentID }) else { return }
        let targets = ids.filter { $0 != currentID }
        guard !targets.isEmpty else { message = "请先选中要应用的其他照片"; return }
        let before = snapshot(Array(targets))
        for id in targets { apply(look: p.look, filmID: p.filmID, to: id) }
        lastBatch = BatchUndo(text: "已应用到 \(targets.count) 张照片", items: before)
    }

    func pasteToSelected(_ ids: Set<UUID>) {
        guard let c = clipboard else { return }
        guard !ids.isEmpty else { message = "请先选中照片"; return }
        let before = snapshot(Array(ids))
        for id in ids { apply(look: c.look, filmID: c.filmID, to: id) }
        lastBatch = BatchUndo(text: "已粘贴设置到 \(ids.count) 张照片", items: before)
    }

    /// Turning vs staying upright changes the window's axes, so the framing starts over.
    func setSheetVertical(_ id: UUID, _ vertical: Bool) {
        guard let i = photos.firstIndex(where: { $0.id == id }), photos[i].sheetVertical != vertical else { return }
        photos[i].sheetVertical = vertical
        photos[i].sheetCrop = SheetCrop()
    }

    func setAllSheetVertical(_ vertical: Bool) {
        for photo in photos { setSheetVertical(photo.id, vertical) }
    }

    func setSheetCrop(_ id: UUID, _ crop: SheetCrop) {
        if let i = photos.firstIndex(where: { $0.id == id }), photos[i].sheetCrop != crop { photos[i].sheetCrop = crop }
    }

    func syncAll(from id: UUID) {
        guard let p = photos.first(where: { $0.id == id }) else { return }
        for other in photos where other.id != id { apply(look: p.look, filmID: p.filmID, to: other.id) }
    }

    private func apply(look newLook: Look, filmID: String, to id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }), let runtime else { return }
        if id == currentID {
            look = newLook
            selectedFilm = runtime.films.first { $0.id == filmID } ?? selectedFilm
        } else {
            photos[i].look = newLook
            photos[i].filmID = filmID
            refreshStrip(id)
        }
    }

    private func refreshStrip(_ id: UUID) {
        guard let runtime, let i = photos.firstIndex(where: { $0.id == id }),
              let film = runtime.films.first(where: { $0.id == photos[i].filmID }) else { return }
        let source = photos[i].source, look = photos[i].look
        let pipeline = cameraRawPipeline
        Task { [weak self] in
            guard let self else { return }
            let r = await self.queue.run(priority: .strip, key: "strip-\(id)", runtime: runtime, film: film, look: look,
                                         input: { try source.makeBuffer(maxEdge: 360, runtime: runtime, originalRaw: pipeline == "original") }, finish: { $0.uiImage() })
            if case .success(let image?) = r, let j = self.photos.firstIndex(where: { $0.id == id }),
               self.photos[j].look == look, self.photos[j].filmID == film.id, self.cameraRawPipeline == pipeline {
                self.photos[j].stripImage = image
            } else if case .failure(let error) = r, self.cameraRawPipeline == pipeline {
                self.message = error.localizedDescription
            }
        }
    }

    // MARK: Films

    func select(_ film: FilmEntry) { selectedFilm = film }

    func toggleFavorite(_ film: FilmEntry) {
        if favorites.contains(film.id) { favorites.remove(film.id) } else { favorites.insert(film.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func description(for film: FilmEntry) -> FilmDescription? { runtime?.descriptions[film.token] }

    func thumbnail(for film: FilmEntry) async -> UIImage? {
        guard let runtime, let source, let id = currentID else { return nil }
        let pipeline = cameraRawPipeline
        let key = "\(id)-\(film.id)-\(pipeline)"
        if let cached = thumbs[key] { return cached }
        let r = await queue.run(priority: .thumbnail, runtime: runtime, film: film, look: Look(),
                                input: { try source.makeBuffer(maxEdge: 180, runtime: runtime, originalRaw: pipeline == "original") }, finish: { $0.uiImage() })
        guard case .success(let image?) = r else { return nil }
        guard photos.contains(where: { $0.id == id }), cameraRawPipeline == pipeline else { return nil }
        thumbs[key] = image
        return image
    }

    // MARK: Preview

    func scheduleRender() {
        guard let runtime, let film = selectedFilm, let buffer = previewBuffer, let photoID = currentID else { return }
        let look = self.look
        renderTask?.cancel()                     // supersedes a queued or running preview (latest wins)
        isRendering = true
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)   // coalesce slider drags
            if Task.isCancelled { return }
            guard let self else { return }
            let r = await self.queue.run(priority: .preview, key: "preview", runtime: runtime, film: film, look: look,
                                         input: { buffer },
                                         finish: { (full: PixelBuffer) -> (UIImage?, UIImage?) in
                                             (full.uiImage(), full.downscaled(maxEdge: 360)?.uiImage())
                                         })
            guard !Task.isCancelled, self.currentID == photoID else { return }
            switch r {
            case .success(let pair?):
                self.result = pair.0
                self.message = nil
                if let i = self.currentIndex { self.photos[i].stripImage = pair.1 }
                self.isRendering = false
            case .success(nil):
                self.isRendering = false
            case .failure(let error):
                self.message = error.localizedDescription
                self.isRendering = false
            }
        }
    }

    // MARK: Export

    func export(scope: ExportScope) async {
        guard let runtime, !isExporting else { return }
        let targets: [Photo]
        switch scope {
        case .current: targets = currentIndex.map { [photos[$0]] } ?? []
        case .selected: targets = photos.filter { selection.contains($0.id) }
        case .all: targets = photos
        }
        guard !targets.isEmpty else { return }
        isExporting = true
        defer { isExporting = false }
        message = nil
        exportStatus = nil
        exportedURLs = []
        exportProgress = ""
        var failures = 0
        var lastError = ""
        let options = exportOptions
        let originalRaw = cameraRawPipeline == "original"
        var urls: [URL] = []
        for (n, photo) in targets.enumerated() {
            guard !Task.isCancelled else { return }
            guard let film = runtime.films.first(where: { $0.id == photo.filmID }) else { continue }
            if targets.count > 1 { exportProgress = "\(n + 1) / \(targets.count)" }
            let source = photo.source
            let longest = max(source.pixelSize.width, source.pixelSize.height)
            let edge = options.maxEdge > 0 ? min(options.maxEdge, longest) : Int.max
            let base = (photo.name + "-" + film.name)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            let stamp = UUID().uuidString
            // Decode, render and encode all happen on the single render worker, one photo at a time.
            let r = await queue.run(priority: .export, runtime: runtime, film: film, look: photo.look,
                                    input: { try source.makeBuffer(maxEdge: edge, runtime: runtime, originalRaw: originalRaw) },
                                    finish: { (rendered: PixelBuffer) -> URL in
                let info = WatermarkInfo(properties: source.properties, film: film.name, category: film.category, strength: photo.look.strength, number: n + 1)
                let framed = Encoder.watermarked(rendered, style: options.style, info: info, orientation: options.orientation)
                let data = try Encoder.encode(framed, format: options.format, quality: options.quality, properties: source.properties)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base)-\(stamp)-\(n).\(options.format.fileExtension)")
                try data.write(to: url, options: .atomic)
                return url
            })
            switch r {
            case .success(let url?): urls.append(url)
            case .success(nil): break
            case .failure(let error):
                failures += 1
                lastError = error.localizedDescription
                message = lastError
            }
        }
        exportedURLs = urls
        if urls.isEmpty {
            exportStatus = ExportStatus(text: "导出失败：\(lastError.isEmpty ? "没有可导出的照片" : lastError)", ok: false)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            let tail = failures > 0 ? "，\(failures) 张失败" : ""
            exportStatus = ExportStatus(text: "导出成功：已渲染 \(urls.count) 张\(tail)，可分享、存到文件或存入相册", ok: failures == 0)
            UINotificationFeedbackGenerator().notificationOccurred(failures == 0 ? .success : .warning)
        }
    }

    /// Small live preview of what an export would look like; composed off the main actor, never on the render queue.
    /// Photos that go on the contact sheet: the picked ones, or everything when nothing is picked.
    var sheetPhotos: [Photo] { selection.isEmpty ? photos : photos.filter { selection.contains($0.id) } }

    func exportPreview(mode: ExportMode, options: ExportOptions) async -> UIImage? {
        guard let runtime else { return nil }
        switch mode {
        case .single:
            guard let i = currentIndex, let cg = result?.cgImage,
                  let film = runtime.films.first(where: { $0.id == photos[i].filmID }) else { return nil }
            let info = WatermarkInfo(properties: photos[i].source.properties, film: film.name, category: film.category,
                                     strength: photos[i].look.strength, number: i + 1)
            let style = options.style, orientation = options.orientation
            return await Task.detached(priority: .utility) { () -> UIImage? in
                guard var buffer = PixelBuffer.from(cgImage: cg) else { return nil }
                if let small = buffer.downscaled(maxEdge: 1400) { buffer = small }
                return Encoder.watermarked(buffer, style: style, info: info, orientation: orientation).uiImage()
            }.value
        case .sheet:
            var frames: [(buffer: PixelBuffer, name: String, category: String, params: String, vertical: Bool, crop: SheetCrop)] = []
            for photo in sheetPhotos {
                guard let film = runtime.films.first(where: { $0.id == photo.filmID }) else { continue }
                let buffer = photo.stripImage?.cgImage.flatMap { PixelBuffer.from(cgImage: $0) } ?? photo.thumb
                let params = WatermarkInfo(properties: photo.source.properties, film: film.name, category: film.category,
                                           strength: photo.look.strength, number: 1).edgeParams
                frames.append((buffer, film.name, film.category, params, photo.sheetVertical, photo.sheetCrop))
            }
            let is135 = options.sheetFormat == .f135, cols = options.sheetColumns, vertical = options.sheetVertical
            let done = frames
            return await Task.detached(priority: .utility) { () -> UIImage? in
                Encoder.contactSheet(done, is135: is135, columns: cols, cellEdge: 260, vertical: vertical)?.uiImage()
            }.value
        }
    }

    /// Renders every open photo with its own film and look, then lays them out as one contact sheet.
    func exportSheet() async {
        guard let runtime, !photos.isEmpty, !isExporting else { return }
        let targets = sheetPhotos
        isExporting = true
        defer { isExporting = false }
        message = nil
        exportStatus = nil
        exportedURLs = []
        exportProgress = ""
        let options = exportOptions
        let originalRaw = cameraRawPipeline == "original"
        let cols = max(1, min(options.sheetColumns, targets.count))
        let edge = Int(min(1000.0, 6000.0 / Double(cols)))
        var frames: [(buffer: PixelBuffer, name: String, category: String, params: String, vertical: Bool, crop: SheetCrop)] = []
        for (n, photo) in targets.enumerated() {
            guard !Task.isCancelled else { return }
            guard let film = runtime.films.first(where: { $0.id == photo.filmID }) else { continue }
            exportProgress = "\(n + 1) / \(targets.count)"
            let source = photo.source
            let longest = max(source.pixelSize.width, source.pixelSize.height)
            let r = await queue.run(priority: .export, runtime: runtime, film: film, look: photo.look,
                                    input: { try source.makeBuffer(maxEdge: min(edge, longest), runtime: runtime, originalRaw: originalRaw) },
                                    finish: { (b: PixelBuffer) -> PixelBuffer in b })
            switch r {
            case .success(let buffer?):
                let params = WatermarkInfo(properties: source.properties, film: film.name, category: film.category,
                                           strength: photo.look.strength, number: n + 1).edgeParams
                frames.append((buffer, film.name, film.category, params, photo.sheetVertical, photo.sheetCrop))
            case .success(nil): break
            case .failure(let error): message = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }
        // Compositing and encoding a large contact sheet must not block the main actor.
        let completedFrames = frames
        do {
            let url = try await Task.detached(priority: .userInitiated) { () -> URL in
                guard let sheet = Encoder.contactSheet(completedFrames, is135: options.sheetFormat == .f135,
                                                       columns: cols, cellEdge: Double(edge), vertical: options.sheetVertical) else {
                    throw AppError.message("无法生成索引图")
                }
                let data = try Encoder.encode(sheet, format: options.format, quality: options.quality, properties: [:])
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("索引图-\(UUID().uuidString).\(options.format.fileExtension)")
                try data.write(to: url, options: .atomic)
                return url
            }.value
            guard !Task.isCancelled else { return }
            exportedURLs = [url]
            exportStatus = ExportStatus(text: "导出成功：索引图已生成（\(completedFrames.count) 张），可分享、存到文件或存入相册", ok: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            message = error.localizedDescription
            exportStatus = ExportStatus(text: "导出失败：\(error.localizedDescription)", ok: false)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func saveToPhotos() async {
        guard !exportedURLs.isEmpty else { return }
        do {
            try await Encoder.saveToPhotos(exportedURLs)
            exportStatus = ExportStatus(text: "已存入相册（\(exportedURLs.count) 张）", ok: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            exportStatus = ExportStatus(text: "存入相册失败：\(error.localizedDescription)", ok: false)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: Bindings

    func intBinding(_ path: WritableKeyPath<Look, Int>) -> Binding<Double> {
        Binding(get: { Double(self.look[keyPath: path]) }, set: { self.look[keyPath: path] = Int($0.rounded()) })
    }
    func floatBinding(_ path: WritableKeyPath<Look, Float>) -> Binding<Double> {
        Binding(get: { Double(self.look[keyPath: path]) }, set: { self.look[keyPath: path] = Float($0) })
    }
}
