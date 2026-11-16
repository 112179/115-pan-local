import SwiftUI
import UIKit

struct TasksView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var tasks: [DirectTask] = []
    @State private var loading = false
    @State private var error: String?
    @State private var pendingDelete: DirectTask?
    @State private var showAdd = false
    @State private var seed = ""
    @State private var stat = 12

    var body: some View {
        List {
            Section {
                Picker("状态", selection: $stat) {
                    Text("进行中").tag(12)
                    Text("已完成").tag(11)
                    Text("失败").tag(9)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if tasks.isEmpty && loading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            } else if tasks.isEmpty && error == nil {
                Section {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(tasks) { task in
                    TaskRow(task: task)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if stat == 11 {
                                Button {
                                    act(task, "restart")
                                } label: {
                                    Label("重下", systemImage: "arrow.clockwise")
                                }
                                .tint(.green)
                            } else {
                                Button {
                                    act(task, "pause")
                                } label: {
                                    Label("暂停", systemImage: "pause.fill")
                                }
                                .tint(.orange)
                                Button {
                                    act(task, "resume")
                                } label: {
                                    Label("继续", systemImage: "play.fill")
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = task
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    seed = ""
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTaskSheet(seed: seed)
                .environmentObject(auth)
        }
        .confirmationDialog("删除这个任务？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let task = pendingDelete { act(task, "del") }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
        .task(id: stat) {
            await load()
            await poll()
        }
    }

    private var emptyText: String {
        switch stat {
        case 11: return "暂无已完成记录"
        case 9: return "暂无失败记录"
        default: return "暂无进行中的任务"
        }
    }

    private func load() async {
        if tasks.isEmpty { loading = true }
        do {
            tasks = try await auth.api.tasks(stat: stat)
            error = nil
        } catch {
            self.error = error.localizedDescription
            tasks = []
        }
        loading = false
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { break }
            guard UIApplication.shared.applicationState == .active else { continue }
            await load()
        }
    }

    private func act(_ task: DirectTask, _ action: String) {
        Task {
            do {
                try await auth.api.taskAction(hash: task.hash.isEmpty ? task.id : task.hash, action: action)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "剪贴板里没有链接"
            return
        }
        seed = text
        showAdd = true
    }
}

struct TaskRow: View {
    let task: DirectTask

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(task.name)
                .font(.subheadline)
                .lineLimit(2)

            ProgressView(value: min(max(task.percent, 0), 100), total: 100)
                .tint(task.percent >= 100 ? .green : .blue)

            HStack {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(task.percent >= 100 ? Color.green : Color.secondary)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: task.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.1f%%", task.percent))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        if task.percent >= 100 { return "已完成" }
        switch task.status {
        case 3: return "下载失败"
        case 2: return "下载中"
        case 1: return "等待中"
        default: return task.percent > 0 ? "下载中" : "等待中"
        }
    }
}
