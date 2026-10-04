import Foundation
import CoreGraphics
import EasyPicCore

struct BrushTests {
    func image(_ bytes:[UInt8],width:Int=32,height:Int=24)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    func bytes(_ image:CGImage)->[UInt8] {
        let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
    }
    func run() throws {
        let white=image(Array(repeating:[UInt8(255),255,255,255],count:768).flatMap{$0})
        let erased=bytes(try BrushEngine.apply(BrushStroke(tool:.eraser,points:[CGPoint(x:2,y:12),CGPoint(x:30,y:12)],diameter:6),to:white))
        for x in 2..<30 { try expectEqual(erased[(12*32+x)*4+3],0) }
        try expectEqual(erased[3],255)
        let half=bytes(try BrushEngine.apply(BrushStroke(tool:.eraser,points:[CGPoint(x:16,y:12)],diameter:10,hardness:0.2,opacity:0.5),to:white))
        try expect(half[(12*32+16)*4+3] >= 127 && half[(12*32+16)*4+3] <= 130)
        try expect(half[(12*32+20)*4+3]>half[(12*32+16)*4+3])
        print("PASS · 画笔轨迹插值、透明擦除、硬度和透明度")
        var data=[UInt8](); for y in 0..<24 { for x in 0..<32 { data += [UInt8(x*8),UInt8(y*10),0,255] } }
        let gradient=image(data)
        let clone=bytes(try BrushEngine.apply(BrushStroke(tool:.clone,points:[CGPoint(x:20,y:12)],diameter:4,source:CGPoint(x:4,y:4)),to:gradient))
        try expectEqual(Array(clone[(12*32+20)*4..<(12*32+20)*4+4]),Array(data[(4*32+4)*4..<(4*32+4)*4+4]))
        for tool in [BrushTool.pixelate,.blur,.solid] {
            let result=bytes(try BrushEngine.apply(BrushStroke(tool:tool,points:[CGPoint(x:12,y:8)],strength:5,color:TextColor(1,0,0),rectangle:CGRect(x:8,y:6,width:10,height:8)),to:gradient))
            try expectEqual(Array(result[0..<4]),Array(data[0..<4])); try expect(result != data)
        }
        var spot: [UInt8]=Array(repeating:[UInt8(100),120,140,255],count:768).flatMap{$0}
        for y in 10..<14 { for x in 14..<18 { for c in 0..<3 { spot[(y*32+x)*4+c]=0 } } }
        let repaired=bytes(try BrushEngine.apply(BrushStroke(tool:.repair,points:[CGPoint(x:16,y:12)],diameter:8),to:image(spot)))
        try expectEqual(Array(repaired[(12*32+16)*4..<(12*32+16)*4+4]),[100,120,140,255])
        print("PASS · 克隆取样、三种矩形马赛克与局部纹理修复")
        let id=UUID(), clear=UUID(); var doc=EditorDocument(baseResourceID:clear,size:CGSize(width:32,height:24))
        var layer=StickerLayer(resourceID:id,name:"画笔",center:CGPoint(x:16,y:12),size:doc.size)
        layer.strokes=[BrushStroke(tool:.solid,points:[CGPoint(x:12,y:8)],rectangle:CGRect(x:8,y:6,width:10,height:8))]; doc.layers=[layer]
        let assets=[id:gradient,clear:image(Array(repeating:0,count:3072))]
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".easypic"); defer { try? FileManager.default.removeItem(at:url) }
        try DocumentEngine.save(doc,resources:assets,to:url); let (restored,resources)=try DocumentEngine.load(url)
        try expectEqual(bytes(try DocumentEngine.render(doc,resources:assets)),bytes(try DocumentEngine.render(restored,resources:resources)))
        var history=DocumentHistory(doc); var next=doc; next.layers[0].strokes?.append(BrushStroke(tool:.eraser,points:[CGPoint(x:4,y:4)])); history.apply(next); history.undo(); try expectEqual(history.document,doc)
        var baseDoc=EditorDocument(baseResourceID:id,size:CGSize(width:32,height:24)); baseDoc.baseStrokes=layer.strokes
        try expectEqual(bytes(try DocumentEngine.render(baseDoc,resources:assets)),bytes(try DocumentEngine.render(doc,resources:assets)))
        try expectThrows { _=try BrushEngine.apply(BrushStroke(tool:.solid,points:[.zero],color:TextColor(2,0,0)),to:gradient) }
        print("PASS · 画笔项目保存重开、底图笔画、像素一致与整笔撤销")
    }
}
