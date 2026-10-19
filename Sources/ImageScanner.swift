import Foundation
import ImageIO

extension MediaScanner {
    static let extensions = ["mov", "mp4", "m4v", "jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "tif", "tiff", "psd", "psb"]
    func photoshop() throws {
        let header = try read(0,26)
        let version = number(header,4,2)
        guard header.prefix(4) == Data("8BPS".utf8), [1,2].contains(version),
              header[6..<12].allSatisfy({ $0 == 0 }), number(header,12,2) > 0,
              number(header,14,4) > 0, number(header,18,4) > 0 else {
            throw ScanError.invalid("Cabeçalho PSD/PSB inválido")
        }
        let colorSize = number(try read(26,4),0,4)
        let resourceStart = 30+colorSize
        let resourceSize = number(try read(resourceStart,4),0,4)
        var pos = resourceStart+4
        guard pos <= report.fileSize, resourceSize <= report.fileSize-pos else { throw ScanError.invalid("Recursos PSD truncados") }
        let end = pos+resourceSize
        while pos < end {
            try tick()
            guard end-pos >= 12 else { throw ScanError.invalid("Recurso PSD truncado") }
            let resource = try read(pos,7)
            guard resource.prefix(4) == Data("8BIM".utf8) else { throw ScanError.invalid("Assinatura de recurso PSD não suportada") }
            let id = number(resource,4,2), nameSize = UInt64(resource[6])+1
            let lengthPos = pos+6+nameSize+nameSize%2
            guard lengthPos+4 <= end else { throw ScanError.invalid("Nome de recurso PSD truncado") }
            let length = number(try read(lengthPos,4),0,4), dataStart = lengthPos+4
            guard length+length%2 <= end-dataStart else { throw ScanError.invalid("Dados de recurso PSD truncados") }
            if id == 1060 { xmp(try read(dataStart,length), "PSD/XMP@\(pos)") }
            pos = dataStart+length+length%2
        }
        let layerLengthBytes = version == 1 ? 4 : 8
        let layerLength = number(try read(end,UInt64(layerLengthBytes)),0,layerLengthBytes)
        let layerStart = end+UInt64(layerLengthBytes)
        guard layerStart <= report.fileSize, layerLength <= report.fileSize-layerStart,
              report.fileSize-layerStart-layerLength >= 2 else { throw ScanError.invalid("Estrutura PSD/PSB incompleta") }
        warning("PSD/PSB: leitura limitada ao XMP global; camadas, objetos inteligentes e dados proprietários não verificados.")
    }
    private func tick() throws {
        boxCount += 1
        guard boxCount < 100_000 else { throw ScanError.invalid("Número excessivo de blocos de imagem") }
    }
    private func little(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
        data[start..<start+count].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private func inflateXMP(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw ScanError.invalid("XMP comprimido vazio") }
        var capacity = 65536
        while capacity <= 32 * 1024 * 1024 {
            var output = Data(count: capacity), length = uLong(capacity)
            let result = output.withUnsafeMutableBytes { dest in
                data.withUnsafeBytes { src in
                    uncompress(dest.bindMemory(to: Bytef.self).baseAddress!, &length, src.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count))
                }
            }
            if result == Z_OK { output.count = Int(length); return output }
            guard result == Z_BUF_ERROR else { throw ScanError.invalid("XMP comprimido inválido") }
            capacity *= 2
        }
        throw ScanError.invalid("XMP descomprimido excede o limite de 32 MiB")
    }
    private func manifest(_ data: Data, _ location: String) throws {
        // JUMBF is a general-purpose container: only the c2pa content type counts.
        let typeUUID = Data([0x63,0x32,0x70,0x61,0x00,0x11,0x00,0x10,0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71])
        guard data.count >= 33, String(decoding: data[4..<8], as: UTF8.self) == "jumb",
              String(decoding: data[12..<16], as: UTF8.self) == "jumd",
              data.subdata(in: 16..<32) == typeUUID else {
            warning("Bloco de credenciais não reconhecido em \(location).")
            return
        }
        report.hasC2PA = true
        try jumbf(data, location)
    }
    func png() throws {
        guard try read(0, 8) == Data([137,80,78,71,13,10,26,10]) else { throw ScanError.invalid("Assinatura PNG inválida") }
        var pos: UInt64 = 8, sawHeader = false, sawPixels = false, sawEnd = false
        while pos < report.fileSize {
            try tick()
            guard report.fileSize-pos >= 12 else { throw ScanError.invalid("PNG truncado") }
            let header = try read(pos, 8), size = number(header,0,4)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            guard size <= report.fileSize-pos-12 else { throw ScanError.invalid("Bloco PNG truncado") }
            if !sawHeader {
                guard type == "IHDR", size == 13 else { throw ScanError.invalid("Cabeçalho PNG inválido") }
                sawHeader = true
            }
            if type == "IDAT" { sawPixels = true }
            if ["caBX", "iTXt", "zTXt", "tEXt"].contains(type) {
                let data = try read(pos+8,size)
                let expected = number(try read(pos+8+size,4),0,4)
                let checked = Data(header[4..<8]) + data
                let crc = checked.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(checked.count)) }
                guard UInt64(crc) == expected else { throw ScanError.invalid("Metadados PNG com CRC inválido") }
                if type == "caBX" { try manifest(data, "PNG/caBX@\(pos)") }
                else if let nul = data.firstIndex(of: 0), String(decoding: data[..<nul], as: UTF8.self) == "XML:com.adobe.xmp" {
                    var start = nul+1
                    if type == "iTXt" {
                        guard data.count-start >= 2 else { throw ScanError.invalid("iTXt truncado") }
                        let compressed = data[start], method = data[start+1]; start += 2
                        guard compressed <= 1, method == 0 else { throw ScanError.invalid("Compressão iTXt não suportada") }
                        for _ in 0..<2 {
                            guard let end = data[start...].firstIndex(of: 0) else { throw ScanError.invalid("iTXt truncado") }
                            start = end+1
                        }
                        let text = data.subdata(in: start..<data.count)
                        xmp(compressed == 1 ? try inflateXMP(text) : text, "PNG/iTXt@\(pos)")
                    } else if type == "zTXt" {
                        guard start < data.count, data[start] == 0 else { throw ScanError.invalid("zTXt inválido") }
                        xmp(try inflateXMP(data.subdata(in: start+1..<data.count)), "PNG/zTXt@\(pos)")
                    } else { xmp(data.subdata(in: start..<data.count), "PNG/tEXt@\(pos)") }
                }
            }
            pos += 12+size
            if type == "IEND" {
                guard size == 0 else { throw ScanError.invalid("IEND inválido") }
                sawEnd = true; break
            }
        }
        guard sawHeader && sawPixels && sawEnd else { throw ScanError.invalid("Estrutura PNG incompleta") }
        if pos != report.fileSize { warning("Há dados depois do final da imagem PNG; não foram interpretados.") }
    }
    func jpeg() throws {
        guard try read(0,2) == Data([0xff,0xd8]) else { throw ScanError.invalid("Assinatura JPEG inválida") }
        var pos: UInt64 = 2, sawFrame = false, sawScan = false
        var streams: [UInt64: (next: UInt64, data: Data)] = [:]
        var extended: [String: (size: Int, chunks: [Int: Data])] = [:]
        while pos < report.fileSize {
            try tick()
            guard try read(pos,1)[0] == 0xff else { throw ScanError.invalid("Marcador JPEG inválido") }
            pos += 1
            var marker = try read(pos,1)[0]; pos += 1
            while marker == 0xff { try tick(); marker = try read(pos,1)[0]; pos += 1 }
            if marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            let length = number(try read(pos,2),0,2)
            guard length >= 2, length <= report.fileSize-pos else { throw ScanError.invalid("Segmento JPEG truncado") }
            if (0xc0...0xcf).contains(marker), ![0xc4,0xc8,0xcc].contains(marker) { sawFrame = true }
            if marker == 0xda { sawScan = true; break }
            if marker == 0xeb || marker == 0xe1 {
                let data = try read(pos+2,length-2)
                if marker == 0xeb, data.starts(with: [0x4a,0x50]) {
                    guard data.count >= 16 else { throw ScanError.invalid("APP11 truncado") }
                    let id = number(data,2,2), sequence = number(data,4,4)
                    if sequence == 1 {
                        guard streams[id] == nil else { throw ScanError.invalid("APP11 duplicado") }
                        streams[id] = (2, data.subdata(in: 8..<data.count))
                    } else {
                        guard var stream = streams[id], stream.next == sequence,
                              stream.data.prefix(8) == data.subdata(in: 8..<16) else { throw ScanError.invalid("Sequência APP11 incompleta") }
                        stream.data.append(data.subdata(in: 16..<data.count)); stream.next += 1
                        streams[id] = stream
                    }
                } else if marker == 0xe1 {
                    let prefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
                    let ext = Data("http://ns.adobe.com/xmp/extension/\0".utf8)
                    if data.starts(with: prefix) { xmp(data.subdata(in: prefix.count..<data.count), "JPEG/XMP@\(pos)") }
                    if data.starts(with: ext) {
                        let base = ext.count
                        guard data.count >= base+40 else { throw ScanError.invalid("XMP estendido truncado") }
                        let id = String(decoding: data[base..<base+32], as: UTF8.self)
                        let total = Int(number(data,base+32,4)), offset = Int(number(data,base+36,4))
                        guard total <= 32*1024*1024, offset <= total, data.count-base-40 <= total-offset else { throw ScanError.invalid("XMP estendido inválido") }
                        var group = extended[id] ?? (total, [:])
                        guard group.size == total, group.chunks[offset] == nil else { throw ScanError.invalid("XMP estendido inconsistente") }
                        group.chunks[offset] = data.subdata(in: base+40..<data.count); extended[id] = group
                    }
                }
            }
            pos += length
        }
        for id in streams.keys.sorted() { try manifest(streams[id]!.data, "JPEG/APP11/\(id)") }
        for (id, group) in extended {
            var data = Data()
            for offset in group.chunks.keys.sorted() {
                guard offset == data.count else { throw ScanError.invalid("XMP estendido incompleto") }
                data.append(group.chunks[offset]!)
            }
            guard data.count == group.size else { throw ScanError.invalid("XMP estendido incompleto") }
            xmp(data, "JPEG/XMP-estendido/\(id)")
        }
        guard sawFrame && sawScan, report.fileSize >= 2 else { throw ScanError.invalid("Estrutura JPEG incompleta") }
        if try read(report.fileSize-2,2) != Data([0xff,0xd9]) { warning("Final JPEG ausente ou com dados adicionais; leitura parcial.") }
    }
    func webp() throws {
        let header = try read(0,12)
        guard String(decoding: header[0..<4], as: UTF8.self) == "RIFF", String(decoding: header[8..<12], as: UTF8.self) == "WEBP",
              little(header,4,4)+8 == report.fileSize else { throw ScanError.invalid("Cabeçalho WebP inválido") }
        var pos: UInt64 = 12, sawPixels = false
        while pos < report.fileSize {
            try tick()
            guard report.fileSize-pos >= 8 else { throw ScanError.invalid("WebP truncado") }
            let chunk = try read(pos,8), size = little(chunk,4,4)
            let type = String(decoding: chunk[0..<4], as: UTF8.self)
            guard size+size%2 <= report.fileSize-pos-8 else { throw ScanError.invalid("Bloco WebP truncado") }
            if ["VP8 ", "VP8L", "ANMF"].contains(type) { sawPixels = true }
            if type == "C2PA" { try manifest(read(pos+8,size), "WebP/C2PA@\(pos)") }
            if type == "XMP " { xmp(try read(pos+8,size), "WebP/XMP@\(pos)") }
            pos += 8+size+size%2
        }
        guard sawPixels else { throw ScanError.invalid("Estrutura WebP incompleta") }
    }
    func tiff() throws {
        let header = try read(0,8)
        let order = String(decoding: header[0..<2], as: UTF8.self)
        guard ["II", "MM"].contains(order) else { throw ScanError.invalid("Assinatura TIFF inválida") }
        func num(_ data: Data, _ offset: Int, _ length: Int) -> UInt64 { order == "II" ? little(data,offset,length) : number(data,offset,length) }
        guard num(header,2,2) == 42 else { throw ScanError.invalid("TIFF não suportado (incluindo BigTIFF)") }
        var pending = [num(header,4,4)], visited = Set<UInt64>()
        while let pos = pending.popLast(), pos != 0 {
            try tick()
            guard visited.insert(pos).inserted else { throw ScanError.invalid("Ciclo nos diretórios TIFF") }
            let count = num(try read(pos,2),0,2)
            guard pos+2+count*12+4 <= report.fileSize else { throw ScanError.invalid("TIFF truncado") }
            for i in 0..<count {
                try tick()
                let entry = try read(pos+2+i*12,12)
                let tag = num(entry,0,2), type = num(entry,2,2), length = num(entry,4,4)
                if tag == 700 || tag == 52545 {
                    guard [1,7].contains(type) else { throw ScanError.invalid("Tipo de metadados TIFF não suportado") }
                    let data = length <= 4 ? entry.subdata(in: 8..<8+Int(length)) : try read(num(entry,8,4),length)
                    if tag == 700 { xmp(data,"TIFF/XMP@\(pos)") }
                    else { try manifest(data,"TIFF/C2PA@\(pos)") }
                }
                if [330,34665].contains(tag), type == 4, length > 0 {
                    guard length < 100_000 else { throw ScanError.invalid("Diretórios TIFF demais") }
                    let data = length == 1 ? entry.subdata(in: 8..<12) : try read(num(entry,8,4),length*4)
                    for j in 0..<Int(length) { let child = num(data,j*4,4); if child != 0 { pending.append(child) } }
                }
            }
            let next = num(try read(pos+2+count*12,4),0,4)
            if next != 0 { pending.append(next) }
        }
        guard !visited.isEmpty else { throw ScanError.invalid("TIFF sem diretórios de imagem") }
    }
    func validateHEIF(_ url: URL) throws {
        report.additionalSystemReads = true
        guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(image) > 0 else {
            throw ScanError.invalid("Imagem HEIC/HEIF/AVIF não reconhecida pelo macOS")
        }
        // ImageIO reads only metadata here; no pixel buffer is requested.
        if let metadata = CGImageSourceCopyMetadataAtIndex(image,0,nil), let data = CGImageMetadataCreateXMPData(metadata,nil) {
            xmp(data as Data, "ImageIO/XMP")
        }
    }
}
