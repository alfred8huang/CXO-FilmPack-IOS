import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var m = model
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = model.startupError {
                VStack(spacing: 8) {
                    Text("启动失败").font(.title3.weight(.semibold))
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else if model.photos.isEmpty {
                EmptyStateView()
            } else if sizeClass == .regular {
                PadLayout()
            } else {
                PhoneLayout()
            }
        }
        .photosPicker(isPresented: $m.showPhotoPicker, selection: $pickerItems, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            model.importProgress = "正在读取所选照片…"
            Task {
                var imports: [(url: URL, name: String)] = []
                var index = model.photos.count
                for item in items {
                    index += 1
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
                    if (try? data.write(to: url)) != nil { imports.append((url, "照片\(index)")) }
                }
                if imports.isEmpty { model.importProgress = nil; model.message = "无法读取所选照片" } else { model.importPhotos(imports) }
                pickerItems = []
            }
        }
        // Attached to its own background view: several presentation modifiers (photos picker, file importer, sheet)
        // on one view can silently stop one of them from presenting on newer iPadOS.
        .background {
            Color.clear
                .fileImporter(isPresented: $m.showFileImporter,
                              allowedContentTypes: [.image, .rawImage, .data],   // .data: RAW formats that don't declare an image type
                              allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): importFiles(urls)
                    case .failure(let error): model.message = "无法打开文件：\(error.localizedDescription)"
                    }
                }
        }
        .sheet(item: $m.sheet) { [model] kind in
            SheetContent(kind: kind, model: model)
                .environment(model)
                .presentationDetents((kind == .settings || kind == .export || kind == .contactSheet || kind == .photos) ? [.large] : [.fraction(0.42), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                .presentationDragIndicator(.visible)
                .glassSheetBackground()
        }
    }
}

extension RootView {
    /// Copies the picked files into the app sandbox (off the main thread, coordinated so iCloud files download first),
    /// then imports them. Failures are reported with the actual reason.
    fileprivate func importFiles(_ urls: [URL]) {
        let model = self.model
        model.importProgress = "正在读取文件…"
        Task {
            var imports: [(url: URL, name: String)] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let copy = try await Task.detached(priority: .userInitiated) { try copyIntoSandbox(url) }.value
                    imports.append((copy, url.deletingPathExtension().lastPathComponent))
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if imports.isEmpty {
                model.importProgress = nil
                model.message = failures.isEmpty ? "无法读取所选文件" : failures.joined(separator: "\n")
            } else {
                if !failures.isEmpty { model.message = failures.joined(separator: "\n") }
                model.importPhotos(imports)
            }
        }
    }
}

private func copyIntoSandbox(_ url: URL) throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let ext = url.pathExtension
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)")
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
        do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
    }
    if let copyError { throw copyError }
    if let coordinationError { throw coordinationError }
    return dest
}

struct SheetContent: View {
    let kind: SheetKind
    let model: EditorModel

    var body: some View {
        switch kind {
        case .settings:
            SettingsView()
        case .export:
            ExportView(model: model, mode: .single)
        case .contactSheet:
            ExportView(model: model, mode: .sheet)
        case .photos:
            PhotoGridView()
        case .library:
            FilmLibraryView(columns: 3).padding([.horizontal, .top]).padding(.top, 8)
        default:
            ScrollView {
                VStack(spacing: 12) {
                    switch kind {
                    case .adjust: AdjustView()
                    case .grain: GrainView()
                    case .edge: EdgeView()
                    default: EmptyView()
                    }
                }
                .padding([.horizontal, .top]).padding(.top, 14).padding(.bottom, 24)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "film.stack").font(.system(size: 56, weight: .light))
            VStack(spacing: 6) {
                Text("CXO FilmPack").font(.largeTitle.weight(.bold))
                Text("选一张照片，套上胶片的味道").foregroundStyle(.secondary)
            }
            GlassGroup {
                VStack(spacing: 12) {
                    GlassTextButton(title: "从相册选取", systemName: "photo.on.rectangle", prominent: true) { model.showPhotoPicker = true }
                    GlassTextButton(title: "从文件选取（含 RAW）", systemName: "folder") { model.showFileImporter = true }
                }
            }
            if let progress = model.importProgress {
                HStack(spacing: 8) { ProgressView(); Text(progress).font(.footnote).foregroundStyle(.secondary) }
            }
            if let message = model.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        }
    }
}

/// Shared floating message pill.
struct MessageToast: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        if let progress = model.importProgress {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress) }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glass()
                .transition(.opacity)
        } else if let message = model.message {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glass()
                .onTapGesture { model.message = nil }
                .transition(.opacity)
        }
    }
}

struct OpenMenu: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        Menu {
            Button("从相册选取", systemImage: "photo.on.rectangle") { model.showPhotoPicker = true }
            Button("从文件选取（含 RAW）", systemImage: "folder") { model.showFileImporter = true }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Circle())
        }
        .glass(in: Circle(), interactive: true)
    }
}

/// Labelled so it is obvious what it opens: the contact-sheet (索引图) maker.
struct ContactSheetButton: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        Button { model.sheet = .contactSheet } label: {
            Label("索引图", systemImage: "rectangle.split.3x1")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
    }
}

struct CompareButton: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        Image(systemName: model.showOriginal ? "eye.fill" : "eye")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glass(in: Circle(), interactive: true, tint: model.showOriginal ? Color.accentColor : nil)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}, onPressingChanged: { model.showOriginal = $0 })
    }
}

struct PhotoCanvas: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        ZoomableImageView(image: model.showOriginal ? model.original : (model.result ?? model.original),
                          token: model.photoToken, onHold: { model.showOriginal = $0 })
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if model.showOriginal {
                    Text("原图").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .glass().padding(.top, 70).padding(.leading, 16)
                }
            }
    }
}
