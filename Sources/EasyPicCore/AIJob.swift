import Foundation
import CoreGraphics
import ImageIO
import Darwin

public struct AIJobFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct CLIResult { public var code: Int32; public var output: String }
public final class CLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    public func run(executable: URL, arguments: [String], directory: URL? = nil, input: String = "", timeout: Double = 600,
                    event: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CLIResult {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached { [self] in
                let p = Process(); p.executableURL = executable; p.arguments = arguments; p.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                p.environment = environment
                let output = Pipe(), errors = Pipe(), stdin = Pipe()
                p.standardOutput = output; p.standardError = errors; p.standardInput = stdin
                let collector = CLICollector(event: event)
                output.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData, events: true) }
                errors.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData, events: false) }
                defer {
                    output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
                    try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
                    lock.withLock { process = nil }
                }
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    process = p
                    try p.run()
                }
                // Terminate on cancellation, with a bounded escalation if a CLI ignores SIGTERM.
                let started = Date()
                let monitor = DispatchSource.makeTimerSource(queue: .global())
                monitor.schedule(deadline: .now() + 0.2, repeating: 0.2)
                monitor.setEventHandler { [self] in
                    lock.lock(); let cancelled = self.cancelled; lock.unlock()
                    if (cancelled || Date().timeIntervalSince(started) > timeout), p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                    }
                }
                monitor.resume(); defer { monitor.cancel() }
                do { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close() }
                catch { if p.isRunning { p.terminate() }; throw error }
                p.waitUntilExit()
                output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
                collector.append(output.fileHandleForReading.readDataToEndOfFile(), events: true)
                collector.append(errors.fileHandleForReading.readDataToEndOfFile(), events: false)
                let wasCancelled = lock.withLock { cancelled }
                if wasCancelled { throw CancellationError() }
                if Date().timeIntervalSince(started) > timeout { throw AIJobFailure("任务超时，请缩短提示词或稍后重试。") }
                return CLIResult(code: p.terminationStatus, output: collector.output)
            }.value
        }, onCancel: { self.cancel() })
    }
}
private final class CLICollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data(), pending = Data()
    private let event: @Sendable (String) -> Void
    init(event: @escaping @Sendable (String) -> Void) { self.event = event }
    var output: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func append(_ chunk: Data, events: Bool) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); if data.count > 256_000 { data.removeFirst(data.count - 256_000) }
        var messages: [String] = []
        if events {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]; pending.removeSubrange(...end)
                if let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = json["type"] as? String {
                    if type == "turn.failed" || type == "error" { messages.append("任务报告错误") }
                    else if type == "item.started", let item = json["item"] as? [String: Any] { messages.append((item["type"] as? String) == "image_generation" ? "正在生成图片…" : "正在处理图片…") }
                    else if type == "turn.completed" { messages.append("正在校验生成结果…") }
                }
            }
            if pending.count > 256_000 { pending.removeAll() }
        }
        lock.unlock(); messages.forEach(event)
    }
}
public struct AICapabilities {
    public var version: String
    public var available: Bool
    public var message: String
    public init(version: String, available: Bool, message: String) { self.version = version; self.available = available; self.message = message }
}
public enum AIJobEngine {
    public static func detect(_ executable: URL) async throws -> AICapabilities {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else { throw AIJobFailure("找不到可执行的 Codex CLI，请选择本机 codex 文件。") }
        let version = try await CLIProcess().run(executable: executable, arguments: ["--version"], timeout: 15)
        let help = try await CLIProcess().run(executable: executable, arguments: ["exec", "--help"], timeout: 15)
        let features = try await CLIProcess().run(executable: executable, arguments: ["features", "list"], timeout: 15)
        let login = try await CLIProcess().run(executable: executable, arguments: ["login", "status"], timeout: 15)
        let enabled = features.output.split(separator: "\n").contains { $0.hasPrefix("image_generation") && $0.split(whereSeparator: \.isWhitespace).last == "true" }
        let available = version.code == 0 && help.output.contains("--output-schema") && help.output.contains("--image") && enabled && login.code == 0
        return AICapabilities(version: version.output.trimmingCharacters(in: .whitespacesAndNewlines), available: available,
                              message: available ? "CLI 与登录可用，已启用图片生成。实际模型能力以任务结果为准。" : "CLI 缺少图片生成能力或未登录，请先在终端配置 Codex。")
    }
    public static func prepare(input: CGImage, reference: CGImage?, mask: CGImage?, prompt: String, directory: URL) throws -> [String] {
        let fm = FileManager.default; try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try ImageEngine.encode(input, format: .png).write(to: directory.appendingPathComponent("input.png"))
        if let reference { try ImageEngine.encode(reference, format: .png).write(to: directory.appendingPathComponent("reference.png")) }
        if let mask { try ImageEngine.encode(mask, format: .png).write(to: directory.appendingPathComponent("mask.png")) }
        let schema: [String: Any] = ["type":"object", "properties":["image_path":["type":"string"],"message":["type":"string"]],"required":["image_path","message"],"additionalProperties":false]
        try JSONSerialization.data(withJSONObject: schema).write(to: directory.appendingPathComponent("schema.json"))
        var args = ["exec","--json","--ephemeral","--skip-git-repo-check","-s","workspace-write","-C",directory.path,"--image",directory.appendingPathComponent("input.png").path]
        if reference != nil { args += ["--image",directory.appendingPathComponent("reference.png").path] }
        if mask != nil { args += ["--image",directory.appendingPathComponent("mask.png").path] }
        args += ["--output-schema",directory.appendingPathComponent("schema.json").path,"-o",directory.appendingPathComponent("result.json").path,"-"]
        return args
    }
    public static func instruction(_ prompt: String, masked: Bool) -> String {
        """
        Use the built-in image generation/editing tool ($imagegen) to EDIT input.png. Do not use Python, SVG, canvas, or programmatic drawing as a substitute. Save the actual generated bitmap inside this task directory as output.png. Never modify input.png, reference.png, mask.png, schema.json or files outside this directory. Do not read credentials. Do not use a separately billed API fallback. If image generation is unavailable, return an empty image_path and explain why. Return image_path relative to this directory and a short message. The first image is the input; reference.png, when present, is the style reference.
        \(masked ? "mask.png is a visual selection guide: white marks the editable area, black marks protected content. Preserve all unmarked content. The app will composite only the selected region; this guide is not a guaranteed model mask." : "Preserve the input composition and dimensions unless requested otherwise.")
        User edit request:
        \(prompt)
        """
    }
    public static func validateResult(in directory: URL) throws -> CGImage {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("result.json"))) as? [String: Any]
        guard let path = json?["image_path"] as? String, !path.isEmpty else { throw AIJobFailure((json?["message"] as? String) ?? "CLI 没有返回图片结果。") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), !["input.png","reference.png","mask.png"].contains(url.lastPathComponent) else { throw AIJobFailure("结果路径不在任务目录内，或返回了输入图片。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true, let length = values.fileSize, length > 0, length < 200_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 100_000_000 else { throw AIJobFailure("结果不是有效图片，或尺寸超出允许范围。") }
        return try ImageEngine.load(url).image
    }
    public static func selectedResult(_ result: CGImage, over original: CGImage, rect: CGRect?) throws -> CGImage {
        let size = CGSize(width:original.width,height:original.height)
        guard let c=CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        c.draw(original,in:CGRect(origin:.zero,size:size))
        if let rect { c.clip(to:CGRect(x:rect.minX,y:size.height-rect.maxY,width:rect.width,height:rect.height)) }
        c.draw(result,in:CGRect(origin:.zero,size:size))
        guard let image=c.makeImage() else { throw ImageFailure.renderFailed }; return image
    }
}
