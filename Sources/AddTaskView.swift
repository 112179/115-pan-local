import SwiftUI

struct AddTaskSheet: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var folderID = "0"
    @State private var folderName = "根目录"
    @State private var showPicker = false
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    init(seed: String = "") {
        _text = State(initialValue: seed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 130)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Text("下载链接")
                } footer: {
                    Text("支持 magnet / ed2k / http / 115 分享链接，每行一个。")
                }

                Section("保存到") {
                    Button {
                        showPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(folderName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let message {
                    Section {
                        Label(message, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "提交中…" : "开始下载").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("新建云下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                FolderPicker { cid, name in
                    folderID = cid
                    folderName = name
                }
                .environmentObject(auth)
            }
        }
    }

    private func submit() {
        let urls = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !urls.isEmpty else {
            error = "先粘贴至少一个链接"
            return
        }

        busy = true
        message = nil
        error = nil
        Task {
            do {
                var last = ""
                for url in urls {
                    last = try await auth.api.addTask(url: url, cid: folderID)
                }
                message = last
                text = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct FolderPicker: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    let onPick: (String, String) -> Void

    var body: some View {
        NavigationStack {
            FolderLevel(cid: "0", name: "根目录", onPick: pick)
                .navigationTitle("选择文件夹")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: DirRoute.self) { route in
                    FolderLevel(cid: route.id, name: route.name, onPick: pick)
                        .navigationTitle(route.name)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
    }

    private func pick(_ cid: String, _ name: String) {
        onPick(cid, name)
        dismiss()
    }
}

struct FolderLevel: View {
    @EnvironmentObject private var auth: AuthStore

    let cid: String
    let name: String
    let onPick: (String, String) -> Void

    @State private var folders: [DirectFile] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button {
                    onPick(cid, name)
                } label: {
                    Label("保存到「\(name)」", systemImage: "checkmark.circle")
                }
            }

            Section {
                if loading && folders.isEmpty {
                    HStack {
                        ProgressView()
                        Text("读取中…").foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(folders) { folder in
                    NavigationLink(value: DirRoute(id: folder.id, name: folder.name)) {
                        FolderRow(name: folder.name)
                    }
                }
                if !loading && folders.isEmpty && error == nil {
                    Text("没有子文件夹").foregroundStyle(.secondary)
                }
            } header: {
                Text("子文件夹")
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let result = try await auth.api.files(cid: cid, limit: 1000)
            folders = result.items.filter { $0.isDir }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
