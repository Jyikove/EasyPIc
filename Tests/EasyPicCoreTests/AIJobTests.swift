import Foundation
import CoreGraphics
import EasyPicCore

struct AIJobTests {
    func run() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let input=try ImageEngine.load(Bundle.module.url(forResource:"Animated.png-frame0",withExtension:"png",subdirectory:"Fixtures")!).image
        let args=try AIJobEngine.prepare(input:input,reference:input,mask:nil,prompt:"test",directory:directory)
        try expect(args.contains("workspace-write")); try expect(!args.contains("danger-full-access")); try expect(args.filter{$0=="--image"}.count==2)
        func result(_ path:String) throws { try JSONSerialization.data(withJSONObject:["image_path":path,"message":"test"]).write(to:directory.appendingPathComponent("result.json")) }
        try result("input.png"); try expectThrows { _=try AIJobEngine.validateResult(in:directory) }
        try result("../outside.png"); try expectThrows { _=try AIJobEngine.validateResult(in:directory) }
        try ImageEngine.encode(input,format:.png).write(to:directory.appendingPathComponent("output.png"))
        try result("output.png"); let validated=try AIJobEngine.validateResult(in:directory); try expectEqual(validated.width,input.width)
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("escape.png"),withDestinationURL:directory.deletingLastPathComponent().appendingPathComponent("outside.png"))
        try result("escape.png"); try expectThrows { _=try AIJobEngine.validateResult(in:directory) }
        print("PASS · AI 参数隔离、真实图片校验、输入/越界/符号链接结果拒绝")
        let c=CGContext(data:nil,width:input.width,height:input.height,bitsPerComponent:8,bytesPerRow:input.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(CGRect(x:0,y:0,width:input.width,height:input.height))
        let rect=CGRect(x:2,y:2,width:4,height:4)
        let selected=try AIJobEngine.selectedResult(c.makeImage()!,over:input,rect:rect)
        func bytes(_ image:CGImage)->[UInt8] { c.clear(CGRect(x:0,y:0,width:input.width,height:input.height));c.draw(image,in:CGRect(x:0,y:0,width:input.width,height:input.height));return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:input.width*input.height*4)) }
        let original=bytes(input),changed=bytes(selected)
        for y in 0..<input.height { for x in 0..<input.width where !rect.contains(CGPoint(x:x,y:y)) { let i=(y*input.width+x)*4;try expectEqual(Array(original[i..<i+4]),Array(changed[i..<i+4])) } }
        print("PASS · AI 局部结果合成保留选区外实际像素")
        let shell=URL(fileURLWithPath:"/bin/sh")
        let resultOutput=try await CLIProcess().run(executable:shell,arguments:["-c","cat; printf '%s\\n' '{\"type\":\"turn.completed\"}'"],input:"test input\n",timeout:3)
        try expectEqual(resultOutput.code,0);try expect(resultOutput.output.contains("test input"))
        let runner=CLIProcess(); let task=Task { try await runner.run(executable:shell,arguments:["-c","exec sleep 20"],timeout:30) }
        try await Task.sleep(nanoseconds:200_000_000);runner.cancel()
        do { _=try await task.value;throw CheckFailure(description:"cancel did not throw") } catch is CancellationError {}
        do { _=try await CLIProcess().run(executable:shell,arguments:["-c","exec sleep 20"],timeout:0.2);throw CheckFailure(description:"timeout did not throw") } catch is AIJobFailure {}
        print("PASS · CLI 输入输出、取消和超时无死锁")
    }
    static func smoke(directory:URL,selected:Bool) async throws {
        let c=CGContext(data:nil,width:512,height:512,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:512,height:512))
        c.setFillColor(CGColor(red:0.9,green:0.1,blue:0.1,alpha:1));c.fillEllipse(in:CGRect(x:156,y:156,width:200,height:200))
        let image=c.makeImage()!
        var mask:CGImage?
        if selected {
            c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:0,y:0,width:512,height:512));c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:128,y:128,width:256,height:256));mask=c.makeImage()!
        }
        let prompt="Change the red circle into a blue ceramic sphere. Keep the white background and centered composition."
        let args=try AIJobEngine.prepare(input:image,reference:image,mask:mask,prompt:prompt,directory:directory)
        let result=try await CLIProcess().run(executable:URL(fileURLWithPath:"/opt/homebrew/bin/codex"),arguments:args,directory:directory,input:AIJobEngine.instruction(prompt,masked:selected),timeout:180) { print($0) }
        try result.output.write(to:directory.appendingPathComponent("events.log"),atomically:true,encoding:.utf8)
        guard result.code==0 else { throw AIJobFailure("Actual CLI failed: \(result.code), see private build events.log") }
        let generated=try AIJobEngine.validateResult(in:directory)
        let applied=try AIJobEngine.selectedResult(generated,over:image,rect:selected ? CGRect(x:128,y:128,width:256,height:256):nil)
        try ImageEngine.encode(applied,format:.png).write(to:directory.appendingPathComponent("applied.png"))
        print("Actual CLI generated and validated \(generated.width)×\(generated.height)")
    }
}
