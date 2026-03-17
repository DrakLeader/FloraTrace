import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TIFF 前景抠图批处理")
                .font(.title2.bold())

            pathRow(
                title: "输入目录",
                path: model.inputDirectory?.path ?? "",
                chooseAction: model.chooseInputDirectory
            )

            pathRow(
                title: "输出目录",
                path: model.outputDirectory?.path ?? "",
                chooseAction: model.chooseOutputDirectory
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("黑位滚降")
                    Spacer()
                    Text(String(format: "%.3f", model.blackPoint))
                        .monospacedDigit()
                }
                Slider(value: $model.blackPoint, in: 0.0 ... 0.20, step: 0.005)
                Text("默认值 0.03。值越大，接近纯黑的像素越容易被压到黑位。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            HStack {
                Button(model.isProcessing ? "处理中..." : "开始处理") {
                    model.startProcessing()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isProcessing || model.inputDirectory == nil || model.outputDirectory == nil)

                Spacer()
                Text(model.summaryText)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 560)
    }

    private func pathRow(title: String, path: String, chooseAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            HStack {
                Text(path.isEmpty ? "尚未选择目录" : path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Button("选择…", action: chooseAction)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var inputDirectory: URL?
    @Published var outputDirectory: URL?
    @Published var blackPoint: Double = 0.03
    @Published var isProcessing = false
    @Published var logs: [String] = []
    @Published var summaryText = "等待开始"

    private let processor = ImageBatchProcessor()

    func chooseInputDirectory() {
        guard let url = selectDirectoryPanel() else { return }
        inputDirectory = url

        let aliasName = "\(url.lastPathComponent)_alias"
        let sibling = url.deletingLastPathComponent().appendingPathComponent(aliasName, isDirectory: true)
        outputDirectory = sibling
        summaryText = "输入目录已选择，输出默认到同级 alias 目录"
    }

    func chooseOutputDirectory() {
        guard let url = selectDirectoryPanel() else { return }
        outputDirectory = url
        summaryText = "输出目录已更新"
    }

    func startProcessing() {
        guard !isProcessing, let inputDirectory, let outputDirectory else { return }
        isProcessing = true
        logs.removeAll(keepingCapacity: true)
        summaryText = "正在扫描 TIFF 文件..."

        let config = ProcessingConfig(
            inputRoot: inputDirectory,
            outputRoot: outputDirectory,
            blackPoint: blackPoint
        )

        Task {
            do {
                let summary = try await self.processor.process(config: config) { message in
                    await MainActor.run {
                        self.logs.append(message)
                    }
                }
                self.isProcessing = false
                self.summaryText = "完成：成功 \(summary.successCount)，失败 \(summary.failedCount)"
            } catch {
                self.isProcessing = false
                self.summaryText = "处理失败：\(error.localizedDescription)"
                self.logs.append("Fatal: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func selectDirectoryPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
