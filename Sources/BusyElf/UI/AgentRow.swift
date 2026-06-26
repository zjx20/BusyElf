import SwiftUI

/// 单任务行。点 `×` 就地翻成单段行内确认(不弹模态——模态会与 popover 失焦消失打架)。
struct AgentRow: View {
    let session: TaskSession
    let now: Date
    let onForceStop: () -> Void

    @State private var confirming = false
    @State private var xmarkHovered = false

    private var isWaiting: Bool { session.status == .waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if confirming {
                confirmBlock
            } else {
                normalBlock
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.12), value: confirming)
    }

    // MARK: - 常规展示

    private var normalBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 第 1 行:状态点 + 项目名 + ×
            HStack(spacing: 6) {
                statusDot
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if session.isStuck(asOf: now) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                        .help("长时间无进展,可能已卡死")
                }
                Spacer(minLength: 4)
                forceStopButton
            }

            // 第 2 行:working → 当前活动;waiting → message
            secondLine

            // 第 3 行:时长 · 来源
            Text(thirdLineText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        if isWaiting {
            Text(session.waitingMessage?.isEmpty == false ? session.waitingMessage! : "需要你处理")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(session.waitingMessage ?? "")
        } else if !session.activity.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundColor(.secondary)
                Text(session.activity)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(session.activity)
        } else {
            Text("在干活…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(isWaiting ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
            .help(isWaiting ? "等你处理" : "在干活")
    }

    private var forceStopButton: some View {
        Button(action: { confirming = true }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(xmarkHovered ? .red : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .onHover { xmarkHovered = $0 }
        .help("移除此任务(解除休眠阻止,不杀进程)")
    }

    private var thirdLineText: String {
        let elapsed = Format.duration(session.elapsed(asOf: now))
        if let agent = session.agent, !agent.isEmpty {
            return "\(elapsed) · \(agent)"
        }
        return elapsed
    }

    // MARK: - 行内确认

    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusDot
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            Text("移除此任务,让 Mac 可以休眠?")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            if session.looksActive(asOf: now) {
                Text("⚠ 该任务似乎仍在活动(\(Format.ago(session.sinceLastSeen(asOf: now)))还有进展)")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            HStack {
                Button("移除", role: .destructive) {
                    confirming = false
                    onForceStop()
                }
                .controlSize(.small)
                Spacer()
                Button("取消") { confirming = false }
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
        }
    }
}
