import SwiftUI

struct DirRoute: Hashable {
    let id: String
    let name: String
}

struct PlayerTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let pickcode: String
}

enum FileFilter: String, CaseIterable {
    case all, video, folder

    var label: String {
        switch self {
        case .all: return "全部"
        case .video: return "只看视频"
        case .folder: return "只看文件夹"
        }
    }
}

struct BrowserList: View {
    @EnvironmentObject private var auth: AuthStore

    let cid: String
    let name: String

    @State private var items: [DirectFile] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var resolving = false
    @State private var resolvingName = ""
    @State private var target: PlayerTarget?

    @State private var filter: FileFilter = .all
    @State private var query = ""
    @State private var searchResults: [DirectFile]?

    @State private var renameTarget: DirectFile?
    @State private var renameText = ""
    @State private var moveTarget: DirectFile?
    @State private var deleteTarget: DirectFile?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private let pageSize = 100

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if loading && items.isEmpty && searchResults == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            }

            if let results = searchResults {
                Section("搜索结果（\(results.count)）") {
                    ForEach(results) { item in
                        row(for: item)
                    }
                }
            } else {
                ForEach(visibleItems) { item in
                    row(for: item)
                }

                if hasMore {
                    Section {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() } else { Text("加载更多") }
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前目录")
        .onSubmit(of: .search) {
            Task { await doSearch() }
        }
        .onChange(of: query) { _, value in
            if value.isEmpty {
                searchResults = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        Task { await load(reset: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("筛选", selection: $filter) {
                        ForEach(FileFilter.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable {
            if searchResults != nil {
                await doSearch()
            } else {
                await load(reset: true)
            }
        }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
        .overlay {
            if resolving {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(resolvingName)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .fullScreenCover(item: $target) { item in
            LocalPlayerView(title: item.title, url: item.url, pickcode: item.pickcode)
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil },
                                             set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $renameText)
            Button("确定") { commitRename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") { createFolder() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这个项目？",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.name ?? "")
        }
        .sheet(isPresented: Binding(get: { moveTarget != nil },
                                    set: { if !$0 { moveTarget = nil } })) {
            FolderPicker { cid, _ in
                commitMove(to: cid)
            }
            .environmentObject(auth)
        }
    }

    private var visibleItems: [DirectFile] {
        switch filter {
        case .all: return items
        case .video: return items.filter { $0.isVideo }
        case .folder: return items.filter { $0.isDir }
        }
    }

    private var hasMore: Bool {
        items.count < total
    }

    @ViewBuilder
    private func row(for item: DirectFile) -> some View {
        if item.isDir {
            NavigationLink(value: DirRoute(id: item.id, name: item.name)) {
                FolderRow(name: item.name)
            }
            .contextMenu { menu(for: item) }
        } else {
            Button {
                resolve(item)
            } label: {
                FileRow(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: item) }
        }
    }

    @ViewBuilder
    private func menu(for item: DirectFile) -> some View {
        Button {
            renameTarget = item
            renameText = item.name
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            moveTarget = item
        } label: {
            Label("移动到…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = item
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func load(reset: Bool) async {
        if reset {
            loading = true
        } else {
            loading = true
        }
        do {
            let result = try await auth.api.files(cid: cid,
                                                  offset: reset ? 0 : items.count,
                                                  limit: pageSize)
            if reset {
                items = result.items
            } else {
                items += result.items
            }
            total = max(result.total, items.count)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func doSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = nil
            return
        }
        loading = true
        do {
            searchResults = try await auth.api.search(keyword: keyword, cid: cid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty, name != target.name else { return }
        Task {
            do {
                try await auth.api.rename(id: target.id, name: name)
                await load(reset: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await auth.api.mkdir(name: name, pid: cid)
                await load(reset: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            do {
                try await auth.api.delete(id: target.id)
                await load(reset: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commitMove(to cid: String) {
        guard let target = moveTarget else { return }
        moveTarget = nil
        Task {
            do {
                try await auth.api.move(id: target.id, to: cid)
                await load(reset: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func resolve(_ item: DirectFile) {
        guard !resolving else { return }
        resolving = true
        resolvingName = item.name
        Task {
            do {
                let url = try await auth.api.downloadURL(pickcode: item.pickcode)
                target = PlayerTarget(title: item.name, url: url, pickcode: item.pickcode)
            } catch {
                self.error = error.localizedDescription
            }
            resolving = false
        }
    }
}

struct FolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(name).lineLimit(1)
        }
    }
}

struct FileRow: View {
    let item: DirectFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isVideo ? "play.rectangle.fill" : "doc.fill")
                .foregroundStyle(item.isVideo ? Color.blue : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if item.isVideo && !item.pickcode.isEmpty {
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
