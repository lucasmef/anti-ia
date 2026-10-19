import Foundation

struct Evidence: Codable {
    let kind: String
    let value: String
    let location: String
}

struct ScanReport: Encodable {
    var file: String
    var status = "inconclusive"
    var bytesRead: UInt64 = 0
    var fileSize: UInt64 = 0
    var milliseconds: Double = 0
    var hasC2PA = false
    var additionalSystemReads = false
    var detectedFormat: String?
    var evidence: [Evidence] = []
    var warnings: [String] = []
    let scope = "Metadados locais de vídeos e imagens. Sem análise de imagem/áudio, consulta ao Instagram ou validação criptográfica C2PA. A ausência de sinais não garante ausência de rótulo."
}

enum ScanError: Error { case invalid(String) }

// Bounded CBOR reader: decodes assertions, never executes embedded content.
struct CBORReader {
    let bytes: [UInt8]
    var offset = 0
    var nodes = 0
    mutating func uint(_ count: Int) throws -> UInt64 {
        guard count <= bytes.count - offset else { throw ScanError.invalid("CBOR truncado") }
        var value: UInt64 = 0
        for _ in 0..<count { value = (value << 8) | UInt64(bytes[offset]); offset += 1 }
        return value
    }
    mutating func read(_ depth: Int = 0) throws -> Any {
        nodes += 1
        guard depth < 64, nodes < 100_000, offset < bytes.count else { throw ScanError.invalid("Limite CBOR") }
        let head = bytes[offset]; offset += 1
        let major = head >> 5, extra = head & 31
        if extra == 31 {
            guard (2...5).contains(major) else { throw ScanError.invalid("CBOR indefinido inválido") }
            var array: [Any] = [], map: [String: Any] = [:], binary = Data(), string = ""
            while true {
                guard offset < bytes.count else { throw ScanError.invalid("CBOR indefinido truncado") }
                if bytes[offset] == 0xff { offset += 1; break }
                if major == 2 || major == 3 {
                    guard bytes[offset] >> 5 == major, bytes[offset] & 31 != 31 else { throw ScanError.invalid("Fragmento CBOR inválido") }
                }
                let value = try read(depth+1)
                switch major {
                case 2: binary.append(value as! Data)
                case 3: string += value as! String
                case 4: array.append(value)
                case 5:
                    let item = try read(depth+1)
                    if let key = value as? String {
                        guard map[key] == nil else { throw ScanError.invalid("Chave CBOR duplicada") }
                        map[key] = item
                    }
                default: break
                }
            }
            switch major {
            case 2: return binary
            case 3: return string
            case 4: return array
            default: return map
            }
        }
        let n: UInt64
        switch extra {
        case 0...23: n = UInt64(extra)
        case 24: n = try uint(1)
        case 25: n = try uint(2)
        case 26: n = try uint(4)
        case 27: n = try uint(8)
        default: throw ScanError.invalid("CBOR inválido")
        }
        switch major {
        case 0, 1: return n
        case 2, 3:
            guard n <= UInt64(bytes.count - offset) else { throw ScanError.invalid("CBOR truncado") }
            let end = offset + Int(n); defer { offset = end }
            if major == 3 {
                guard let value = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw ScanError.invalid("Texto CBOR inválido") }
                return value
            }
            return Data(bytes[offset..<end])
        case 4:
            guard n < 100_000 else { throw ScanError.invalid("CBOR grande demais") }
            var values: [Any] = []
            for _ in 0..<n { values.append(try read(depth + 1)) }
            return values
        case 5:
            guard n < 100_000 else { throw ScanError.invalid("CBOR grande demais") }
            var values: [String: Any] = [:]
            for _ in 0..<n {
                let key = try read(depth + 1), value = try read(depth + 1)
                if let key = key as? String { values[key] = value }
            }
            return values
        case 6: return try read(depth + 1)
        case 7: return NSNull()
        default: throw ScanError.invalid("CBOR inválido")
        }
    }
}

final class XMPReader: NSObject, XMLParserDelegate {
    var sources: [String] = []
    var tools: [String] = []
    var active: String?
    var text = ""
    let iptc = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    var namespaces: [String: [String]] = [:]
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { namespaces[prefix, default: []].append(uri) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        for (key, value) in attributes {
            let parts = key.split(separator: ":").map(String.init)
            if parts.count == 2, parts[1] == "DigitalSourceType", namespaces[parts[0]]?.last == iptc { sources.append(value) }
            if parts.count == 2, parts[1] == "CreatorTool", namespaces[parts[0]]?.last == "http://ns.adobe.com/xap/1.0/" { tools.append(value) }
        }
        if namespaceURI == iptc, elementName == "DigitalSourceType" {
            active = elementName; text = ""
            if let resource = attributes["rdf:resource"] { sources.append(resource) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if active != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if active == elementName { sources.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); active = nil }
    }
}

final class MediaScanner {
    var report: ScanReport
    var handle: FileHandle!
    var boxCount = 0
    private var sawMovie = false
    private var sawMedia = false
    private let c2paUUID = Data([0xd8,0xfe,0xc3,0xd6,0x1b,0x0e,0x48,0x3c,0x92,0x97,0x58,0x28,0x87,0x7e,0xc4,0x81])
    private let xmpUUID = Data([0xbe,0x7a,0xcf,0xcb,0x97,0xa9,0x42,0xe8,0x9c,0x71,0x99,0x94,0x91,0xe3,0xaf,0xac])
    private let containers: Set<String> = ["moov","udta","trak","mdia","minf","stbl","dinf","edts","mvex","moof","traf","mfra"]
    private let aiTypes: Set<String> = ["trainedAlgorithmicMedia", "compositeWithTrainedAlgorithmicMedia", "compositeSynthetic"]
    init(url: URL) { report = ScanReport(file: url.lastPathComponent) }
    func warning(_ message: String) { if !report.warnings.contains(message) { report.warnings.append(message) } }
    private func evidence(_ kind: String, _ value: String, _ location: String) {
        guard report.evidence.count < 200 else { return }
        if !report.evidence.contains(where: { $0.kind == kind && $0.value == value && $0.location == location }) {
            report.evidence.append(Evidence(kind: kind, value: String(value.prefix(500)), location: location))
        }
    }
    private func source(_ value: String, _ location: String) {
        let prefix = ["http://cv.iptc.org/newscodes/digitalsourcetype/", "https://cv.iptc.org/newscodes/digitalsourcetype/"]
        guard let base = prefix.first(where: { value.hasPrefix($0) }) else { return }
        let term = String(value.dropFirst(base.count))
        evidence(aiTypes.contains(term) ? "ai_source" : "other_source", value, location)
    }
    func read(_ position: UInt64, _ length: UInt64) throws -> Data {
        guard length <= 32 * 1024 * 1024, report.bytesRead + length <= 64 * 1024 * 1024 else { throw ScanError.invalid("Limite de leitura de metadados atingido; análise incompleta") }
        try handle.seek(toOffset: position)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        report.bytesRead += UInt64(data.count)
        guard data.count == Int(length) else { throw ScanError.invalid("Arquivo truncado ou indisponível") }
        return data
    }
    func number(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
        data[start..<start+count].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private func inspectObject(_ object: Any, _ location: String) {
        if let map = object as? [String: Any] {
            for key in map.keys.sorted() {
                let value = map[key]!
                if key == "digitalSourceType", let value = value as? String { source(value, location) }
                if key == "softwareAgent" {
                    if let value = value as? String { evidence("software", value, location) }
                    if let agent = value as? [String: Any], let name = agent["name"] as? String { evidence("software", name, location) }
                }
                if key == "claim_generator_info", let agents = value as? [[String: Any]] {
                    for agent in agents { if let name = agent["name"] as? String { evidence("software", name, location) } }
                }
                if key == "dc:title", let title = value as? String { evidence("ingredient", title, location) }
                inspectObject(value, location)
            }
        } else if let array = object as? [Any] { for value in array { inspectObject(value, location) } }
    }
    func jumbf(_ data: Data, _ path: String, _ depth: Int = 0) throws {
        guard depth < 24 else { throw ScanError.invalid("Credenciais profundas demais") }
        var offset = 0
        while offset < data.count {
            if depth == 0, data[offset...].allSatisfy({ $0 == 0 }) { return }
            guard data.count-offset >= 8 else { throw ScanError.invalid("JUMBF truncado") }
            boxCount += 1
            guard boxCount < 100_000 else { throw ScanError.invalid("Número excessivo de blocos") }
            let size = number(data, offset, 4)
            guard size >= 8, size <= UInt64(data.count-offset) else { throw ScanError.invalid("JUMBF inválido") }
            let type = String(decoding: data[offset+4..<offset+8], as: UTF8.self)
            let body = data.subdata(in: offset+8..<offset+Int(size))
            if type == "jumb" { try jumbf(body, path + "/jumb", depth + 1) }
            if type == "cbor" {
                var reader = CBORReader(bytes: Array(body))
                inspectObject(try reader.read(), path + "/cbor")
            }
            if type == "json" { inspectObject(try JSONSerialization.jsonObject(with: body), path + "/json") }
            offset += Int(size)
        }
    }
    func xmp(_ data: Data, _ location: String) {
        var packet = data
        // Some encoders terminate UTF-8 XMP packets with NUL padding.
        if !packet.starts(with: [0xff,0xfe]), !packet.starts(with: [0xfe,0xff]) {
            while packet.last == 0 { packet.removeLast() }
        }
        let delegate = XMPReader(), parser = XMLParser(data: packet)
        parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        if parser.parse() {
            for value in delegate.sources { source(value, location) }
            for value in delegate.tools { evidence("software", value, location) }
        } else { warning("Um bloco XMP não pôde ser interpretado.") }
    }
    private func boxes(_ start: UInt64, _ end: UInt64, _ path: String, _ depth: Int = 0) throws {
        guard depth < 24 else { throw ScanError.invalid("Estrutura profunda demais") }
        var pos = start
        while pos < end {
            guard end-pos >= 8 else { throw ScanError.invalid("Cabeçalho de bloco truncado") }
            boxCount += 1
            guard boxCount < 100_000 else { throw ScanError.invalid("Número excessivo de blocos") }
            let header = try read(pos, 8)
            var size = number(header, 0, 4), headerSize: UInt64 = 8
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1 { size = number(try read(pos+8, 8), 0, 8); headerSize = 16 }
            if size == 0 { size = end-pos }
            guard size >= headerSize, size <= end-pos else { throw ScanError.invalid("Tamanho inválido no bloco \(type)") }
            let bodyStart = pos+headerSize, bodySize = size-headerSize
            let location = path + "/" + type + "@" + String(pos)
            if type == "moov" { sawMovie = true }
            if type == "mdat" { sawMedia = true }
            if containers.contains(type) { try boxes(bodyStart, pos+size, location, depth+1) }
            else if type == "meta", bodySize >= 8 {
                let first = try read(bodyStart, 4)
                try boxes(bodyStart + (number(first,0,4) == 0 ? 4 : 0), pos+size, location, depth+1)
            } else if type == "uuid" {
                guard bodySize >= 16 else { throw ScanError.invalid("UUID truncado") }
                let uuid = try read(bodyStart, 16)
                if uuid == c2paUUID {
                    report.hasC2PA = true
                    let body = try read(bodyStart+16, bodySize-16)
                    guard body.count >= 5, body[0] == 0, let nul = body[4...].firstIndex(of: 0) else { throw ScanError.invalid("Cabeçalho C2PA não suportado") }
                    let purpose = String(decoding: body[4..<nul], as: UTF8.self)
                    if ["manifest", "original", "update"].contains(purpose) {
                        let first = nul + 1 + (purpose == "update" ? 0 : 8)
                        guard first + 8 <= body.count else { throw ScanError.invalid("Manifesto C2PA truncado") }
                        try jumbf(body.subdata(in: first..<body.count), location)
                    }
                    else { warning("Bloco C2PA auxiliar ou externo: \(purpose).") }
                } else if uuid == xmpUUID { xmp(try read(bodyStart+16, bodySize-16), location) }
                else { warning("Bloco UUID de outro padrão não interpretado.") }
            } else if type == "XMP_" { xmp(try read(bodyStart, bodySize), location) }
            // mdat and sample tables are skipped by offset, including multi-GB payloads.
            pos += size
        }
    }
    func scan(_ url: URL) -> ScanReport {
        let start = Date()
        defer { try? handle?.close() }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ScanError.invalid("Selecione um vídeo ou uma imagem") }
            let ext = url.pathExtension.lowercased()
            guard Self.extensions.contains(ext) else { throw ScanError.invalid("Formato não suportado. Use MOV, MP4, M4V, JPG, PNG, WebP, HEIC, HEIF, AVIF, TIFF, PSD ou PSB.") }
            report.fileSize = UInt64(values.fileSize ?? 0)
            handle = try FileHandle(forReadingFrom: url)
            let signature = try read(0,min(report.fileSize,12))
            var format = ext
            if signature.starts(with: [0xff,0xd8]) { format = "jpg" }
            else if signature.starts(with: [137,80,78,71,13,10,26,10]) { format = "png" }
            else if signature.starts(with: Data("8BPS".utf8)) { format = "psd" }
            else if signature.starts(with: [0x49,0x49,0x2a,0]) || signature.starts(with: [0x4d,0x4d,0,0x2a]) { format = "tiff" }
            else if signature.count == 12, signature.prefix(4) == Data("RIFF".utf8), signature.suffix(4) == Data("WEBP".utf8) { format = "webp" }
            report.detectedFormat = format
            switch format {
            case "jpg", "jpeg": try jpeg()
            case "png": try png()
            case "webp": try webp()
            case "tif", "tiff": try tiff()
            case "psd", "psb": try photoshop()
            case "heic", "heif", "avif":
                try validateHEIF(url)
                try boxes(0, report.fileSize, "")
            default:
                try boxes(0, report.fileSize, "")
                guard sawMovie && sawMedia else { throw ScanError.invalid("Estrutura de vídeo MOV/MP4 incompleta") }
            }
        } catch ScanError.invalid(let reason) { warning(reason) }
        catch { warning(error.localizedDescription) }
        if report.evidence.contains(where: { $0.kind == "ai_source" }) { report.status = "ai_declared" }
        else if !report.warnings.isEmpty { report.status = "inconclusive" }
        else if report.hasC2PA { report.status = "credentials_present" }
        else { report.status = "no_signals" }
        report.milliseconds = Date().timeIntervalSince(start)*1000
        return report
    }
}
