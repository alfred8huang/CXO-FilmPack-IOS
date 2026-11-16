import SwiftUI

struct FilmCard: View {
    @Environment(EditorModel.self) private var model
    let film: FilmEntry
    @State private var thumb: UIImage?
    var showDetail: (FilmEntry) -> Void = { _ in }

    private var selected: Bool { model.selectedFilm?.id == film.id }

    var body: some View {
        Button { model.select(film) } label: {
            VStack(spacing: 6) {
                Color.white.opacity(0.06)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let thumb {
                            Image(uiImage: thumb).resizable().scaledToFill()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        if model.favorites.contains(film.id) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).padding(6)
                        }
                    }
                Text(film.name).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(model.favorites.contains(film.id) ? "取消收藏" : "收藏",
                   systemImage: model.favorites.contains(film.id) ? "star.slash" : "star") { model.toggleFavorite(film) }
            Button("胶片详情", systemImage: "info.circle") { showDetail(film) }
        }
        .task(id: model.photoToken) {
            thumb = nil
            let image = await model.thumbnail(for: film)
            if !Task.isCancelled { thumb = image }
        }
    }
}

struct FilmDetailView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let film: FilmEntry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(film.name).font(.title2.weight(.bold))
                    if let d = model.description(for: film) {
                        let rows: [(String, String?)] = [("厂商", d.manufacturer), ("类型", d.type), ("发布", d.introduced), ("停产", d.discontinued)]
                        ForEach(rows.filter { ($0.1 ?? "").isEmpty == false }, id: \.0) { row in
                            HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(row.1 ?? "") }.font(.subheadline)
                        }
                        if let text = d.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            Text(text).font(.body).padding(.top, 6)
                        }
                    } else {
                        Text("暂无介绍").foregroundStyle(.secondary)
                    }
                    if film.experimental { Text("实验性胶片").font(.footnote).foregroundStyle(.orange) }
                }
                .padding()
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Searchable, categorised film grid (the "Presets" panel).
struct FilmLibraryView: View {
    @Environment(EditorModel.self) private var model
    @State private var query = ""
    @State private var category = "全部"
    @State private var detail: FilmEntry?
    var columns: Int = 2

    private var categories: [String] { ["全部", "收藏"] + (model.runtime?.categories ?? []) }

    private var filtered: [FilmEntry] {
        guard let runtime = model.runtime else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return runtime.films.filter { film in
            switch category {
            case "全部": break
            case "收藏": if !model.favorites.contains(film.id) { return false }
            default: if film.category != category { return false }
            }
            return q.isEmpty || film.name.lowercased().contains(q) || film.token.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索胶片", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glass()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { c in
                        Button { category = c } label: {
                            Text(c).font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(category == c ? Color.accentColor : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                if filtered.isEmpty {
                    Text(category == "收藏" ? "长按胶片可以收藏" : "没有匹配的胶片")
                        .foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
                        ForEach(filtered) { film in
                            FilmCard(film: film, showDetail: { detail = $0 })
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .sheet(item: $detail) { [model] film in
            FilmDetailView(film: film).environment(model)
        }
    }
}

/// Horizontal quick-switch strip.
struct FilmStrip: View {
    @Environment(EditorModel.self) private var model
    var cardWidth: CGFloat = 92

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(model.runtime?.films ?? []) { film in
                        FilmCard(film: film).frame(width: cardWidth).id(film.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            // A horizontal ScrollView is greedy vertically; pin it to one row of cards.
            .frame(height: cardWidth * 0.75 + 30)
            .onChange(of: model.selectedFilm) { _, film in
                if let film { withAnimation { proxy.scrollTo(film.id, anchor: .center) } }
            }
        }
    }
}

/// Lightroom-style strip of every open photograph (shows each photo with its own look).
struct PhotoStrip: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    var height: CGFloat = 72

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    if model.photos.count > 1 {
                        Button { model.openPhotoGrid(inPanel: sizeClass == .regular) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "checkmark.circle").font(.title3.weight(.semibold))
                                Text("多选").font(.caption2)
                            }
                            .frame(width: height, height: height)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.photos) { photo in
                        PhotoThumb(photo: photo, height: height).id(photo.id)
                    }
                    Button { model.showPhotoPicker = true } label: {
                        Image(systemName: "plus").font(.title3.weight(.semibold))
                            .frame(width: height, height: height)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
            .frame(height: height)
            .onChange(of: model.currentID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

struct PhotoThumb: View {
    @Environment(EditorModel.self) private var model
    let photo: Photo
    let height: CGFloat
    @State private var confirmRemove = false

    var body: some View {
        let selected = model.currentID == photo.id
        Button { model.selectPhoto(photo.id) } label: {
            Color.white.opacity(0.06)
                .frame(width: height * 4 / 3, height: height)
                .overlay {
                    if let image = photo.stripImage ?? photo.originalThumb {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("复制设置", systemImage: "doc.on.doc") { model.copySettings(from: photo.id) }
            Button("粘贴设置", systemImage: "doc.on.clipboard") { model.pasteSettings(to: photo.id) }
                .disabled(model.clipboard == nil)
            if model.photos.count > 1 {
                Button("同步到所有照片", systemImage: "arrow.triangle.2.circlepath") { model.syncAll(from: photo.id) }
            }
            Button("移除", systemImage: "trash", role: .destructive) { confirmRemove = true }
        }
        .confirmationDialog("移除这张照片？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除", role: .destructive) { model.removePhoto(photo.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这张照片的胶片和调整会丢失，原文件不会被删除。")
        }
    }
}


/// Sheet wrapper (iPhone): the grid panel under a drag indicator.
struct PhotoGridView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PhotoGridPanel { dismiss() }
            .padding(.horizontal, 12).padding(.top, 16)
    }
}

/// Every open photo as a grid of tiles, for multi-select: sync the current photo's look to many photos, or export them.
/// Used as a sheet on iPhone and as a side-panel tab on iPad (where the big preview stays visible).
struct PhotoGridPanel: View {
    @Environment(EditorModel.self) private var model
    var minTile: CGFloat = 104
    let onClose: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case all = "全部", raw = "RAW", adjusted = "已调整"
        var id: String { rawValue }
    }
    private enum DragMode { case idle, ignored, select, deselect }

    @State private var kind: Kind = .all
    @State private var filmFilter: String?
    @State private var tileFrames: [UUID: CGRect] = [:]
    @State private var dragMode: DragMode = .idle

    private var visible: [Photo] {
        model.photos.filter { photo in
            switch kind {
            case .all: break
            case .raw: if !photo.source.isRaw { return false }
            case .adjusted: if photo.look == Look() { return false }
            }
            if let filmFilter, photo.filmID != filmFilter { return false }
            return true
        }
    }

    private var filmOptions: [(id: String, name: String)] {
        var seen = Set<String>(), out: [(id: String, name: String)] = []
        for photo in model.photos where seen.insert(photo.filmID).inserted {
            if let film = model.runtime?.films.first(where: { $0.id == photo.filmID }) { out.append((film.id, film.name)) }
        }
        return out
    }

    /// Swipe sideways across tiles to select (or, starting on a picked tile, deselect) a run of photos at once;
    /// a mostly vertical drag is left to scrolling.
    private var swipeSelect: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("photoGrid"))
            .onChanged { value in
                if dragMode == .idle {
                    guard abs(value.translation.width) >= abs(value.translation.height),
                          let start = tile(at: value.startLocation) else { dragMode = .ignored; return }
                    dragMode = model.selection.contains(start) ? .deselect : .select
                    apply(start)
                }
                if let id = tile(at: value.location) { apply(id) }
            }
            .onEnded { _ in dragMode = .idle }
    }

    private func tile(at point: CGPoint) -> UUID? {
        tileFrames.first { $0.value.contains(point) }?.key
    }

    private func apply(_ id: UUID) {
        switch dragMode {
        case .select:
            if model.selection.insert(id).inserted { UISelectionFeedbackGenerator().selectionChanged() }
        case .deselect:
            if model.selection.remove(id) != nil { UISelectionFeedbackGenerator().selectionChanged() }
        default: break
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            filters
            ScrollView {
                if visible.isEmpty {
                    Text("没有符合的照片").font(.footnote).foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile, maximum: 180), spacing: 8)], spacing: 8) {
                        ForEach(visible) { PhotoGridTile(photo: $0) }
                    }
                    .padding(.vertical, 2)
                    .coordinateSpace(name: "photoGrid")
                    .onPreferenceChange(TileFrameKey.self) { tileFrames = $0 }
                    .simultaneousGesture(swipeSelect)
                }
            }
            .overlay(alignment: .top) { feedback.padding(.top, 4) }
            actionBar
        }
    }

    private var header: some View {
        let ids = Set(visible.map(\.id))
        let allVisible = !ids.isEmpty && ids.isSubset(of: model.selection)
        return HStack(spacing: 14) {
            Text("已选 \(model.selection.count) / \(model.photos.count)")
                .font(.headline).monospacedDigit()
            Spacer(minLength: 0)
            Button(allVisible ? "全不选" : "全选") {
                if allVisible { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
            }
            .disabled(ids.isEmpty)
            Button("完成") { onClose() }.fontWeight(.semibold)
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if filmOptions.count > 1 {
                Menu {
                    Button("全部胶片") { filmFilter = nil }
                    ForEach(filmOptions, id: \.id) { option in
                        Button(option.name) { filmFilter = option.id }
                    }
                } label: {
                    Label(filmOptions.first { $0.id == filmFilter }?.name ?? "胶片", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.footnote.weight(.medium)).lineLimit(1)
                }
            }
        }
    }

    /// Result of a batch action (with undo) or a short message; shown here because the grid covers the main toast.
    @ViewBuilder private var feedback: some View {
        if let batch = model.lastBatch {
            HStack(spacing: 12) {
                Text(batch.text).font(.footnote.weight(.medium))
                Button("撤销") { model.undoLastBatch() }.font(.footnote.weight(.bold))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass()
        } else {
            MessageToast()
        }
    }

    private var actionBar: some View {
        let targets = model.selection.filter { $0 != model.currentID }.count
        let canSync = targets > 0
        let canPaste = model.clipboard != nil && !model.selection.isEmpty
        let canExport = !model.selection.isEmpty
        let film = model.selectedFilm?.name ?? "当前胶片"
        let syncTitle = canSync ? "把 \(film) · \(model.look.strength)% 应用到 \(targets) 张" : "先选中要应用的照片"
        return VStack(spacing: 8) {
            Text("点选或横向划过连选；标「当前」的这张是设置的来源。")
                .font(.caption).foregroundStyle(.secondary)
            GlassGroup {
                VStack(spacing: 10) {
                    GlassTextButton(title: syncTitle, systemName: "arrow.triangle.2.circlepath", prominent: canSync) {
                        model.applyCurrent(toSelected: model.selection)
                    }
                    .disabled(!canSync).opacity(canSync ? 1 : 0.4)
                    HStack(spacing: 10) {
                        GlassTextButton(title: "粘贴设置", systemName: "doc.on.clipboard") {
                            model.pasteToSelected(model.selection)
                        }
                        .disabled(!canPaste).opacity(canPaste ? 1 : 0.4)
                        GlassTextButton(title: "导出", systemName: "square.and.arrow.up") {
                            model.sheet = .export
                        }
                        .disabled(!canExport).opacity(canExport ? 1 : 0.4)
                    }
                    if model.photos.count > 1 {
                        GlassTextButton(title: model.selection.isEmpty ? "做索引图（全部 \(model.photos.count) 张）" : "用所选 \(model.selection.count) 张做索引图",
                                        systemName: "rectangle.split.3x1") {
                            model.sheet = .contactSheet
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct TileFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct PhotoGridTile: View {
    @Environment(EditorModel.self) private var model
    let photo: Photo

    var body: some View {
        let picked = model.selection.contains(photo.id)
        let isCurrent = model.currentID == photo.id
        let filmName = model.runtime?.films.first { $0.id == photo.filmID }?.name
        Button { model.toggleSelection(photo.id) } label: {
            Color.white.opacity(0.06)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = photo.stripImage ?? photo.originalThumb {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if photo.source.isRaw { badge("RAW", fill: Color.black.opacity(0.55)) }
                        if isCurrent { badge("当前", fill: Color.accentColor) }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.look != Look() {
                        Image(systemName: "slider.horizontal.3").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(5).background(Color.accentColor, in: Circle()).padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let filmName {
                        Text(filmName).font(.caption2).lineLimit(1).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(picked ? Color.accentColor : Color.white.opacity(0.9))
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(picked ? Color.accentColor : Color.clear, lineWidth: 3)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geo in
            Color.clear.preference(key: TileFrameKey.self, value: [photo.id: geo.frame(in: .named("photoGrid"))])
        })
        .contextMenu {
            Button("设为当前照片", systemImage: "star.circle") { model.selectPhoto(photo.id) }
            Button("复制设置", systemImage: "doc.on.doc") { model.copySettings(from: photo.id) }
        }
    }

    private func badge(_ text: String, fill: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}
