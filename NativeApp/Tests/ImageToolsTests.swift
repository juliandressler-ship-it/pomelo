import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PDFKit

@main struct ImageToolsTests {
    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let c = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    static func main() async throws {
        let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<64 { for x in 0..<96 {
            ctx.setFillColor(CGColor(red: CGFloat(x % 23) / 23, green: CGFloat(y % 17) / 17, blue: CGFloat((x+y)%13)/13, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }}
        let original = ctx.makeImage()!, input = CIImage(cgImage: ctx.makeImage()!)
        if let renderedInput = ImageOps.render(input) {
        let baseline = pixels(renderedInput)
        check(pixels(ImageOps.render(ImageOps.adjusted(input, .neutral))!) == baseline, "neutral adjustment preserves pixels")
        let adjustments: [(String, (inout PhotoAdjustments) -> Void)] = [
            ("exposure", {$0.exposure=1}), ("brightness", {$0.brightness=0.2}), ("contrast", {$0.contrast=1.5}),
            ("highlights", {$0.highlights=0.3}), ("shadows", {$0.shadows=0.8}), ("saturation", {$0.saturation=0}),
            ("vibrance", {$0.vibrance=1}), ("temperature", {$0.temperature=3000}), ("tint", {$0.tint=70}),
            ("sharpness", {$0.sharpness=1}), ("clarity", {$0.clarity=1}), ("dehaze", {$0.dehaze=1}),
            ("noise reduction", {$0.noiseReduction=1}), ("grain", {$0.grain=1}), ("vignette", {$0.vignette=1}),
            ("sepia", {$0.sepia=1}), ("monochrome", {$0.monochrome=true})]
        for (name, change) in adjustments {
            var a = PhotoAdjustments(); change(&a)
            if let result = ImageOps.render(ImageOps.adjusted(input,a)) {
                check(result.width == 96 && result.height == 64 && pixels(result) != baseline, "\(name) changes pixels and preserves dimensions")
            } else { check(false, "\(name) renders") }
        }
        for style in RedactionStyle.allCases {
            let result = ImageOps.render(ImageOps.redact(input,redactions:[Redaction(rect:CGRect(x:20,y:20,width:30,height:30),style:style)]))!
            check(pixels(result) != baseline && result.width == 96 && result.height == 64,"\(style) redaction changes pixels")
        }
        } else {
            print("BLOCKED CoreImage rendering unavailable in this process; adjustments and redaction require a graphics-capable run")
        }
        let baseline = pixels(original)
        for turns in 0..<4 {
            let rotated = try ImageOps.rotated(original, quarterTurns: turns, flipHorizontal: false, flipVertical: false)
            check(rotated.width == (turns%2 == 0 ? 96 : 64) && rotated.height == (turns%2 == 0 ? 64 : 96), "rotation \(turns) dimensions")
            let restored = try ImageOps.rotated(rotated, quarterTurns: -turns, flipHorizontal: false, flipVertical: false)
            check(pixels(restored) == baseline, "rotation \(turns) reverses exactly")
        }
        for horizontal in [true,false] {
            let flipped = try ImageOps.rotated(original, quarterTurns: 0, flipHorizontal: horizontal, flipVertical: !horizontal)
            check(try pixels(flipped) != baseline && pixels(ImageOps.rotated(flipped, quarterTurns: 0, flipHorizontal: horizontal, flipVertical: !horizontal)) == baseline, "flip \(horizontal) reverses exactly")
        }
        let resized = ImageIOBridge.scaled(original, to: CGSize(width: 24,height:16))
        check(resized.width == 24 && resized.height == 16, "resize dimensions")
        let crop = ImageIOBridge.cropped(original,to:CGRect(x:10,y:10,width:20,height:15))
        check(crop.width == 20 && crop.height == 15, "crop dimensions")
        var frame = ImageOps.FrameOptions(); frame.aspect = CGSize(width:16,height:9); frame.padding=0.1; frame.shadow=0
        let framed = ImageOps.framed(original,options:frame)!
        check(abs(Double(framed.width)/Double(framed.height)-16.0/9.0) < 0.025,"frame preserves selected 16:9 ratio with padding")
        for layout in ImageOps.CollageLayout.allCases {
            var options = ImageOps.CollageOptions(); options.width=240; options.height=180; options.spacing=8; options.layout=layout
            let frames = ImageOps.collageFrames(count:3,options:options)
            check(frames.count == 3 && frames.allSatisfy {$0.width>0 && $0.height>0 && CGRect(x:0,y:0,width:240,height:180).contains($0)},"\(layout) collage frames fit")
            let collage = ImageOps.collage([original,original,original],options:options)!
            check(collage.width==240 && collage.height==180,"\(layout) collage dimensions")
        }
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("image-tools-\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let source=dir.appendingPathComponent("fixture.tiff")
        let dest=CGImageDestinationCreateWithURL(source as CFURL,UTType.tiff.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,original,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFArtist:"Private Artist"],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:23.0,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:72.0,kCGImagePropertyGPSLongitudeRef:"E"]] as CFDictionary)
        check(CGImageDestinationFinalize(dest),"metadata fixture writes")
        let fields=await MetadataOps.read(source)
        check(fields.contains {$0.key=="Artist"},"metadata reads artist")
        let cleaned=dir.appendingPathComponent("clean.tiff")
        try await MetadataOps.write(source,edits:fields.filter(\.editable),removeAll:false,removeSensitive:true,to:cleaned,progress:{_ in})
        let cleanFields=await MetadataOps.read(cleaned)
        check(!cleanFields.contains {$0.key=="Artist" || $0.group=="GPS"},"remove sensitive does not restore artist from unchanged fields")
        let cleared=dir.appendingPathComponent("cleared.tiff")
        var clearEdits=fields.filter(\.editable)
        for index in clearEdits.indices where clearEdits[index].key == "Artist" { clearEdits[index].value = "" }
        try await MetadataOps.write(source,edits:clearEdits,removeAll:false,removeSensitive:false,to:cleared,progress:{_ in})
        check(!(await MetadataOps.read(cleared)).contains {$0.key=="Artist"}, "clearing editable metadata actually deletes value")
        let all=dir.appendingPathComponent("all.tiff")
        try await MetadataOps.write(source,edits:fields,removeAll:true,removeSensitive:false,to:all,progress:{_ in})
        check(!(await MetadataOps.read(all)).contains {$0.key=="Artist" || $0.group=="GPS"},"remove all metadata strips artist GPS")
        let text=dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to:text)
        check(try FileAction.hashReport([text]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt", "SHA256 known vector")
        let first=try FileAction.duplicateFiles([text])[0], second=try FileAction.duplicateFiles([text])[0]
        check(try first != second && Data(contentsOf:first) == Data("abc".utf8) && Data(contentsOf:second) == Data("abc".utf8), "duplicate keeps bytes and avoids overwriting")
        let pdf=PDFDocument(); pdf.insert(PDFPage(image:NSImage(cgImage:original,size:NSSize(width:96,height:64)))!,at:0)
        pdf.documentAttributes=[PDFDocumentAttribute.authorAttribute:"Private Person",PDFDocumentAttribute.titleAttribute:"Keep title"]
        let pdfURL=dir.appendingPathComponent("meta.pdf"); check(pdf.write(to:pdfURL), "PDF metadata fixture writes")
        let pdfClean=dir.appendingPathComponent("meta-clean.pdf")
        try await MetadataOps.write(pdfURL,edits:await MetadataOps.read(pdfURL),removeAll:false,removeSensitive:true,to:pdfClean,progress:{_ in})
        let pdfFields=await MetadataOps.read(pdfClean)
        check(!pdfFields.contains {$0.key=="Author"} && pdfFields.contains {$0.value=="Keep title"}, "PDF sensitive stripping retains title")
        // Nachbau Phase 4
        // QR-Code lesen: Bild und PDF
        let qrFilter = CIFilter(name: "CIQRCodeGenerator")!
        qrFilter.setValue(Data("https://example.com/open-tangerine".utf8), forKey: "inputMessage")
        let qrCI = qrFilter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let qrPadded = qrCI.transformed(by: CGAffineTransform(translationX: 40, y: 40)).composited(over: CIImage(color: .white).cropped(to: qrCI.extent.insetBy(dx: -40, dy: -40).offsetBy(dx: 40, dy: 40)))
        let qrImage = ImageOps.render(qrPadded)!
        let qrURL = dir.appendingPathComponent("qr.png")
        try ImageIOBridge.write(qrImage, to: qrURL, format: .png)
        let qrCodes = try VisionOps.codes(in: qrURL)
        check(qrCodes.map(\.text) == ["https://example.com/open-tangerine"] && qrCodes.first?.kind == "QR code", "QR code read from image")
        let qrPDF = dir.appendingPathComponent("qr.pdf")
        try PDFOps.fromImages([qrURL], to: qrPDF, progress: { _ in })
        let pdfCodes = try VisionOps.codes(in: qrPDF)
        check(pdfCodes.first?.text == "https://example.com/open-tangerine" && pdfCodes.first?.page == 1, "QR code read from PDF page 1")
        check(try VisionOps.codes(in: original).isEmpty, "no code in noise image")
        // Drucken: PDF, Bild und Text werden ein Druckauftrag; Gesperrtes und Nicht-Druckbares wird abgelehnt
        let printDoc = try await Printing.document(for: [qrPDF, qrURL, text])
        check(printDoc.pageCount == 3, "print job combines PDF, image and text pages")
        check(printDoc.page(at: 2)?.string?.contains("abc") == true, "print job text page has real text")
        let qrSize = printDoc.page(at: 1)?.bounds(for: .mediaBox).size
        check(qrSize?.width == CGFloat(qrImage.width) && qrSize?.height == CGFloat(qrImage.height), "print job image page keeps image proportions")
        let markdown = dir.appendingPathComponent("print.md"); try Data("# Title\n\nSome *text*".utf8).write(to: markdown)
        check(try await Printing.document(for: [markdown]).page(at: 0)?.string?.contains("Title") == true, "markdown prints as formatted text")
        let locked = dir.appendingPathComponent("locked.pdf")
        check(PDFDocument(url: qrPDF)!.write(to: locked, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "geheim2"]), "locked PDF fixture writes")
        do { _ = try await Printing.document(for: [locked]); check(false, "locked PDF rejected for printing") }
        catch OpenTangerineError.invalidInput(let message) { check(message.contains("password"), "locked PDF rejected for printing") }
        let song = dir.appendingPathComponent("song.mp3"), word = dir.appendingPathComponent("brief.docx")
        check(Printing.canPrint([qrPDF, qrURL, text, markdown]) && !Printing.canPrint([qrPDF, song]) && !Printing.canPrint([word]) && !Printing.canPrint([dir]), "printable formats: PDF, images, text only")
        check(RadialController.printItems(for: [qrURL, qrPDF]).map(\.label) == ["PRINT"] && RadialController.printItems(for: [song]).isEmpty, "PRINT shown in the convert wheel for printable files")
        check(FileAction.wheel(for: [qrURL]).contains(.print) && !FileAction.wheel(for: [song]).contains(.print) && FileAction.wheel(for: [song]).count == FileAction.wheel.count - 1, "Print shown in the actions wheel only for printable files")
        // Beschriften: Rahmen landet als Pixel im Bild, Größe bleibt
        let white = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        white.setFillColor(CGColor(gray: 1, alpha: 1)); white.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let blank = white.makeImage()!
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let annotated = try AnnotationRenderer.render(blank, marks: [AnnotationMark(kind: .rectangle, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 120, y: 60), color: red, size: 6)])
        let ap = pixels(annotated)
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let i = (y * 200 + x) * 4; return (ap[i], ap[i + 1], ap[i + 2]) }
        check(annotated.width == 200 && annotated.height == 100, "annotation keeps image size")
        check(px(20, 30) == (255, 0, 0) && px(70, 35) == (255, 255, 255), "annotation frame drawn at the right place, inside untouched")
        // Echtes Schwärzen: Pixel im Bereich sind vollständig schwarz
        let secret = ImageOps.render(ImageOps.redact(CIImage(cgImage: original), redactions: [Redaction(rect: CGRect(x: 10.4, y: 10.6, width: 30.3, height: 20.2))]))!
        let sp = pixels(secret)
        var allBlack = true
        for y in 11..<30 { for x in 11..<40 { let i = (y * 96 + x) * 4; if sp[i] != 0 || sp[i + 1] != 0 || sp[i + 2] != 0 { allBlack = false } } }
        check(allBlack, "solid redaction overwrites every pixel in the area")
        check(RedactionStyle.solid.isSecure && !RedactionStyle.blur.isSecure && !RedactionStyle.pixelate.isSecure, "only solid redaction counts as secure")
        // Hintergrund entfernen: dunkles Motiv auf hellem Grund
        let subject = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        subject.setFillColor(CGColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)); subject.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        subject.setFillColor(CGColor(srgbRed: 0.9, green: 0.35, blue: 0.1, alpha: 1)); subject.fillEllipse(in: CGRect(x: 200, y: 120, width: 240, height: 240))
        subject.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.2, alpha: 1)); subject.fillEllipse(in: CGRect(x: 330, y: 330, width: 90, height: 50))
        do {
            let cut = try VisionOps.removeBackground(subject.makeImage()!)
            let cp = pixels(cut)
            let corner = cp[3], centre = cp[((240) * 640 + 320) * 4 + 3]
            check(cut.width == 640 && corner < 20 && centre > 200, "background removed: corner transparent (\(corner)), subject kept (\(centre))")
        } catch {
            check(false, "background removal: \(error.localizedDescription)")
        }
        print("Image tool failures: \(failures)")
        if failures > 0 { exit(1) }
    }
}
