import SwiftUI
import AppKit
import EasyPicCore

extension EditorModel {
    func openAI() {
        chooseEditorTool(.ai)
    }
    func chooseAIExecutable() {
        guard canUseLayers else { return }
        let panel = NSOpenPanel()
        choosingOpenLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingOpenLocation = false
            if response == .OK, let url = panel.url { self.cliPath = url.path }
        }
    }
    func importAIReference() {
        guard canUseLayers else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        choosingOpenLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingOpenLocation = false
            guard response == .OK, let url = panel.url else { return }
            self.busy = true
            Task {
                defer { self.busy = false }
                do { self.aiReference = try await Task.detached { try ImageEngine.load(url).image }.value }
                catch { self.aiMessage = error.localizedDescription }
            }
        }
    }
    func runAI() {
        guard canUseLayers, !aiRunning, !aiSelecting, let doc = document, !aiPrompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let prompt = aiPrompt, assets = resources, reference = aiReference, rect = aiSelection
        let executable = URL(fileURLWithPath: cliPath), runner = CLIProcess()
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EasyPic/AIJobs/" + UUID().uuidString)
        aiRunner = runner; aiRunning = true; aiResult = nil; aiMessage = "正在检查本机 Codex…"
        aiTask = Task { [self] in
            defer { aiRunning = false; aiRunner = nil }
            do {
                let capability = try await AIJobEngine.detect(executable)
                guard capability.available else { throw AIJobFailure(capability.message) }
                let input = try await Task.detached { try DocumentEngine.render(doc,resources:assets) }.value
                aiInput = input
                let mask: CGImage? = rect.map { rect in
                    let c=CGContext(data:nil,width:input.width,height:input.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    c.setFillColor(CGColor(gray:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:input.width,height:input.height))
                    c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:rect.minX,y:CGFloat(input.height)-rect.maxY,width:rect.width,height:rect.height)); return c.makeImage()!
                }
                let args = try AIJobEngine.prepare(input:input,reference:reference,mask:mask,prompt:prompt,directory:directory)
                aiMessage = "正在调用图片生成工具…"
                let result = try await runner.run(executable:executable,arguments:args,directory:directory,input:AIJobEngine.instruction(prompt,masked:rect != nil)) { [weak self] message in
                    Task { @MainActor in self?.aiMessage = message }
                }
                try Task.checkCancellation()
                guard result.code == 0 else { throw AIJobFailure("Codex 任务失败（退出码 \(result.code)），请检查本机模型与图片生成能力。") }
                let generated=try AIJobEngine.validateResult(in:directory)
                aiResult = try AIJobEngine.selectedResult(generated,over:input,rect:rect)
                aiMessage = "结果已校验，选择应用后才会修改图片。"
                aiJobDirectory = directory
                let record = ["prompt":prompt,"status":"completed","selection":rect.map{NSStringFromRect($0)} ?? "full"]
                try JSONSerialization.data(withJSONObject:record).write(to:directory.appendingPathComponent("job.json"))
            } catch is CancellationError {
                aiMessage = "已取消，当前文档保持完整。"; try? FileManager.default.removeItem(at:directory)
            } catch {
                aiMessage = error.localizedDescription; try? FileManager.default.removeItem(at:directory)
            }
        }
    }
    func cancelAI() { aiRunner?.cancel(); aiTask?.cancel() }
    func applyAI() {
        guard canUseLayers, !aiSelecting, let result=aiResult, var doc=document else { return }
        let id=UUID(); resources[id]=result
        var layer=StickerLayer(resourceID:id,name:"AI · " + String(aiPrompt.prefix(24)),center:CGPoint(x:doc.size.width/2,y:doc.size.height/2),size:doc.size)
        layer.aiPrompt=aiPrompt; doc.layers.append(layer); selectedLayerID=layer.id
        aiResult=nil; aiInput=nil; aiSelection=nil; commitDocument(doc)
    }
    func closeAI() {
        guard !aiRunning else { return }; aiSelecting=false; activeEditorTool=nil
    }
}
struct AIEditorControls: View {
    @ObservedObject var model: EditorModel
    @State private var showOriginal = false
    @State private var detecting = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Codex CLI 路径",text:$model.cliPath).textFieldStyle(.roundedBorder)
                HStack {
                    Button("选择…", action: model.chooseAIExecutable)
                    Button("检测") {
                        detecting=true
                        Task { defer { detecting=false }; do { let info=try await AIJobEngine.detect(URL(fileURLWithPath:model.cliPath)); model.aiMessage=info.version + " · " + info.message } catch { model.aiMessage=error.localizedDescription } }
                    }.disabled(detecting)
                }
            }
            .disabled(model.aiRunning)
            Text("使用本机 Codex 配置与登录。图片、提示词和参考图会发送到所配置的云端服务，并计入相应用量。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$model.aiPrompt).disabled(model.aiRunning).frame(height:90).overlay(RoundedRectangle(cornerRadius:6).stroke(.secondary.opacity(0.3)))
            VStack(alignment: .leading, spacing: 10) {
                Button(model.aiReference == nil ? "添加参考图…" : "更换参考图…", action: model.importAIReference)
                if model.aiReference != nil { Button("移除参考图") { model.aiReference=nil } }
                Button(model.aiSelection == nil ? "选择局部区域…" : "重新选择区域…") { model.aiSelecting=true }
                if model.aiSelection != nil { Button("全图") { model.aiSelection=nil } }
                if model.aiSelecting {
                    Text("在画布上拖出选区。").font(.caption).foregroundStyle(.secondary)
                    Button("取消选择") { model.aiSelecting=false }
                }
            }
            .disabled(model.aiRunning)
            if model.aiSelection != nil { Text("仅将返回图片的选区合成到原图；选区蒙版作为参考，不保证模型严格执行蒙版编辑。").font(.caption).foregroundStyle(.secondary) }
            if let image = showOriginal ? model.aiInput : model.aiResult {
                Image(decorative:image,scale:1).resizable().scaledToFit().frame(maxWidth:.infinity).frame(height:240)
                Toggle("查看原图",isOn:$showOriginal)
            }
            HStack { if model.aiRunning || detecting { ProgressView().controlSize(.small) }; Text(model.aiMessage).font(.caption).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 10) {
                if model.aiRunning { Button("取消任务",action:model.cancelAI) }
                else { Button("收起 AI 工具",action:model.closeAI) }
                if model.aiResult != nil { Button("应用结果",action:model.applyAI).buttonStyle(.glassProminent).disabled(!model.canUseLayers) }
                Button(model.aiResult == nil ? "开始改图" : "重新生成",action:model.runAI).buttonStyle(.glassProminent).disabled(!model.canUseLayers || model.aiPrompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(detecting)
    }
}
struct AISelectionOverlay: View {
    @ObservedObject var model: EditorModel
    let scale:Double
    let size:CGSize
    @State private var start:CGPoint?
    var body:some View {
        ZStack(alignment:.topLeading) {
            Color.black.opacity(0.25)
            if let r=model.aiSelection { Rectangle().stroke(.orange,lineWidth:2).frame(width:r.width*scale,height:r.height*scale).offset(x:r.minX*scale,y:r.minY*scale) }
        }.frame(width:size.width,height:size.height).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onChanged { value in
            func point(_ p:CGPoint)->CGPoint { CGPoint(x:min(size.width,max(0,p.x))/scale,y:min(size.height,max(0,p.y))/scale) }
            let a=point(value.startLocation),b=point(value.location)
            model.aiSelection=CGRect(x:floor(min(a.x,b.x)),y:floor(min(a.y,b.y)),width:floor(abs(a.x-b.x)),height:floor(abs(a.y-b.y)))
        }.onEnded { _ in
            if let rect=model.aiSelection,rect.width<1 || rect.height<1 { model.aiSelection=nil }
            model.aiSelecting=false
        })
    }
}
