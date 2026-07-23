import SwiftUI

struct PendingCard: View {
    @ObservedObject var store: SessionStore
    let req: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch req.kind {
            case .approval: approvalBody
            case .question: QuestionBody(store: store, req: req)
            case .plan: PlanBody(store: store, req: req)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.45), lineWidth: 1))
    }

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("⚠ 权限请求")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(req.toolName)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.accent, in: Capsule())
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(req.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+ ") ? .green
                                         : line.hasPrefix("- ") ? .red : Theme.textPrimary)
                        .lineLimit(4)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                DecisionButton(label: "拒绝", style: .dark) {
                    store.decide(req.id, .deny(reason: ""))
                }
                DecisionButton(label: "允许一次", style: .light) {
                    store.decide(req.id, .allow)
                }
                DecisionButton(label: "始终允许", style: .blue) {
                    store.decide(req.id, .alwaysAllow)
                }
                Spacer()
                Button {
                    store.setBypass(req.sessionKey, true)
                } label: {
                    Label("本会话自动批准", systemImage: "bolt.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("此会话后续的权限请求全部自动放行，直到你在会话卡上关闭")
            }
            if let rule = req.alwaysAllowRuleContent {
                Text("「始终允许」将放行 \(rule) 类命令")
                    .font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Decision buttons: dark = deny, light = allow-once, blue = primary.
struct DecisionButton: View {
    enum Style { case dark, light, blue }
    let label: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .light ? .black : .white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(minWidth: 64)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .dark: return Color(white: 0.22)
        case .light: return .white
        case .blue: return Color(red: 0.25, green: 0.45, blue: 0.95)
        }
    }
}

private struct QuestionBody: View {
    @ObservedObject var store: SessionStore
    let req: PendingRequest
    @State private var selected: [Int: Set<String>] = [:]

    private var allAnswered: Bool {
        req.questions.allSatisfy { !(selected[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("❓ Agent 的提问")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            ForEach(req.questions) { q in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if !q.header.isEmpty {
                            Text(q.header).font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .overlay(Capsule().stroke(Theme.textTertiary, lineWidth: 0.5))
                        }
                        Text(q.question)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        if q.multiSelect {
                            Text("多选").font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    ForEach(q.options) { opt in
                        Button {
                            toggle(q, opt.label)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: isPicked(q, opt.label)
                                      ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                      : (q.multiSelect ? "square" : "circle"))
                                .foregroundStyle(isPicked(q, opt.label) ? Theme.accent : Theme.textTertiary)
                                VStack(alignment: .leading) {
                                    Text(opt.label).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                    if !opt.description.isEmpty {
                                        Text(opt.description).font(.system(size: 10))
                                            .foregroundStyle(Theme.textSecondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                DecisionButton(label: "提交回答", style: .blue) {
                    store.decide(req.id, .answers(selected.mapValues(Array.init)))
                }
                .disabled(!allAnswered)
                .opacity(allAnswered ? 1 : 0.4)
                Spacer()
            }
        }
    }

    private func isPicked(_ q: PendingQuestion, _ label: String) -> Bool {
        selected[q.id]?.contains(label) ?? false
    }

    private func toggle(_ q: PendingQuestion, _ label: String) {
        var set = selected[q.id] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selected[q.id] = set
    }
}

private struct PlanBody: View {
    @ObservedObject var store: SessionStore
    let req: PendingRequest
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("📋 计划审阅")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            ScrollView {
                Text(req.plan)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            .padding(6)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            TextField("告诉 Agent 需要修改什么…", text: $feedback)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            HStack(spacing: 8) {
                DecisionButton(label: "批准（终端确认）", style: .light) {
                    store.decide(req.id, .planAllow(mode: "default"))
                }
                DecisionButton(label: "退回并反馈", style: .dark) {
                    store.decide(req.id, .planFeedback(feedback))
                }
                .disabled(feedback.isEmpty)
                .opacity(feedback.isEmpty ? 0.4 : 1)
                Spacer()
            }
            Text("注：当前 Claude Code 版本计划批准需在终端最终确认")
                .font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
        }
    }
}
