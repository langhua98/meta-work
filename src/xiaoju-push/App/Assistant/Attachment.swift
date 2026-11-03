import SwiftUI
import AVKit
import QuickLook
import UniformTypeIdentifiers

// 模型发来的文件：图片直接看，视频直接播，代码 / 文本看前几十行，其他的预览或分享。

struct Attachment: Identifiable, Equatable {
    enum Kind { case image, video, text, other }
    let id = UUID()
    let name: String
    let remotePath: String
    let url: URL
    let size: Int

    var kind: Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) || t.conforms(to: .xml)
            || ["md", "yml", "yaml", "toml", "swift", "py", "js", "ts", "sh", "csv", "log"].contains(ext) { return .text }
        return .other
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    /// 存到 缓存/附件/<随机>/<文件名>，保留原名方便分享
    static func save(_ data: Data, name: String) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("附件", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = base.appendingPathComponent(safe.isEmpty ? "文件" : safe)
        try data.write(to: url)
        return url
    }
}

struct AttachmentCard: View {
    let item: Attachment
    let saveToCloud: (Attachment) async throws -> String
    @State private var preview: URL?
    @State private var cloudStatus: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            footer
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .quickLookPreview($preview)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let img = UIImage(contentsOfFile: item.url.path) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .background(Theme.bg)
                    .onTapGesture { preview = item.url }
            } else { fileRow }
        case .video:
            VideoPlayer(player: AVPlayer(url: item.url))
                .frame(height: 220)
        case .text:
            Button { preview = item.url } label: {
                Text(textHead).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .lineLimit(24).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.bg)
            }
            .buttonStyle(PressStyle())
        case .other:
            Button { preview = item.url } label: { fileRow }.buttonStyle(PressStyle())
        }
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(Theme.blueText)
                .frame(width: 40, height: 40).background(Theme.blueSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("点开预览").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(12)
    }

    private var textHead: String {
        guard let d = try? Data(contentsOf: item.url) else { return "" }
        let s = String(decoding: d.prefix(8000), as: UTF8.self)
        return s.split(separator: "\n", omittingEmptySubsequences: false).prefix(24).joined(separator: "\n")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(cloudStatus ?? item.sizeText).font(.system(size: 11))
                    .foregroundStyle(cloudStatus?.hasPrefix("✓") == true ? Theme.green : Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Haptics.tap()
                saving = true
                Task {
                    do {
                        let p = try await saveToCloud(item)
                        cloudStatus = "✓ 已存到 \(p)"
                        Haptics.success()
                    } catch {
                        cloudStatus = error.localizedDescription
                        Haptics.error()
                    }
                    saving = false
                }
            } label: {
                if saving { ProgressView().controlSize(.small) } else { Image(systemName: "icloud.and.arrow.up") }
            }
            .disabled(saving || cloudStatus?.hasPrefix("✓") == true)
            .accessibilityLabel("存到云盘")
            ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("分享或保存")
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Theme.blueText)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
