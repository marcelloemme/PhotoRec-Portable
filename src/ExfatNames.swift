import Foundation
import CryptoKit

// MARK: - Recupero nomi originali (parser exFAT read-only + incrocio per contenuto)
//
// PhotoRec recupera i CONTENUTI dei file ma con nomi generici (f0012345.jpg).
// I nomi (e i percorsi) originali vivono ancora nelle directory entry del filesystem,
// anche per i file cancellati. Qui leggiamo la struttura exFAT direttamente dal device
// grezzo (senza copiare nulla), poi incrociamo per CONTENUTO ogni file recuperato da
// PhotoRec con l'entry cancellata corrispondente, per riassegnargli il nome giusto.
//
// Perché non TestDisk: il suo unico comando batch (list,filecopy) COPIA fisicamente
// tutti i file → raddoppia lo spazio. Leggendo noi il filesystem evitiamo ogni copia.
//
// ATTENZIONE (device grezzo): le letture su /dev/rdiskN devono essere allineate a
// SECTOR byte (offset E lunghezza), altrimenti EINVAL. Vedi rawRead(aligned:).

// Un file trovato nella struttura del filesystem, con i dati per l'incrocio per contenuto.
struct FSEntry {
    let name: String          // "DSCF4293.RAF"
    let path: String          // "/.Trashes/501/DSCF4293.RAF"
    let size: UInt64
    let firstCluster: UInt32
    let contiguous: Bool      // NoFatChain: cluster consecutivi
    let deleted: Bool
    let isDir: Bool
}

// Chiave d'incrocio = hash dell'HEADER (primi HEAD byte).
//
// NB: NON si può usare la dimensione come chiave. PhotoRec non conosce la dimensione reale
// del file: fa carving da un header al successivo, quindi la sua dimensione è quasi sempre
// MAGGIORE di quella registrata nella directory entry (differenze da +decine di KB a
// centinaia di MB). Verificato sul campo: 0% dei file recuperati aveva la dimensione esatta.
// L'HEADER invece coincide: sia PhotoRec sia la directory entry partono dallo STESSO primo
// cluster, quindi i primi byte sono identici. Verificato: 99.9% di match per header.
enum ExfatNames {
    static let SECTOR = 512
    static let HEAD = 32 * 1024   // header confrontato (più che sufficiente: bastano ~4KB)

    // MARK: Walker

    // Legge la struttura exFAT e restituisce i file cancellati (files, non directory)
    // con primo cluster e dimensione validi. Nil se la partizione non è exFAT.
    final class Walker {
        private let fh: FileHandle
        private let partStartByte: UInt64

        private var bytesPerSector: UInt64 = 0
        private var sectorsPerCluster: UInt64 = 0
        private var bytesPerCluster: UInt64 = 0
        private var clusterHeapOffsetSectors: UInt64 = 0
        private var fatOffsetSectors: UInt64 = 0
        private var fatLengthSectors: UInt64 = 0
        private var rootDirCluster: UInt32 = 0
        private var fat = Data()

        private(set) var entries: [FSEntry] = []

        init?(devicePath: String, partitionStartSector: UInt64) {
            guard let h = FileHandle(forReadingAtPath: devicePath) else { return nil }
            fh = h
            partStartByte = partitionStartSector * UInt64(SECTOR)
        }
        deinit { try? fh.close() }

        // Lettura DENTRO la partizione, allineata al settore (richiesto dal device grezzo).
        private func readAligned(at byteOffset: UInt64, _ length: Int) -> Data {
            let abs = partStartByte + byteOffset
            let s = UInt64(SECTOR)
            let start = (abs / s) * s
            let end = ((abs + UInt64(length) + s - 1) / s) * s
            do {
                try fh.seek(toOffset: start)
                let buf = fh.readData(ofLength: Int(end - start))
                let lo = Int(abs - start)
                guard lo <= buf.count else { return Data() }
                return buf.subdata(in: lo..<min(lo + length, buf.count))
            } catch { return Data() }
        }

        private func clusterByte(_ c: UInt32) -> UInt64 {
            (clusterHeapOffsetSectors + (UInt64(c) - 2) * sectorsPerCluster) * bytesPerSector
        }
        private func readCluster(_ c: UInt32) -> Data { readAligned(at: clusterByte(c), Int(bytesPerCluster)) }
        private func fatNext(_ c: UInt32) -> UInt32 {
            let off = Int(c) * 4
            guard off + 4 <= fat.count else { return 0xFFFFFFFF }
            return fat.leU32(off)
        }
        private func readChain(first: UInt32, contiguous: Bool, size: UInt64?) -> Data {
            var out = Data()
            if contiguous, let size = size, size > 0 {
                let n = Int((size + bytesPerCluster - 1) / bytesPerCluster)
                for i in 0..<n { out.append(readCluster(first &+ UInt32(i))) }
                return out
            }
            var c = first, guardCount = 0
            while c >= 2 && c < 0xFFFFFFF7 && guardCount < 1_000_000 {
                out.append(readCluster(c))
                let nx = fatNext(c)
                if nx == c || nx < 2 { break }
                c = nx; guardCount += 1
                if let size = size, UInt64(out.count) >= size { break }
            }
            return out
        }

        func walk() -> Bool {
            let boot = readAligned(at: 0, 512)
            guard boot.count >= 512, boot.subdata(in: 3..<11) == Data("EXFAT   ".utf8) else { return false }
            fatOffsetSectors         = UInt64(boot.leU32(80))
            fatLengthSectors         = UInt64(boot.leU32(84))
            clusterHeapOffsetSectors = UInt64(boot.leU32(88))
            rootDirCluster           = boot.leU32(96)
            bytesPerSector    = UInt64(1) << UInt64(boot[boot.startIndex + 108])
            sectorsPerCluster = UInt64(1) << UInt64(boot[boot.startIndex + 109])
            bytesPerCluster   = bytesPerSector * sectorsPerCluster
            guard bytesPerCluster > 0 else { return false }
            fat = readAligned(at: fatOffsetSectors * bytesPerSector, Int(fatLengthSectors * bytesPerSector))
            parseDir(readChain(first: rootDirCluster, contiguous: false, size: nil), path: "", depth: 0)
            return true
        }

        private func parseDir(_ d: Data, path: String, depth: Int) {
            let base = d.startIndex
            let n = d.count
            var i = 0
            while i + 32 <= n {
                let etype = d[base + i]
                if etype == 0x00 { break }
                if etype == 0x85 || etype == 0x05 {
                    let deleted = (etype == 0x05)
                    let secondaryCount = Int(d[base + i + 1])
                    guard i + 64 <= n else { break }
                    let se = base + i + 32
                    let seType = d[se]
                    if seType == 0xC0 || seType == 0x40 {
                        let genFlags = d[se + 1]
                        let noFatChain = (genFlags & 0x02) != 0
                        let nameLength = Int(d[se + 3])
                        let firstClu = d.leU32(i + 32 + 20)
                        let dataLength = d.leU64(i + 32 + 24)
                        let attrs = d.leU16(i + 4)
                        let isDir = (attrs & 0x10) != 0
                        var nameBytes = Data()
                        if secondaryCount >= 1 {
                            for k in 0..<(secondaryCount - 1) {
                                let off = i + 64 + k * 32
                                guard off + 32 <= n else { break }
                                let ne = base + off
                                if d[ne] != 0xC1 && d[ne] != 0x41 { break }
                                nameBytes.append(d.subdata(in: (ne + 2)..<(ne + 32)))
                            }
                        }
                        var name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
                        if name.count > nameLength { name = String(name.prefix(nameLength)) }
                        let full = path + "/" + name
                        entries.append(FSEntry(name: name, path: full, size: dataLength,
                                               firstCluster: firstClu, contiguous: noFatChain,
                                               deleted: deleted, isDir: isDir))
                        if isDir && !deleted && depth < 16 && firstClu >= 2 {
                            let sub = readChain(first: firstClu, contiguous: noFatChain,
                                                size: dataLength > 0 ? dataLength : bytesPerCluster * 8)
                            parseDir(sub, path: full, depth: depth + 1)
                        }
                    }
                    i += 32 * (secondaryCount + 1)
                    continue
                }
                i += 32
            }
        }

        // Legge `length` byte a partire da `offset` DENTRO il file dato (gestisce contigui e concatenati).
        func readFileRange(first: UInt32, contiguous: Bool, size: UInt64, offset: UInt64, length: Int) -> Data {
            guard size > 0, offset < size else { return Data() }
            let len = Int(min(UInt64(length), size - offset))
            if len <= 0 { return Data() }
            if contiguous {
                return readAligned(at: clusterByte(first) + offset, len)
            }
            // concatenato: cammino i cluster fino a offset
            var out = Data()
            var pos: UInt64 = 0
            var c = first, guardCount = 0
            while c >= 2 && c < 0xFFFFFFF7 && guardCount < 1_000_000 && out.count < len {
                let cl = readCluster(c)
                let clStart = pos, clEnd = pos + UInt64(cl.count)
                if clEnd > offset {
                    let a = Int(max(0, Int64(offset) - Int64(clStart)))
                    let b = Int(min(UInt64(cl.count), offset + UInt64(len) - clStart))
                    if a < b { out.append(cl.subdata(in: (cl.startIndex + a)..<(cl.startIndex + b))) }
                }
                pos = clEnd
                let nx = fatNext(c)
                if nx == c || nx < 2 { break }
                c = nx; guardCount += 1
            }
            return out.prefix(len)
        }

        // Hash dell'header (primi HEAD byte) di un file del filesystem, letto dal device grezzo.
        // È la chiave d'incrocio: coincide con l'header del file recuperato da PhotoRec.
        // Stringa vuota se il file è troppo corto o illeggibile (contenuto già sovrascritto).
        func headerHash(_ e: FSEntry) -> String {
            let head = readFileRange(first: e.firstCluster, contiguous: e.contiguous, size: e.size, offset: 0, length: HEAD)
            guard head.count >= min(HEAD, Int(e.size)) && !head.isEmpty else { return "" }
            return sha(head)
        }
    }

    static func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Modalità scanner (eseguita come figlio diretto dell'app, da root, SD smontata)

    // Scrive un TSV con una riga per file cancellato:  headerHash \t size \t path
    // headerHash è la chiave d'incrocio. size è informativa (NON usata per il match).
    // Il path è già ripulito dal prefisso iniziale "/". Restituisce il numero di righe.
    @discardableResult
    static func runScan(devicePath: String, startSector: UInt64, outPath: String) -> Int {
        guard let w = Walker(devicePath: devicePath, partitionStartSector: startSector), w.walk() else {
            // Non exFAT (o illeggibile): scrivo file vuoto così il chiamante prosegue senza nomi.
            try? Data().write(to: URL(fileURLWithPath: outPath))
            return 0
        }
        var lines = ""
        var count = 0
        for e in w.entries where e.deleted && !e.isDir && e.firstCluster >= 2 && e.size > 0 {
            let h = w.headerHash(e)
            // salto i file il cui contenuto è irrecuperabile (header vuoto/illeggibile)
            guard !h.isEmpty else { continue }
            let cleanPath = e.path.hasPrefix("/") ? String(e.path.dropFirst()) : e.path
            lines += "\(h)\t\(e.size)\t\(cleanPath)\n"
            count += 1
        }
        try? lines.write(toFile: outPath, atomically: true, encoding: .utf8)
        return count
    }

    // MARK: Matcher lato GUI (non richiede root: legge i file PhotoRec già accessibili)

    // Voce dell'indice nomi caricata dal TSV prodotto dallo scanner.
    private struct NameRec { let size: UInt64; let path: String }

    // Carica il TSV in un indice per HEADER-HASH (la chiave d'incrocio).
    // Se più file cancellati condividono lo stesso header (raro: file identici nei primi
    // 32KB), tengo il primo — sono comunque duplicati e un nome vale l'altro.
    private static func loadIndex(_ tsvPath: String) -> [String: NameRec] {
        guard let text = try? String(contentsOfFile: tsvPath, encoding: .utf8) else { return [:] }
        var index: [String: NameRec] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            let head = String(f[0])
            let size = UInt64(f[1]) ?? 0
            let path = String(f[2])
            if index[head] == nil { index[head] = NameRec(size: size, path: path) }
        }
        return index
    }

    // Hash dell'header (primi HEAD byte) di un file PhotoRec (lettura normale dal filesystem).
    private static func headerHashOfFile(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: HEAD)
        guard !head.isEmpty else { return nil }
        return sha(head)
    }

    // Risultato del match per un file PhotoRec: nome originale e percorso (dalla root FS).
    struct Match { let originalName: String; let originalPath: String }

    // Scorre i file PhotoRec in workDir/recup_dir.N e, per ognuno il cui HEADER combacia col
    // TSV, ne calcola nome+percorso originale. NON rinomina qui: restituisce la mappa
    //   percorso-file-photorec -> Match
    // così la riorganizzazione (organizeAndCleanup) può decidere destinazione e nome.
    static func buildMatches(workDir: String, tsvPath: String) -> [String: Match] {
        let index = loadIndex(tsvPath)
        guard !index.isEmpty else { return [:] }
        let fm = FileManager.default
        var result: [String: Match] = [:]
        var idx = 1
        while true {
            let dir = "\(workDir)/recup_dir.\(idx)"
            guard fm.fileExists(atPath: dir) else { break }
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files where f != "report.xml" && f != "photorec.log" {
                    let src = "\(dir)/\(f)"
                    guard let h = headerHashOfFile(src), let rec = index[h] else { continue }
                    let name = (rec.path as NSString).lastPathComponent
                    result[src] = Match(originalName: name, originalPath: rec.path)
                }
            }
            idx += 1
        }
        return result
    }
}

// MARK: - little-endian helper su Data (indipendenti dallo startIndex)

// MARK: - Data di scatto EXIF (per ripristinare la data di creazione delle foto)
//
// Dopo la rinomina, i file recuperati hanno come data quella del recupero (adesso).
// La data di scatto originale è però dentro il file, nell'EXIF (tag DateTimeOriginal
// 0x9003, in fallback DateTime 0x0132). La estraiamo parsando la struttura TIFF/EXIF
// (gestendo entrambi gli ordini di byte II/MM) e la impostiamo come data di CREAZIONE
// del file. Funziona per tutti i formati con EXIF: JPG, TIFF, RAF e altri RAW.
// Zero dipendenze esterne. Se l'EXIF non c'è, il file resta invariato.
enum ExifDate {
    static let READ = 256 * 1024   // basta l'header

    // Estrae la data di scatto ("YYYY:MM:DD HH:MM:SS") da un file, o nil se assente.
    static func captureDate(path: String) -> Date? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let buf = fh.readData(ofLength: READ)
        guard !buf.isEmpty else { return nil }
        if let (tiff, bigEndian) = findTiff(buf),
           let s = walkIFD(buf, tiff: tiff, bigEndian: bigEndian),
           let d = parse(s) {
            return d
        }
        // Fallback: cerca il pattern data nell'header.
        if let s = regexFallback(buf), let d = parse(s) { return d }
        return nil
    }

    // Imposta la data indicata come data di CREAZIONE e di MODIFICA del file.
    // La modifica serve perché il Finder mostra di default la data di modifica: così la
    // data di scatto è visibile subito, senza cambiare le colonne del Finder.
    static func setCreationDate(_ date: Date, path: String) {
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date], ofItemAtPath: path)
    }

    // Trova l'offset dell'header TIFF ("II*\0" little-endian o "MM\0*" big-endian).
    // In JPEG segue il marcatore "Exif\0\0"; nei RAW basati su TIFF è vicino all'inizio.
    private static func findTiff(_ buf: Data) -> (Int, Bool)? {
        let b = buf.startIndex
        let n = min(buf.count, READ)
        var cands: [Int] = []
        // preferisci il TIFF dentro un segmento Exif (JPEG)
        if let r = buf.range(of: Data("Exif\u{00}\u{00}".utf8)) {
            cands.append(buf.distance(from: b, to: r.lowerBound) + 6)
        }
        let II = Data([0x49, 0x49, 0x2A, 0x00])
        let MM = Data([0x4D, 0x4D, 0x00, 0x2A])
        var i = 0
        while i < n - 4 && cands.count < 6 {
            let slice = buf.subdata(in: (b+i)..<(b+i+4))
            if slice == II || slice == MM { cands.append(i) }
            i += 1
        }
        for off in cands {
            guard off >= 0, off + 4 <= buf.count else { continue }
            let sig = buf.subdata(in: (b+off)..<(b+off+4))
            if sig == II { return (off, false) }
            if sig == MM { return (off, true) }
        }
        return nil
    }

    // Percorre IFD0 e l'Exif sub-IFD cercando 0x9003 (DateTimeOriginal) o 0x0132 (DateTime).
    private static func walkIFD(_ buf: Data, tiff: Int, bigEndian: Bool) -> String? {
        func u16(_ o: Int) -> Int {
            let i = buf.startIndex + o
            guard i + 2 <= buf.endIndex else { return 0 }
            return bigEndian ? (Int(buf[i]) << 8 | Int(buf[i+1]))
                             : (Int(buf[i+1]) << 8 | Int(buf[i]))
        }
        func u32(_ o: Int) -> Int {
            let i = buf.startIndex + o
            guard i + 4 <= buf.endIndex else { return 0 }
            return bigEndian
                ? (Int(buf[i]) << 24 | Int(buf[i+1]) << 16 | Int(buf[i+2]) << 8 | Int(buf[i+3]))
                : (Int(buf[i+3]) << 24 | Int(buf[i+2]) << 16 | Int(buf[i+1]) << 8 | Int(buf[i]))
        }
        func ascii(at off: Int, count: Int) -> String? {
            let i = buf.startIndex + off
            guard off >= 0, i + count <= buf.endIndex else { return nil }
            var bytes = [UInt8](buf.subdata(in: i..<(i+count)))
            if let z = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<z]) }
            return String(bytes: bytes, encoding: .ascii)
        }

        guard tiff + 8 <= buf.count else { return nil }
        let ifd0 = tiff + u32(tiff + 4)
        var found9003: String? = nil
        var found0132: String? = nil
        var exifIFD: Int? = nil

        func scan(_ ifd: Int) {
            guard ifd >= 0, ifd + 2 <= buf.count else { return }
            let count = u16(ifd)
            for k in 0..<count {
                let e = ifd + 2 + k * 12
                guard e + 12 <= buf.count else { break }
                let tag = u16(e), typ = u16(e + 2), cnt = u32(e + 4)
                if (tag == 0x9003 || tag == 0x0132) && typ == 2 {
                    let s: String?
                    if cnt <= 4 {
                        s = ascii(at: e + 8, count: cnt)
                    } else {
                        s = ascii(at: tiff + u32(e + 8), count: cnt)
                    }
                    if tag == 0x9003 { found9003 = s } else { found0132 = s }
                } else if tag == 0x8769 {   // puntatore all'Exif IFD
                    exifIFD = tiff + u32(e + 8)
                }
            }
        }
        scan(ifd0)
        if let ex = exifIFD { scan(ex) }
        return found9003 ?? found0132
    }

    private static func regexFallback(_ buf: Data) -> String? {
        // Cerca "YYYY:MM:DD HH:MM:SS" (19 char ASCII) nell'header.
        let bytes = [UInt8](buf.prefix(READ))
        let n = bytes.count
        func isD(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        var i = 0
        while i + 19 <= n {
            // 20\d\d:[01]\d:[0-3]\d [0-2]\d:[0-5]\d:[0-5]\d
            if bytes[i] == 0x32 && bytes[i+1] == 0x30 && isD(bytes[i+2]) && isD(bytes[i+3])
                && bytes[i+4] == 0x3A && bytes[i+7] == 0x3A && bytes[i+10] == 0x20
                && bytes[i+13] == 0x3A && bytes[i+16] == 0x3A {
                if let s = String(bytes: bytes[i..<i+19], encoding: .ascii) { return s }
            }
            i += 1
        }
        return nil
    }

    // Converte "YYYY:MM:DD HH:MM:SS" in Date (fuso orario locale, come la fotocamera).
    private static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}

extension Data {
    func leU16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        guard i + 2 <= endIndex else { return 0 }
        return UInt16(self[i]) | (UInt16(self[i+1]) << 8)
    }
    func leU32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        guard i + 4 <= endIndex else { return 0 }
        return UInt32(self[i]) | (UInt32(self[i+1]) << 8) | (UInt32(self[i+2]) << 16) | (UInt32(self[i+3]) << 24)
    }
    func leU64(_ offset: Int) -> UInt64 {
        UInt64(leU32(offset)) | (UInt64(leU32(offset + 4)) << 32)
    }
}
