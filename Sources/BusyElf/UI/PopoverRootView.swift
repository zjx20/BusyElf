import SwiftUI

/// popover 根视图:状态头 → 可滚动任务列表 / 空态 → 底部开关。固定宽 320pt。
struct PopoverRootView: View {
    @ObservedObject var viewModel: PopoverViewModel
    @State private var confirmingStopAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.sessions.isEmpty {
                emptyState
            } else {
                taskList
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(viewModel.waitingCount > 0 ? .orange
                                 : (viewModel.isBlocking ? .primary : .secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text("BusyElf").font(.system(size: 13, weight: .bold))
                Text(viewModel.headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            overflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var overflowMenu: some View {
        Menu {
            Button("关于 BusyElf") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 26))
                .foregroundColor(.secondary.opacity(0.7))
            Text("工作台是空的。")
                .font(.system(size: 13, weight: .medium))
            Text("当前没有 agent 在工作。\n你的 Mac 会正常 idle 休眠。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("(注:合上盖子仍会休眠 — 长任务请开盖接电)")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
    }

    // MARK: - 任务列表

    private var taskList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().padding(.leading, 12) }
                    AgentRow(session: session, now: viewModel.now) {
                        viewModel.forceStop(session.id)
                    }
                }
            }
        }
        // 超过 ~5 行可滚动;限制最大高度避免 popover 过长
        .frame(maxHeight: 320)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            if !viewModel.sessions.isEmpty {
                stopAllRow
                Divider()
            }

            toggleRow(
                icon: "moon.fill",
                title: "也保持屏幕唤醒",
                isOn: Binding(
                    get: { viewModel.keepDisplayAwake },
                    set: { viewModel.toggleKeepDisplayAwake($0) }))

            toggleRow(
                icon: "power",
                title: "开机启动",
                isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.toggleLaunchAtLogin($0) }))

            Divider()

            Button(action: { NSApp.terminate(nil) }) {
                HStack {
                    Text("Quit BusyElf").font(.system(size: 12))
                    Spacer()
                    Text("⌘Q").font(.system(size: 11)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var stopAllRow: some View {
        Group {
            if confirmingStopAll {
                HStack(spacing: 8) {
                    Text("结束全部 \(viewModel.sessions.count) 个任务?")
                        .font(.system(size: 12))
                    Spacer()
                    Button("结束", role: .destructive) {
                        confirmingStopAll = false
                        viewModel.stopAll()
                    }
                    .controlSize(.small)
                    Button("取消") { confirmingStopAll = false }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Button(action: { confirmingStopAll = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle").font(.system(size: 12))
                        Text("全部结束 (\(viewModel.sessions.count))").font(.system(size: 12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 12))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
