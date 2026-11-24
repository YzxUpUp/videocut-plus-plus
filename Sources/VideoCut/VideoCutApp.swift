import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct VideoCutApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("VideoCut++", id: "editor") {
            Editor(workspace: workspace)
                .frame(minWidth: 960, minHeight: 670)
        }
        .defaultSize(width: 1180, height: 760)
    }
}

private let canvas = Color(red: 0.072, green: 0.085, blue: 0.094)
private let panel = Color(red: 0.108, green: 0.128, blue: 0.137)
private let accent = Color(red: 0.53, green: 0.92, blue: 0.77)
private let rule = Color.white.opacity(0.09)

struct Editor: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var ui = EditorState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(rule)
            HStack(alignment: .top, spacing: 18) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                sidebar.frame(width: 315)
            }
            .padding(20)
            Divider().overlay(rule)
            footer
        }
        .background(canvas)
        .preferredColorScheme(.dark)
        .tint(accent)
        .sheet(isPresented: $workspace.settings) { SetupView(workspace: workspace) }
        .sheet(item: $ui.editing) { cut in
            VStack(alignment: .leading, spacing: 16) {
                Text("调整切点").font(.title2.weight(.semibold))
                TextField("原片秒数", text: $ui.seconds).textFieldStyle(.roundedBorder)
                Text("输入原片时间（秒），可使用小数。").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { ui.editing = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        if let value = Double(ui.seconds) { workspace.changeCut(cut.id, to: value) }
                        ui.editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Double(ui.seconds).map { !$0.isFinite || $0 <= 0.05 || $0 >= workspace.duration - 0.05 ||
                        workspace.cuts.contains(where: { $0.id != cut.id && abs($0.seconds - (Double(ui.seconds) ?? 0)) < 0.05 }) } ?? true)
                }
            }
            .padding(24).frame(width: 330)
        }
        .alert("处理遇到问题", isPresented: Binding(get: { workspace.error != nil }, set: { value in
            if !value { workspace.error = nil }
        })) {
            Button("好", role: .cancel) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onChange(of: workspace.busy) { _, busy in
            if busy { ui.marking = false; ui.drag = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("VideoCut++", systemImage: "film.stack")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(accent)
            TextField("粘贴 B 站、YouTube 或抖音视频链接", text: $workspace.link)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(panel, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { if !workspace.busy && !workspace.link.isEmpty { workspace.download() } }
                .accessibilityLabel("视频链接")
            Button("下载并准备剪辑") { workspace.download() }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.busy || workspace.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button { chooseFile() } label: { Label("打开文件", systemImage: "folder") }
                .disabled(workspace.busy)
            Button { workspace.settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).padding(4)
            }.help("设置").accessibilityLabel("设置")
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 13)
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(workspace.original?.lastPathComponent ?? "视频预览")
                    .font(.headline).lineLimit(1)
                Spacer()
                if workspace.repaired != nil {
                    Toggle("查看原片", isOn: $workspace.compareOriginal)
                        .toggleStyle(.switch).controlSize(.small).disabled(workspace.busy || ui.marking)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.38))
                if workspace.playable != nil {
                    PlayerSurface(player: workspace.player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if ui.marking {
                        GeometryReader { geo in
                            let bounds = videoBounds(in: geo.size)
                            let rect = ui.drag ?? .zero
                            Color.black.opacity(0.04)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                                    let start = clamp(v.startLocation, to: bounds)
                                    let end = clamp(v.location, to: bounds)
                                    ui.drag = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                  width: abs(start.x - end.x), height: abs(start.y - end.y))
                                }.onEnded { _ in
                                    if let r = ui.drag, bounds.width > 0, bounds.height > 0 {
                                        workspace.addSeed(CGRect(x: (r.minX - bounds.minX) / bounds.width,
                                                                 y: (r.minY - bounds.minY) / bounds.height,
                                                                 width: r.width / bounds.width, height: r.height / bounds.height))
                                    }
                                    ui.drag = nil
                                    ui.marking = false
                                })
                            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.13))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent, lineWidth: 2))
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "play.rectangle").font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(accent.opacity(0.75))
                        Text("粘贴链接或打开本地视频").font(.headline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(rule))
            if workspace.playable != nil {
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { min(workspace.currentTime, workspace.duration) },
                                          set: { workspace.seek(to: $0) }),
                           in: 0...max(0.01, workspace.duration))
                    .accessibilityLabel("视频进度")
                    HStack {
                        Text(timestamp(workspace.currentTime))
                        Spacer()
                        Text(timestamp(workspace.duration))
                    }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("分段").font(.headline)
                        Spacer()
                        if workspace.playable != nil {
                            Text("\(workspace.cuts.count + 1) 段").font(.caption.monospacedDigit()).foregroundStyle(accent)
                        }
                    }
                    HStack {
                        Button {
                            workspace.analyze()
                        } label: { Label(workspace.analyzed ? "重新分析" : "AI 分析", systemImage: "sparkles") }
                        Button {
                            workspace.addCut()
                        } label: { Label("添加切点", systemImage: "plus") }
                    }
                    .disabled(workspace.playable == nil || workspace.busy || ui.marking)
                    if workspace.cuts.isEmpty {
                        Text(workspace.analyzed ? "当前保留为一段" : "AI 根据内容建议切点，目标约 60 秒。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(workspace.cuts.enumerated()), id: \.element.id) { index, cut in
                        HStack(alignment: .top, spacing: 8) {
                            Button { workspace.preview(cut) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(timestamp(cut.seconds)).font(.system(.subheadline, design: .monospaced))
                                        .foregroundStyle(accent)
                                    Text(cut.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .help("跳转到 \(timestamp(cut.seconds)) 并暂停预览")
                            Button {
                                ui.seconds = String(format: "%.3f", cut.seconds)
                                ui.editing = cut
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("调整切点").accessibilityLabel("调整切点 \(index + 1)")
                            .padding(.top, 9)
                            Button {
                                workspace.cuts.removeAll { $0.id == cut.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("移除切点").accessibilityLabel("移除切点 \(index + 1)")
                            .padding([.top, .trailing], 9)
                        }
                        .background(canvas, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(workspace.busy || ui.marking)
                    }
                }.modifier(Card())

                VStack(alignment: .leading, spacing: 11) {
                    Text("去水印").font(.headline)
                    HStack {
                        Button {
                            workspace.repair()
                        } label: { Label(workspace.report == nil ? "检测并修补" : "重新处理", systemImage: "wand.and.stars") }
                        Button(ui.marking ? "取消框选" : "框选水印") {
                            workspace.player.pause()
                            if !ui.marking && workspace.repaired != nil { workspace.compareOriginal = true }
                            ui.marking.toggle()
                            ui.drag = nil
                        }
                    }.disabled(workspace.playable == nil || workspace.busy)
                    if ui.marking {
                        Text("在画面中拖动，框住完整水印。").font(.caption).foregroundStyle(accent)
                    }
                    if !workspace.seeds.isEmpty {
                        HStack {
                            Text("已框选 \(workspace.seeds.count) 处").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除框选") { workspace.clearSeeds() }.buttonStyle(.link)
                                .disabled(workspace.busy)
                        }
                    }
                    if let report = workspace.report {
                        Text(report.repairedFrames > 0
                             ? "已修补 \(report.repairedFrames) 帧"
                             : "未检测到可靠的水印")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(report.uncertain) { interval in
                            Button {
                                workspace.seek(to: interval.start)
                            } label: {
                                Label("\(timestamp(interval.start))–\(timestamp(interval.end)) 待复核",
                                      systemImage: "exclamationmark.circle").font(.caption)
                            }.buttonStyle(.link).disabled(workspace.busy || ui.marking)
                        }
                    }
                }.modifier(Card())
                Button {
                    chooseExportFolder()
                } label: {
                    Label("导出 MP4", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(workspace.playable == nil || workspace.busy || ui.marking || workspace.maskNeedsUpdate)
                if workspace.maskNeedsUpdate {
                    Text("水印框已变更，请先重新处理。").font(.caption).foregroundStyle(.secondary)
                }
                if let result = workspace.result {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([result])
                    } label: { Label("在 Finder 中显示", systemImage: "folder") }
                    .buttonStyle(.link)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if workspace.busy {
                ProgressView().controlSize(.small)
                Text(workspace.activity)
                Button("取消") { workspace.cancel() }.controlSize(.small)
            } else {
                Text(workspace.status)
            }
            Spacer()
            if !workspace.missing.isEmpty {
                Button { workspace.settings = true } label: {
                    Label("缺少 \(workspace.missing.count) 项依赖", systemImage: "exclamationmark.circle")
                }.buttonStyle(.link)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func chooseFile() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie,
                                    UTType(filenameExtension: "mkv") ?? .movie,
                                    UTType(filenameExtension: "webm") ?? .movie]
        open.allowsMultipleSelection = false
        if open.runModal() == .OK, let url = open.url { workspace.importVideo(url) }
    }

    private func chooseExportFolder() {
        if let url = workspace.exportFolder ?? selectFolder("导出到此文件夹") {
            workspace.export(to: url)
        }
    }

    private func videoBounds(in size: CGSize) -> CGRect {
        let pixels = workspace.player.currentItem?.presentationSize ?? .zero
        guard pixels.width > 0, pixels.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / pixels.width, size.height / pixels.height)
        let width = pixels.width * scale
        let height = pixels.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }
}

@MainActor
private func selectFolder(_ prompt: String, initial: URL? = nil) -> URL? {
    let open = NSOpenPanel()
    open.canChooseFiles = false
    open.canChooseDirectories = true
    open.canCreateDirectories = true
    open.directoryURL = initial
    open.prompt = prompt
    return open.runModal() == .OK ? open.url : nil
}

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(rule))
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct SetupView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var ui = SettingsState()

    var body: some View {
        ScrollView {
            settingsContent
                .padding(23)
        }
        .frame(width: 525)
        .frame(maxHeight: 640)
        .background(canvas).onAppear(perform: read)
        .onChange(of: workspace.provider) { _, _ in read() }
        .alert("清理下载内容？", isPresented: $ui.confirmCleanup) {
            Button("取消", role: .cancel) {}
            Button("永久清理", role: .destructive) { workspace.clearDownloads() }
        } message: {
            Text("将永久删除应用下载的原片和相关处理文件。清理后无法复原。已导出的 MP4 会保留。")
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置").font(.title2.bold())
                Spacer()
                Button("完成") { workspace.settings = false }.keyboardShortcut(.defaultAction)
            }
            storageSettings
            VStack(alignment: .leading, spacing: 10) {
                Text("AI 服务").font(.headline)
                Picker("服务商", selection: $workspace.provider) {
                    ForEach(Provider.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented)
                TextField("模型名称", text: $ui.model).textFieldStyle(.roundedBorder)
                SecureField(ui.keyOnFile ? "已储存 Key，输入可替换" : "API Key", text: $ui.key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存") { save() }
                    Button("测试连接") { test() }.disabled(ui.testing || !ui.keyOnFile)
                    if ui.keyOnFile { Button("删除 Key", role: .destructive) { save(remove: true) } }
                    if ui.testing { ProgressView().controlSize(.small) }
                }
                Text("仅将带时间戳的本地转写和缩略图发送到所选服务。Key 存于 macOS 钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
                if !ui.note.isEmpty {
                    Text(ui.note).font(.caption).foregroundStyle(accent).textSelection(.enabled)
                }
            }.modifier(Card()).disabled(workspace.busy || ui.testing)
            VStack(alignment: .leading, spacing: 9) {
                Text("本机依赖").font(.headline)
                Text(workspace.missing.isEmpty ? "下载、转写和水印组件均已就绪。" : workspace.missing.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("安装依赖") { workspace.install() }.disabled(workspace.busy || workspace.missing.isEmpty)
                    Button("重新检查") { workspace.refreshDependencies() }.disabled(workspace.busy)
                    if workspace.busy {
                        Text(workspace.activity).font(.caption).lineLimit(1)
                        Button("取消") { workspace.cancel() }
                    }
                }
            }.modifier(Card())
            VStack(alignment: .leading, spacing: 9) {
                Text("抖音下载").font(.headline)
                Text("遇到平台要求 Cookie 的提示时，可在本次运行中使用你选择的 Netscape Cookie 文件。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(workspace.hasCookies ? "更换 Cookie 文件" : "选择 Cookie 文件") {
                        let open = NSOpenPanel()
                        if open.runModal() == .OK { workspace.useDouyinCookies(open.url) }
                    }
                    if workspace.hasCookies { Button("清除") { workspace.useDouyinCookies(nil) } }
                }.disabled(workspace.busy)
            }.modifier(Card())
            if let error = workspace.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("存储位置").font(.headline)
            folderSetting("下载目录", value: $workspace.downloadFolder,
                          fallback: Workspace.jobsRoot.path, resetLabel: "恢复默认")
            Divider()
            folderSetting("MP4 导出目录", value: $workspace.exportFolder,
                          fallback: "每次导出时询问", resetLabel: "改为每次询问")
            Divider()
            HStack {
                Button("清理下载内容…", role: .destructive) { ui.confirmCleanup = true }
                if let status = workspace.cleanupStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .modifier(Card())
        .disabled(workspace.busy)
    }

    private func folderSetting(_ title: String, value: Binding<URL?>, fallback: String, resetLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Button("选择…") {
                    if let url = selectFolder("使用此文件夹", initial: value.wrappedValue) {
                        value.wrappedValue = url
                    }
                }
                .accessibilityLabel("选择\(title)")
                if value.wrappedValue != nil {
                    Button(resetLabel) { value.wrappedValue = nil }
                }
            }
            Text(value.wrappedValue?.path ?? fallback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func read() {
        let provider = workspace.provider
        ui.model = workspace.model(for: provider)
        ui.key = ""
        ui.note = ""
        do { ui.keyOnFile = try !provider.apiKey().isEmpty } catch {
            ui.keyOnFile = false
            ui.note = error.localizedDescription
        }
    }

    private func save(remove: Bool = false) {
        do {
            let provider = workspace.provider
            if remove { try provider.save(key: "") }
            else if !ui.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try provider.save(key: ui.key) }
            workspace.saveModel(ui.model, for: provider)
            read()
            ui.note = remove ? "已删除 Key" : "设置已保存"
        } catch { ui.note = error.localizedDescription }
    }

    private func test() {
        ui.testing = true
        ui.note = ""
        Task {
            defer { ui.testing = false }
            do {
                try await AIClient.make(workspace.provider, model: ui.model).testConnection()
                ui.note = "连接成功"
            } catch { ui.note = error.localizedDescription }
        }
    }
}

private final class EditorState: ObservableObject {
    @Published var marking = false
    @Published var drag: CGRect?
    @Published var editing: Cut?
    @Published var seconds = ""
}

private final class SettingsState: ObservableObject {
    @Published var confirmCleanup = false
    @Published var model = ""
    @Published var key = ""
    @Published var keyOnFile = false
    @Published var note = ""
    @Published var testing = false
}
