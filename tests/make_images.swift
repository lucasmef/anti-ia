import Foundation
import CoreGraphics
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.5, alpha: 1))
context.fill(CGRect(x: 0,y: 0,width: 16,height: 16))
let image = context.makeImage()!
for (type, ext) in [("public.png","png"),("public.jpeg","jpg"),("public.tiff","tiff"),("public.heic","heic")] {
    for ai in [false,true] {
        let url = directory.appendingPathComponent((ai ? "ai" : "plain") + "." + ext)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,type as CFString,1,nil) else { fatalError("No encoder: \(type)") }
        if ai {
            let meta = CGImageMetadataCreateMutable()
            var error: Unmanaged<CFError>?
            precondition(CGImageMetadataRegisterNamespaceForPrefix(meta, "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString, "Iptc4xmpExt" as CFString, &error))
            precondition(CGImageMetadataSetValueWithPath(meta,nil,"Iptc4xmpExt:DigitalSourceType" as CFString,"http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia" as CFString))
            CGImageDestinationAddImageAndMetadata(dest,image,meta,nil)
        } else { CGImageDestinationAddImage(dest,image,nil) }
        precondition(CGImageDestinationFinalize(dest), "Could not encode \(url)")
    }
}
