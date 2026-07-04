import SwiftUI
import AppKit
import CryptoKit

// Helper di localizzazione: cerca la chiave in Localizable.strings (en/it a seconda del sistema).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// MARK: - Disco selezionabile

struct DiskItem: Identifiable, Hashable {
    let id: String          // device node, es: /dev/disk4
    let title: String       // etichetta leggibile (nome volume + dettagli)
    let isRemovable: Bool    // rimovibile/espellibile (esterno)
    let physicalWhole: String // disco fisico, es: "disk4" — per il confronto con la destinazione
}

// MARK: - Categorie di file

// Ogni categoria raggruppa nomi carver VALIDATI contro il binario photorec 7.2 incluso.
// "carvers" vuoto = categoria "Tutto" (everything,enable).
struct FileCategory: Identifiable {
    let id: String
    let label: String
    let icon: String          // SF Symbol
    let carvers: [String]     // nomi carver validi; vuoto = tutto
    var enabled: Bool
}

func defaultCategories() -> [FileCategory] {
    [
        FileCategory(id: "photo", label: L("cat.photo"), icon: "photo",
            carvers: ["jpg", "png", "gif", "bmp", "tif", "raf", "crw", "orf",
                      "rw2", "mrw", "x3f", "raw", "psd", "ico", "icns", "xcf"],
            enabled: true),
        FileCategory(id: "audio", label: L("cat.audio"), icon: "music.note",
            carvers: ["mp3", "flac", "ogg", "au", "ra", "mid", "amr", "caf"],
            enabled: false),
        FileCategory(id: "archive", label: L("cat.archive"), icon: "archivebox",
            carvers: ["zip", "rar", "gz", "7z", "tar", "bz2", "ace", "lzh"],
            enabled: false),
        FileCategory(id: "video", label: L("cat.video"), icon: "film",
            carvers: ["mov", "mkv", "mpg", "m2ts", "flv", "r3d", "mxf", "dv", "mlv"],
            enabled: false),
        FileCategory(id: "doc", label: L("cat.doc"), icon: "doc.text",
            carvers: ["pdf", "doc", "rtf", "txt", "wpd"],
            enabled: false),
        FileCategory(id: "all", label: L("cat.all"), icon: "square.grid.2x2",
            carvers: [],
            enabled: false),
    ]
}

// MARK: - Stato applicazione

@MainActor
final class AppState: ObservableObject {
    @Published var disks: [DiskItem] = []
    @Published var selectedDiskID: String? = nil
    @Published var destination: URL? = nil
    @Published var categories: [FileCategory] = defaultCategories()

    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var filesFound = 0
    @Published var finished = false
    @Published var resultDir: URL? = nil

    // Fase di post-elaborazione (dopo che photorec ha finito la scansione): recupero nomi
    // originali dal filesystem + ripristino date. In questa fase la barra è al massimo e la
    // scansione non avanza più, quindi il monitor mostra un messaggio dedicato invece della
    // percentuale ferma (per non far sospettare un blocco).
    @Published var postProcessing = false

    // Modalità avanzata + opzioni (visibili solo se advancedMode = true).
    @Published var advancedMode = false
    @Published var optFullScan = false          // scansione completa (wholespace) invece di solo cancellati
    @Published var optParanoid = false          // verifica ogni file
    @Published var optBruteForce = false        // brute force (file frammentati)
    @Published var optKeepCorrupted = false     // mantieni file corrotti
    @Published var optOriginalNames = false     // recupera nomi originali via TestDisk (raddoppia spazio)

    // Accesso completo al disco: nil = non verificato, true = ok, false = mancante.
    @Published var hasFullDiskAccess: Bool? = nil

    // Aggiornamenti
    @Published var updateAvailable = false
    @Published var updateVersion = ""          // es. "1.1"
    @Published var updateURL: URL? = nil        // ZIP della release
    @Published var updatePageURL: URL? = nil    // pagina release su GitHub
    @Published var isUpdating = false

    private var monitorTimer: Timer? = nil
    private var imageSize: Int64 = 0
    private var recoveryStart: Date? = nil     // istante d'inizio del recupero
    // Campioni (istante, offset letto) per stimare la velocità RECENTE (finestra mobile).
    private var speedSamples: [(t: Date, offset: Int64)] = []
    // true quando il recupero corrente ha attivo il recupero nomi (fase post-elaborazione).
    private var wantNamesActive = false

    // Repo GitHub per gli aggiornamenti.
    let updateRepo = "marcelloemme/PhotoRec-Portable"

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var photorecPath: String { Bundle.main.bundlePath + "/Contents/Resources/bin/photorec" }
    var testdiskPath: String { Bundle.main.bundlePath + "/Contents/Resources/bin/testdisk" }

    // Riporta l'interfaccia allo stato "pulito" dopo un recupero completato,
    // quando l'utente cambia una qualsiasi impostazione. Non tocca un recupero in corso.
    func resetResultStateIfNeeded() {
        guard finished, !isRunning else { return }
        finished = false
        progress = 0
        filesFound = 0
        resultDir = nil
        statusText = ""
    }

    // true se la cartella di destinazione sta sullo STESSO disco fisico della sorgente.
    @Published var destinationOnSameDisk = false

    // Ricalcola se destinazione e sorgente coincidono sul disco fisico.
    func updateSameDiskWarning() {
        guard let dest = destination,
              let disk = disks.first(where: { $0.id == selectedDiskID }) else {
            destinationOnSameDisk = false; return
        }
        let sourceWhole = disk.physicalWhole
        DispatchQueue.global().async { [weak self] in
            let destWhole = Self.physicalWholeDisk(forPath: dest.path)
            DispatchQueue.main.async {
                self?.destinationOnSameDisk = (destWhole != nil && destWhole == sourceWhole)
            }
        }
    }

    // MARK: Elenco dischi

    func refreshDisks() {
        statusText = L("status.detecting")
        DispatchQueue.global().async { [weak self] in
            let items = Self.listDisks()
            DispatchQueue.main.async {
                self?.disks = items
                if self?.selectedDiskID == nil { self?.selectedDiskID = items.first?.id }
                if items.isEmpty {
                    self?.statusText = L("status.noDisk")
                } else if self?.finished == false && self?.isRunning == false {
                    self?.statusText = ""
                }
                self?.updateSameDiskWarning()
            }
        }
    }

    nonisolated static func listDisks() -> [DiskItem] {
        // Prendo l'elenco completo con partizioni/volumi (per i nomi tipo "64_1").
        guard let listPlist = runCapture("/usr/sbin/diskutil", ["list", "-plist"]),
              let data = listPlist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let wholeDisks = root["WholeDisks"] as? [String] else { return [] }

        // Mappa deviceIdentifier(whole) -> [nomi volume]
        let allDP = (root["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
        var volumeNames: [String: [String]] = [:]
        for entry in allDP {
            guard let dev = entry["DeviceIdentifier"] as? String else { continue }
            var names: [String] = []
            if let parts = entry["Partitions"] as? [[String: Any]] {
                for p in parts { if let vn = p["VolumeName"] as? String, !vn.isEmpty { names.append(vn) } }
            }
            if let apfs = entry["APFSVolumes"] as? [[String: Any]] {
                for v in apfs { if let vn = v["VolumeName"] as? String, !vn.isEmpty { names.append(vn) } }
            }
            volumeNames[dev] = names
        }

        var result: [DiskItem] = []
        for dev in wholeDisks {
            let node = "/dev/\(dev)"
            guard let infoPlist = runCapture("/usr/sbin/diskutil", ["info", "-plist", dev]),
                  let idata = infoPlist.data(using: .utf8),
                  let info = try? PropertyListSerialization.propertyList(from: idata, options: [], format: nil) as? [String: Any]
            else { continue }

            let mediaName = (info["MediaName"] as? String) ?? dev
            let sizeBytes = (info["Size"] as? NSNumber)?.int64Value ?? 0
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let removableMedia = (info["RemovableMediaOrExternalDevice"] as? Bool) ?? false
            let internalDisk = (info["Internal"] as? Bool) ?? true
            let isExternal = ejectable || removableMedia || !internalDisk

            let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            let names = volumeNames[dev] ?? []
            // Nome principale: nome volume se presente, altrimenti il modello del media.
            let primaryName = names.first ?? mediaName
            // Costruisco: "64_1 — 64 GB (SD Reader)"  oppure con più volumi "Vol1, Vol2 — …"
            let volPart = names.count > 1 ? names.joined(separator: ", ") : primaryName
            let readerHint = names.isEmpty ? "" : " (\(shortMedia(mediaName)))"
            let title = "\(volPart) — \(sizeStr)\(readerHint)"

            result.append(DiskItem(id: node, title: title, isRemovable: isExternal, physicalWhole: dev))
        }
        // Rimovibili/esterni in cima; poi per device.
        return result.sorted { ($0.isRemovable ? 0 : 1, $0.id) < ($1.isRemovable ? 0 : 1, $1.id) }
    }

    // Accorcia "Built In SDXC Reader" -> "SD Reader", "APPLE SSD AP0512Z" -> "SSD interno".
    nonisolated static func shortMedia(_ m: String) -> String {
        let low = m.lowercased()
        if low.contains("sd") && low.contains("reader") { return "SD Reader" }
        if low.contains("ssd") { return L("media.ssd") }
        if low.contains("reader") { return "Card Reader" }
        return m
    }

    // Disco fisico che contiene un percorso (per capire se è lo STESSO della sorgente).
    nonisolated static func physicalWholeDisk(forPath path: String) -> String? {
        // statfs -> device di mount (es. /dev/disk3s5), senza processi esterni.
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let mnt = withUnsafeBytes(of: &st.f_mntfromname) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        guard mnt.hasPrefix("/dev/") else { return nil }
        let devID = String(mnt.dropFirst(5))   // disk3s5
        // Chiedo a diskutil il disco fisico (gestisce APFS -> Physical Store).
        guard let infoPlist = runCapture("/usr/sbin/diskutil", ["info", "-plist", devID]),
              let d = infoPlist.data(using: .utf8),
              let info = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
        else { return nil }
        // APFS: risalgo al Physical Store (es. disk0s2 -> disk0).
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first, let dev = first["APFSPhysicalStore"] as? String {
            return wholeOf(dev)
        }
        if let part = info["ParentWholeDisk"] as? String { return part }
        return wholeOf(devID)
    }

    nonisolated static func wholeOf(_ dev: String) -> String {
        // disk4s1 -> disk4 ; disk0s2 -> disk0
        if let r = dev.range(of: "s", options: .backwards),
           dev.distance(from: dev.startIndex, to: r.lowerBound) > 4 {
            return String(dev[..<r.lowerBound])
        }
        return dev
    }

    private func diskSizeBytes(_ diskDev: String) -> Int64 {
        guard let info = Self.runCapture("/usr/sbin/diskutil", ["info", "-plist", diskDev]),
              let d = info.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
              let size = (dict["Size"] as? NSNumber)?.int64Value else { return 0 }
        return size
    }

    // Spazio libero (byte) del volume che contiene un percorso.
    nonisolated static func freeSpaceBytes(atPath path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return 0 }
        return free.int64Value
    }

    // Spazio libero (byte) del filesystem della SD sorgente = totale − usato dai file attuali.
    // È il tetto massimo di dati recuperabili in modalità "solo cancellati": i file cancellati
    // vivono nello spazio non allocato, che è appunto il libero del filesystem.
    // Restituisce 0 se la SD non è montata / illeggibile (il chiamante userà un fallback).
    nonisolated static func sourceFreeSpaceBytes(diskDev: String) -> Int64 {
        // Trovo il mount point di una partizione montata del disco sorgente.
        guard let info = runCapture("/usr/sbin/diskutil", ["list", "-plist", diskDev]),
              let d = info.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
              let allDP = root["AllDisksAndPartitions"] as? [[String: Any]] else { return 0 }
        var partIDs: [String] = []
        for disk in allDP {
            if let parts = disk["Partitions"] as? [[String: Any]] {
                for p in parts { if let id = p["DeviceIdentifier"] as? String { partIDs.append(id) } }
            }
        }
        for pid in partIDs {
            guard let pinfo = runCapture("/usr/sbin/diskutil", ["info", "-plist", pid]),
                  let pd = pinfo.data(using: .utf8),
                  let dict = try? PropertyListSerialization.propertyList(from: pd, options: [], format: nil) as? [String: Any],
                  let mount = dict["MountPoint"] as? String, !mount.isEmpty else { continue }
            let free = freeSpaceBytes(atPath: mount)
            if free > 0 { return free }
        }
        return 0
    }

    // Keyword photorec per lo schema partizioni del disco (per lo scope "solo cancellati").
    // FDisk/MBR -> partition_i386 ; GPT -> partition_gpt ; APM -> partition_mac ; altro -> partition_none.
    nonisolated static func partitionKeyword(forDisk diskDev: String) -> String {
        guard let info = runCapture("/usr/sbin/diskutil", ["info", "-plist", diskDev]),
              let d = info.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
        else { return "partition_none" }
        let content = (dict["Content"] as? String)?.lowercased() ?? ""
        if content.contains("fdisk") { return "partition_i386" }
        if content.contains("guid")  { return "partition_gpt" }
        if content.contains("apple") { return "partition_mac" }
        return "partition_none"
    }

    // Per il recupero nomi: individua la partizione exFAT del disco e il suo settore
    // di avvio (per leggerne la struttura). Restituisce (devicePartizione, settoreAvvio)
    // oppure nil se non c'è una partizione exFAT su questo disco.
    // Esempio: ("/dev/rdisk4s1", 32768).
    nonisolated static func exfatPartition(forDisk diskDev: String) -> (device: String, startSector: UInt64)? {
        // Elenco delle partizioni del disco.
        guard let listPlist = runCapture("/usr/sbin/diskutil", ["list", "-plist", diskDev]),
              let ld = listPlist.data(using: .utf8),
              let lroot = try? PropertyListSerialization.propertyList(from: ld, options: [], format: nil) as? [String: Any],
              let allDP = lroot["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }

        var partIDs: [String] = []
        for disk in allDP {
            if let parts = disk["Partitions"] as? [[String: Any]] {
                for p in parts { if let id = p["DeviceIdentifier"] as? String { partIDs.append(id) } }
            }
        }
        // Fallback: se non elencava partizioni, provo il disco stesso e "<disco>s1".
        if partIDs.isEmpty { partIDs = [diskDev, "\(diskDev)s1"] }

        for pid in partIDs {
            guard let info = runCapture("/usr/sbin/diskutil", ["info", "-plist", pid]),
                  let d = info.data(using: .utf8),
                  let dict = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any]
            else { continue }
            let fsName = (dict["FilesystemName"] as? String)?.lowercased() ?? ""
            let content = (dict["Content"] as? String)?.lowercased() ?? ""
            let isExfat = fsName.contains("exfat") || content.contains("exfat")
            guard isExfat else { continue }
            // Leggo il device della PARTIZIONE (rdiskNsM): il boot sector exFAT è già a
            // offset 0 di quel device, quindi il settore d'avvio è 0 (nessun offset da sommare).
            let rdev = "/dev/r" + pid    // es. /dev/rdisk4s1 (raw)
            return (rdev, 0)
        }
        return nil
    }

    // MARK: Accesso completo al disco

    // L'app, per leggere il device grezzo, ha bisogno di "Accesso completo al disco".
    // Rilevo lo stato provando a leggere un device SENZA privilegi:
    //  - "Operation not permitted" => manca l'accesso (TCC blocca).
    //  - "Permission denied" o lettura ok => l'app ha l'accesso (manca solo root).
    func checkFullDiskAccess() {
        DispatchQueue.global().async { [weak self] in
            let devs = Self.listDisks().map { $0.id }
            let candidates = devs.isEmpty ? ["/dev/disk0"] : devs
            var verdict = true
            for d in candidates {
                let raw = d.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
                let err = Self.readProbeError(raw)
                if err.contains("Operation not permitted") { verdict = false; break }
                if err.isEmpty || err.contains("Permission denied") { verdict = true; break }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hasFullDiskAccess = verdict
                if !verdict {
                    self.statusText = L("status.noFDA.hint")
                } else if self.statusText == L("status.noFDA.hint")
                            || self.statusText == L("status.noFDA.short") {
                    // L'accesso è stato concesso: rimuovo l'avviso residuo.
                    self.statusText = ""
                }
            }
        }
    }

    nonisolated static func readProbeError(_ rawDevice: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/dd")
        p.arguments = ["if=\(rawDevice)", "of=/dev/null", "bs=512", "count=1"]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do {
            try p.run()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return "" }
            return String(data: data, encoding: .utf8) ?? "errore"
        } catch { return "errore" }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Aggiornamenti (GitHub Releases)

    // Controlla in background se esiste una release più recente.
    func checkForUpdate() {
        let repo = updateRepo
        let current = appVersion
        DispatchQueue.global().async { [weak self] in
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 8
            guard let (data, resp) = try? Self.syncData(req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // URL dello ZIP allegato alla release (primo asset .zip), o pagina release.
            var zipURL: URL? = nil
            if let assets = json["assets"] as? [[String: Any]] {
                for a in assets {
                    if let name = a["name"] as? String, name.hasSuffix(".zip"),
                       let u = a["browser_download_url"] as? String { zipURL = URL(string: u); break }
                }
            }
            let pageURL = (json["html_url"] as? String).flatMap { URL(string: $0) }

            if Self.isNewer(latest, than: current) {
                DispatchQueue.main.async {
                    self?.updateVersion = latest
                    self?.updateURL = zipURL
                    self?.updatePageURL = pageURL
                    self?.updateAvailable = true
                }
            }
        }
    }

    // Confronta due versioni "1.2.3" numericamente. true se a > b.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // Scarica lo ZIP della nuova versione, lo scompatta e avvia la sostituzione assistita.
    func performUpdate() {
        guard let zip = updateURL else {
            // Nessuno ZIP allegato: apro la pagina release.
            if let p = updatePageURL { NSWorkspace.shared.open(p) }
            return
        }
        isUpdating = true
        statusText = L("update.downloading")
        let bundlePath = Bundle.main.bundlePath
        DispatchQueue.global().async { [weak self] in
            let tmp = NSTemporaryDirectory() + "PhotoRecPortable_update"
            let fm = FileManager.default
            try? fm.removeItem(atPath: tmp)
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let zipPath = tmp + "/update.zip"

            // Scarico lo ZIP.
            guard let (data, resp) = try? Self.syncData(URLRequest(url: zip)),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  (try? data.write(to: URL(fileURLWithPath: zipPath))) != nil else {
                DispatchQueue.main.async { self?.isUpdating = false; self?.statusText = L("update.failed") }
                return
            }
            // Scompatto con ditto.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipPath, tmp]
            try? unzip.run(); unzip.waitUntilExit()

            // Cerco il .app scompattato.
            guard let newApp = Self.findApp(in: tmp) else {
                DispatchQueue.main.async { self?.isUpdating = false; self?.statusText = L("update.failed") }
                return
            }

            // Script che aspetta la chiusura, sostituisce il bundle e riavvia.
            let script = tmp + "/replace.sh"
            let sh = """
            #!/bin/bash
            sleep 1
            while /bin/ps -p \(getpid()) > /dev/null 2>&1; do sleep 0.5; done
            /usr/bin/ditto '\(newApp)' '\(bundlePath)'
            /usr/bin/xattr -dr com.apple.quarantine '\(bundlePath)' 2>/dev/null
            /usr/bin/open '\(bundlePath)'
            /bin/rm -rf '\(tmp)'
            """
            try? sh.write(toFile: script, atomically: true, encoding: .utf8)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", script]
            try? chmod.run(); chmod.waitUntilExit()

            DispatchQueue.main.async {
                self?.statusText = L("update.installing")
                // Lancio lo script in background e chiudo l'app.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script]
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    nonisolated static func findApp(in dir: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for i in items where i.hasSuffix(".app") { return "\(dir)/\(i)" }
        return nil
    }

    // Richiesta sincrona (siamo già su un thread di background).
    nonisolated static func syncData(_ req: URLRequest) throws -> (Data, URLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)? = nil
        var err: Error? = nil
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let d = d, let r = r { result = (d, r) }
            err = e
            sem.signal()
        }.resume()
        sem.wait()
        if let result = result { return result }
        throw err ?? URLError(.badServerResponse)
    }

    // Attiva/disattiva una categoria. "Tutto" è esclusivo: se lo attivo spengo le altre;
    // se attivo un'altra categoria, spengo "Tutto".
    func toggleCategory(_ id: String) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        let willEnable = !categories[idx].enabled
        if id == "all" {
            for i in categories.indices { categories[i].enabled = (i == idx) ? willEnable : false }
        } else {
            categories[idx].enabled = willEnable
            if willEnable, let allIdx = categories.firstIndex(where: { $0.id == "all" }) {
                categories[allIdx].enabled = false
            }
        }
        resetResultStateIfNeeded()
    }

    // MARK: Comando fileopt dalle categorie selezionate

    private func fileoptCommand() -> String {
        // "Tutto" attivo → everything,enable
        if categories.first(where: { $0.id == "all" })?.enabled == true {
            return "fileopt,everything,enable"
        }
        let carvers = categories.filter { $0.enabled }.flatMap { $0.carvers }
        let unique = Array(Set(carvers)).sorted()
        if unique.isEmpty { return "fileopt,everything,enable" }
        var cmd = "fileopt,everything,disable"
        for e in unique { cmd += ",\(e),enable" }
        return cmd
    }

    // Opzioni avanzate (options,...) da anteporre a fileopt. Valide solo in modalità avanzata.
    private func optionsCommand() -> String {
        guard advancedMode else { return "" }
        var opts: [String] = []
        opts.append(optParanoid ? (optBruteForce ? "paranoid_bf" : "paranoid") : "paranoid_no")
        if optKeepCorrupted { opts.append("keep_corrupted_file") }
        return opts.isEmpty ? "" : "options," + opts.joined(separator: ",") + ","
    }

    // MARK: RECUPERO

    // Percorsi correnti del recupero (per monitor, annulla, riorganizzazione).
    private var workDir = ""       // cartella temporanea dove lavora photorec
    private var pidFile = ""       // file col PID di photorec (per l'annulla)
    @Published var isCancelling = false

    func start() {
        guard let diskID = selectedDiskID else { statusText = L("status.selectDisk"); return }
        guard let dest = destination else { statusText = L("status.chooseDest"); return }

        let diskDevCheck = diskID.replacingOccurrences(of: "/dev/", with: "")
        // C1 — Controllo spazio: se la destinazione non ha abbastanza spazio, avviso e blocco.
        // Stima del massimo recuperabile:
        //  - scansione completa (wholespace): legge tutto il device → fino alla dimensione del device;
        //  - solo cancellati (freespace): i dati recuperabili stanno nello spazio NON allocato della
        //    SD, cioè il libero del filesystem (totale − usato). Uso quello quando disponibile,
        //    con fallback prudente a metà della dimensione device se la SD non è leggibile.
        let deviceSize = diskSizeBytes(diskDevCheck)
        let freeSpace = Self.freeSpaceBytes(atPath: dest.path)
        let needed: Int64
        if advancedMode && optFullScan {
            needed = deviceSize
        } else {
            let sourceFree = Self.sourceFreeSpaceBytes(diskDev: diskDevCheck)
            needed = sourceFree > 0 ? sourceFree : deviceSize / 2
        }
        // Nota: il recupero dei nomi originali NON richiede spazio extra — lo scanner exFAT
        // legge solo i nomi dal filesystem, senza copiare alcun file.
        if deviceSize > 0 && freeSpace > 0 && freeSpace < needed {
            let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let freeStr = ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
            statusText = String(format: L("status.lowSpace"), freeStr, neededStr)
            finished = false
            return
        }

        let rawDevice = diskID.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let diskDev = diskID.replacingOccurrences(of: "/dev/", with: "")
        let destPath = dest.path
        // Cartella temporanea nascosta DENTRO la destinazione: photorec lavora qui,
        // poi riorganizzo i file per estensione nella destinazione e la cancello.
        let work = dest.appendingPathComponent(".photorec_lavoro").path
        let recupPath = work + "/recup_dir"
        let logPath = work + "/log.txt"
        let pidF = work + "/photorec.pid"
        let plog = work + "/photorec.log"    // log leggibile di photorec (/log) per il tempo
        let pr = photorecPath
        let uid = getuid()

        // Scope: default = solo file cancellati (freespace) col tipo di partizione rilevato;
        // in modalità avanzata con "scansione completa" = wholespace su partition_none.
        let fullScan = advancedMode && optFullScan
        let partKeyword = Self.partitionKeyword(forDisk: diskDev)
        let opts = optionsCommand()
        let fo = fileoptCommand()

        // Comando batch principale.
        let mainBatch: String
        if fullScan {
            mainBatch = "partition_none,\(opts)options,wholespace,\(fo),search"
        } else {
            mainBatch = "\(partKeyword),\(opts)options,freespace,\(fo),search"
        }

        self.workDir = work
        self.pidFile = pidF

        // Funzione shell per contare i file recuperati (esclude report.xml).
        // Fallback: se lo scope "solo cancellati" trova 0 file, rilancio in scansione completa
        // nella stessa esecuzione (una sola password).
        let fallbackBlock = fullScan ? "" : """
         ; \
        FILES=$(/usr/bin/find '\(work)' -type f ! -name 'report.xml' ! -name 'photorec.log' ! -name 'log.txt' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') ; \
        if [ "$FILES" = "0" ]; then \
          '\(pr)' /log /d '\(recupPath)' /cmd '\(rawDevice)' partition_none,\(opts)options,wholespace,\(fo),search >> '\(logPath)' 2>&1 ; \
        fi
        """

        // Recupero nomi originali (opzione avanzata): dopo photorec, mentre il device è
        // ancora smontato, ri-eseguo l'app stessa in modalità "--exfat-scan". Legge la
        // struttura exFAT del device (senza copiare file) e scrive in namesTSV l'elenco dei
        // file cancellati con dimensione + firme di contenuto + percorso. L'incrocio per
        // contenuto con i file photorec avviene poi in Swift, lato GUI (vedi buildMatches).
        // Girando come figlio del comando root già autorizzato, lo scan ha sia root sia
        // l'accesso completo al disco dell'app: nessuna seconda password.
        let wantNames = advancedMode && optOriginalNames
        let namesTSV = work + "/.nomi.tsv"
        let appExe = Bundle.main.executablePath ?? ""
        var scanBlock = ""
        if wantNames, let ex = Self.exfatPartition(forDisk: diskDev) {
            // Nota: uso il device della PARTIZIONE exFAT e il suo settore d'avvio.
            scanBlock = """
             ; \
            '\(appExe)' --exfat-scan '\(ex.device)' \(ex.startSector) '\(namesTSV)' 2>/dev/null || true
            """
        }

        // Un solo comando come root (una sola password):
        // prepara cartella → smonta la card → lancia photorec (con /log) scrivendone il PID →
        // aspetta la fine → eventuale fallback completo → eventuale scan nomi (exFAT) →
        // rimonta → riassegna i file all'utente.
        let shell = """
        rm -rf '\(work)' ; mkdir -p '\(work)' ; cd '\(work)' ; \
        /usr/sbin/diskutil unmountDisk '\(diskDev)' || true ; \
        '\(pr)' /log /d '\(recupPath)' /cmd '\(rawDevice)' \(mainBatch) > '\(logPath)' 2>&1 & \
        PRPID=$! ; echo $PRPID > '\(pidF)' ; \
        wait $PRPID ; PRSTATUS=$?\(fallbackBlock)\(scanBlock) ; \
        /usr/sbin/diskutil mountDisk '\(diskDev)' || true ; \
        /usr/sbin/chown -R \(uid) '\(work)' 2>/dev/null || true ; \
        exit $PRSTATUS
        """
        _ = plog

        isRunning = true
        isCancelling = false
        finished = false
        progress = 0
        filesFound = 0
        resultDir = dest
        recoveryStart = Date()
        speedSamples = []
        statusText = L("status.auth")
        wantNamesActive = wantNames
        postProcessing = false
        stalledPolls = 0

        startMonitor(destBase: work, diskDev: diskDev)

        DispatchQueue.global().async { [weak self] in
            let outcome = Self.runAsAdmin(shell)
            let logHint = Self.readableLog(logPath)
            let cancelled = DispatchQueue.main.sync { self?.isCancelling ?? false }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stopMonitor()

                // Errore di permessi: gestione dedicata, niente riorganizzazione.
                if case .failed = outcome, logHint.contains("Operation not permitted") {
                    self.isRunning = false; self.finished = true; self.isCancelling = false
                    self.hasFullDiskAccess = false
                    self.statusText = L("status.noFDA.short")
                    try? FileManager.default.removeItem(atPath: work)   // pulizia cartella di lavoro
                    return
                }
                // Annullato dall'utente al dialogo password.
                if case .cancelled = outcome, !cancelled {
                    self.isRunning = false; self.finished = true
                    self.statusText = L("status.cancelled")
                    try? FileManager.default.removeItem(atPath: work)   // pulizia cartella di lavoro
                    return
                }

                // In tutti gli altri casi (successo, annullato durante, o errore generico)
                // faccio la post-elaborazione: [nomi] → ordinamento → ripristino date.
                let renameNames = wantNames
                self.postProcessing = true
                self.progress = 1
                self.statusText = renameNames ? L("status.matchingNames") : L("status.sorting")
                DispatchQueue.global().async {
                    // 1) Recupero nomi originali (solo se richiesto): incrocio per CONTENUTO i
                    //    file photorec con l'elenco letto dallo scanner exFAT (namesTSV).
                    var matches: [String: ExfatNames.Match] = [:]
                    if renameNames {
                        matches = ExfatNames.buildMatches(workDir: work, tsvPath: namesTSV)
                    }
                    // 2) Ordinamento per tipo (+ rinomina dove c'è il nome originale).
                    DispatchQueue.main.async { self.statusText = L("status.sorting") }
                    let moved = Self.organizeAndCleanup(workDir: work, destination: destPath, matches: matches)
                    // 3) Ripristino date originali dall'EXIF — SEMPRE, come ultimo passo.
                    //    Opera solo sui file già recuperati (non tocca la card).
                    DispatchQueue.main.async { self.statusText = L("status.restoringDates") }
                    _ = Self.restoreDatesInDestination(destPath)
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.postProcessing = false
                        self.finished = true
                        self.filesFound = moved
                        self.progress = 1
                        if cancelled {
                            self.statusText = String(format: L("status.stopped"), moved)
                        } else if case .failed(let msg) = outcome {
                            let detail = logHint.isEmpty ? msg : logHint
                            self.statusText = moved > 0
                                ? String(format: L("status.doneWarn"), moved, detail)
                                : String(format: L("status.failed"), detail)
                        } else {
                            self.statusText = String(format: L("status.done"), moved)
                        }
                        self.isCancelling = false
                    }
                }
            }
        }
    }

    // MARK: Annulla

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        statusText = L("status.stopping")
        let pidF = pidFile
        DispatchQueue.global().async {
            // Provo prima a leggere il PID e killare senza privilegi.
            var killedByUser = false
            if let pidStr = try? String(contentsOfFile: pidF, encoding: .utf8),
               let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if kill(pid, SIGTERM) == 0 { killedByUser = true }
            }
            // Se non riuscito (processo di root), fermo photorec come admin.
            if !killedByUser {
                _ = Self.runAsAdmin("pkill -f 'Resources/bin/photorec' || true")
            }
        }
        // La chiusura effettiva (riorganizzazione) avviene nel completion di start(),
        // quando il comando root termina perché photorec è stato fermato.
    }

    // MARK: Recupero nomi originali (incrocio per hash con TestDisk)

    // Calcola l'hash dei file recuperati da TestDisk (che hanno i nomi originali) e dei file
    // recuperati da photorec (nomi generici); dove i contenuti combaciano, rinomina il file
    // photorec col nome originale. Restituisce quanti file sono stati rinominati.
    nonisolated static func applyOriginalNames(workDir: String, testdiskDir: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: testdiskDir) else { return 0 }

        // 1) Mappa hash -> nome originale, dai file TestDisk (ricorsivo). Escludo file di sistema.
        var hashToName: [String: String] = [:]
        if let en = fm.enumerator(atPath: testdiskDir) {
            for case let rel as String in en {
                let full = "\(testdiskDir)/\(rel)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                // Escludo file di sistema: uso il PATH completo (relativo), non solo il basename,
                // perché i file dentro .fseventsd hanno come nome solo l'UUID.
                let low = rel.lowercased()
                let base = (rel as NSString).lastPathComponent
                if base == "testdisk.log" || base.hasPrefix("._")
                    || low.contains("fseventsd") || low.contains(".trashes")
                    || low.contains(".spotlight") || base == ".ds_store" { continue }
                guard let h = fileHash(full) else { continue }
                // se due file hanno lo stesso hash, tengo il primo nome (indifferente).
                if hashToName[h] == nil { hashToName[h] = base }
            }
        }
        guard !hashToName.isEmpty else { return 0 }

        // 2) Scorro i file photorec e rinomino quelli il cui hash combacia.
        var renamed = 0
        var idx = 1
        while true {
            let dir = "\(workDir)/recup_dir.\(idx)"
            guard fm.fileExists(atPath: dir) else { break }
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files {
                    if f == "report.xml" || f == "photorec.log" { continue }
                    let src = "\(dir)/\(f)"
                    guard let h = fileHash(src), let origName = hashToName[h] else { continue }
                    // rinomino mantenendo un nome non in conflitto nella stessa cartella.
                    let target = uniqueDestination(dir: dir, filename: origName)
                    if (try? fm.moveItem(atPath: src, toPath: target)) != nil { renamed += 1 }
                }
            }
            idx += 1
        }
        return renamed
    }

    // Hash del contenuto di un file (MD5, sufficiente per il match di uguaglianza).
    nonisolated static func fileHash(_ path: String) -> String? {
        guard let data = fm_read(path) else { return nil }
        var hasher = Insecure.MD5()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fm_read(_ path: String) -> Data? {
        // Leggo il file in modo efficiente (mappato in memoria quando possibile).
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    // MARK: Riorganizzazione per estensione (merge non distruttivo)

    // Sposta i file da workDir/recup_dir.N/ in destination/<estensione>/,
    // gestendo le collisioni con rinomina. Restituisce quanti file sono stati sistemati.
    // `matches`: per i file photorec di cui abbiamo ritrovato il nome originale (via exFAT),
    // mappa il percorso del file photorec al nome/percorso originale. Quando presente, il
    // file viene salvato col nome originale invece di quello generico (f0012345.jpg).
    nonisolated static func organizeAndCleanup(workDir: String, destination: String,
                                               matches: [String: ExfatNames.Match] = [:]) -> Int {
        let fm = FileManager.default
        var moved = 0
        var idx = 1
        while true {
            let dir = "\(workDir)/recup_dir.\(idx)"
            guard fm.fileExists(atPath: dir) else { break }
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files {
                    if f == "report.xml" || f == "photorec.log" { continue }
                    let src = "\(dir)/\(f)"
                    // Nome finale: se abbiamo ritrovato il nome originale, uso quello.
                    let match = matches[src]
                    let finalName = match?.originalName ?? f
                    var ext = (finalName as NSString).pathExtension.lowercased()
                    if ext.isEmpty { ext = "altri" }
                    // PhotoRec: i file corrotti iniziano con 'b'. Vanno in una sottocartella
                    // dedicata dentro il tipo. (Il marker 'b' è sul nome generico di photorec.)
                    let subdir: String
                    if match == nil && f.hasPrefix("b") {
                        subdir = "\(destination)/\(ext)/\(L("folder.corrupted"))"
                    } else {
                        subdir = "\(destination)/\(ext)"
                    }
                    try? fm.createDirectory(atPath: subdir, withIntermediateDirectories: true)
                    let target = uniqueDestination(dir: subdir, filename: finalName)
                    do {
                        try fm.moveItem(atPath: src, toPath: target)
                        moved += 1
                    } catch {
                        _ = try? fm.copyItem(atPath: src, toPath: target)
                        if fm.fileExists(atPath: target) { moved += 1 }
                    }
                }
            }
            idx += 1
        }
        // Rimuovo la cartella di lavoro (recup_dir.N, log, pid).
        try? fm.removeItem(atPath: workDir)
        return moved
    }

    // MARK: Ripristino date originali (EXIF)

    // Scorre le foto già sistemate in `destination` e imposta la loro data di CREAZIONE alla
    // data di scatto EXIF (DateTimeOriginal). Sempre attivo, in entrambe le modalità: opera
    // SOLO sui file già recuperati (non tocca la card). I file senza EXIF restano invariati.
    // Restituisce quante foto hanno ottenuto la data originale.
    nonisolated static func restoreDatesInDestination(_ destination: String) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: destination) else { return 0 }
        var restored = 0
        for case let rel as String in en {
            let ext = (rel as NSString).pathExtension.lowercased()
            guard isPhotoExt(ext) else { continue }
            let full = "\(destination)/\(rel)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let d = ExifDate.captureDate(path: full) {
                ExifDate.setCreationDate(d, path: full)
                restored += 1
            }
        }
        return restored
    }

    // Estensioni foto/RAW che possono contenere EXIF con la data di scatto.
    nonisolated static func isPhotoExt(_ ext: String) -> Bool {
        let photo: Set<String> = [
            "jpg", "jpeg", "tif", "tiff", "heic", "heif", "png", "dng",
            // RAW comuni
            "raf", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
            "orf", "rw2", "raw", "pef", "x3f", "3fr", "mrw", "mos", "erf", "kdc"
        ]
        return photo.contains(ext)
    }

    // Restituisce un percorso non esistente: se "foto.jpg" esiste, prova "foto-1.jpg", ecc.
    nonisolated static func uniqueDestination(dir: String, filename: String) -> String {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = "\(dir)/\(filename)"
        var n = 1
        while fm.fileExists(atPath: candidate) {
            let newName = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = "\(dir)/\(newName)"
            n += 1
        }
        return candidate
    }

    // Legge il log photorec e restituisce l'ultima riga di errore sensata (senza codici ncurses).
    nonisolated static func readableLog(_ path: String) -> String {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        // Rimuovo sequenze di escape ANSI/ncurses.
        var s = ""
        var skipping = false
        for ch in raw {
            if ch == "\u{1B}" { skipping = true; continue }
            if skipping {
                if ch.isLetter { skipping = false }
                continue
            }
            s.append(ch)
        }
        let lines = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("PhotoRec") && !$0.contains("cgsecurity") }
        if let err = lines.last(where: { $0.contains("Unable") || $0.contains("permitted") || $0.contains("error") }) {
            return err
        }
        return ""
    }

    enum AdminOutcome { case success; case cancelled; case failed(String) }

    nonisolated static func runAsAdmin(_ shellCommand: String) -> AdminOutcome {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
        do {
            try p.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return .success }
            let errText = String(data: errData, encoding: .utf8) ?? ""
            if errText.contains("-128") || errText.lowercased().contains("cancel") { return .cancelled }
            let trimmed = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(trimmed.isEmpty ? "Errore sconosciuto (codice \(p.terminationStatus))." : trimmed)
        } catch { return .failed(error.localizedDescription) }
    }

    // MARK: Monitor progresso (report.xml)

    func startMonitor(destBase: String, diskDev: String) {
        DispatchQueue.global().async { [weak self] in
            let sz = DispatchQueue.main.sync { self?.diskSizeBytes(diskDev) ?? 0 }
            DispatchQueue.main.async { self?.imageSize = sz }
        }
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollProgress(destBase: destBase) }
        }
    }

    func stopMonitor() { monitorTimer?.invalidate(); monitorTimer = nil }

    // Numero di cicli consecutivi in cui la scansione non avanza (barra ferma al massimo).
    private var stalledPolls = 0

    private func pollProgress(destBase: String) {
        let size = imageSize
        DispatchQueue.global().async { [weak self] in
            let (count, lastOffset) = Self.scanProgress(destBase: destBase)
            let pct = size > 0 ? min(0.99, Double(lastOffset) / Double(size)) : 0
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }

                // Se siamo già in post-elaborazione, non tocco più barra/testo qui:
                // il messaggio dedicato lo gestisce chi avvia la fase.
                if self.postProcessing { return }

                // Rilevo il passaggio alla fase di post-elaborazione: la scansione è al
                // massimo e non produce nuovi offset da alcuni cicli (photorec ha finito,
                // lo shell prosegue con lo scan nomi / rimonta). Solo se è attivo il
                // recupero nomi, che è ciò che richiede tempo dopo la barra.
                let atMax = size > 0 && lastOffset > 0 && pct >= 0.99
                if self.wantNamesActive && atMax && count == self.filesFound {
                    self.stalledPolls += 1
                    if self.stalledPolls >= 2 {
                        self.postProcessing = true
                        self.progress = 1
                        self.statusText = L("status.matchingNames")
                        return
                    }
                } else {
                    self.stalledPolls = 0
                }

                self.filesFound = count
                if size > 0 { self.progress = pct }
                let pctStr = size > 0 ? " — \(Int(self.progress * 100))%" : ""
                let etaStr = self.etaFromRecentSpeed(offset: lastOffset, size: size)
                self.statusText = String(format: L("status.recovering"), count, pctStr) + etaStr
            }
        }
    }

    // Stima "tempo rimanente" dalla velocità degli ultimi ~30 secondi (finestra mobile).
    // Reagisce ai rallentamenti: se photorec legge più lentamente, la stima si allunga.
    private func etaFromRecentSpeed(offset: Int64, size: Int64) -> String {
        guard size > 0, offset > 0 else { return "" }
        let now = Date()
        speedSamples.append((now, offset))
        // tengo solo gli ultimi 30 secondi di campioni
        speedSamples.removeAll { now.timeIntervalSince($0.t) > 30 }
        guard let oldest = speedSamples.first,
              now.timeIntervalSince(oldest.t) >= 5 else { return "" }  // servono ≥5s di storia
        let dt = now.timeIntervalSince(oldest.t)
        let dOffset = Double(offset - oldest.offset)
        guard dt > 0, dOffset > 0 else { return "" }   // se fermo, nessuna stima
        let bytesPerSec = dOffset / dt
        let remainingBytes = Double(size - offset)
        let remaining = remainingBytes / bytesPerSec
        return " · " + String(format: L("status.remaining"), Self.hmsShort(remaining))
    }

    // Stima leggibile: "meno di 1 min", "5 min", "1 h 20 min".
    nonisolated static func hmsShort(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return L("time.under1min") }
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(format: L("time.hm"), h, m) }
        return String(format: L("time.m"), m)
    }

    nonisolated private static func scanProgress(destBase: String) -> (Int, Int64) {
        let fm = FileManager.default
        var count = 0
        var lastOffset: Int64 = 0
        var idx = 1
        while true {
            let dir = "\(destBase)/recup_dir.\(idx)"
            guard fm.fileExists(atPath: dir) else { break }
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files where f != "report.xml" { count += 1 }
                let reportPath = "\(dir)/report.xml"
                if let xml = try? String(contentsOfFile: reportPath, encoding: .utf8) {
                    for line in xml.components(separatedBy: "\n") where line.contains("img_offset=") {
                        if let off = extractInt(line, key: "img_offset") { lastOffset = max(lastOffset, off) }
                    }
                }
            }
            idx += 1
        }
        return (count, lastOffset)
    }

    nonisolated private static func extractInt(_ s: String, key: String) -> Int64? {
        guard let r = s.range(of: "\(key)='") else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return Int64(rest[..<end])
    }

    nonisolated static func runCapture(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}

// MARK: - Interfaccia

struct ContentView: View {
    @ObservedObject var state: AppState

    // Font unico per tutta l'interfaccia.
    let ui = Font.system(size: 13)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                // Intestazione: "PhotoRec Portable" in grassetto fa da titolo, nella stessa frase.
                // Interfaccia grafica per PhotoRec, creato da Christophe Grenier (CGSecurity).
                Group {
                    Text("PhotoRec Portable").bold()
                    + Text(L("header.intro"))
                    + Text("PhotoRec").bold()
                    + Text(L("header.author"))
                    + Text("cgsecurity.org")
                        .foregroundColor(.accentColor).underline()
                    + Text(".")
                }
                .font(ui)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    if let url = URL(string: "https://www.cgsecurity.org/wiki/PhotoRec") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                // Avvisi (FDA/update): appaiono solo quando servono e occupano spazio solo allora.
                // Eventi rari (una tantum o a ogni aggiornamento), quindi far crescere la
                // finestra in quel caso è accettabile.
                if state.updateAvailable { updateBanner }
                if state.hasFullDiskAccess == false { fdaBanner }

                // Disco di input
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("section.source")).bold().font(ui)
                    HStack {
                        Picker("", selection: Binding(
                            get: { state.selectedDiskID ?? "" },
                            set: { state.selectedDiskID = $0; state.updateSameDiskWarning(); state.resetResultStateIfNeeded() })) {
                            ForEach(state.disks) { disk in
                                Text((disk.isRemovable ? "💾 " : "🖥️ ") + disk.title).tag(disk.id)
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Button(action: { state.refreshDisks() }) {
                            Text(L("btn.refresh")).frame(width: 80)
                        }.disabled(state.isRunning)
                    }
                }

                // Cartella di output — dropdown "finto" per coerenza visiva col disco.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("section.destination")).bold().font(ui)
                    HStack {
                        HStack(spacing: 6) {
                            Text("📁")
                            Text(state.destination?.path ?? L("dest.none"))
                                .foregroundColor(state.destination == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(ui)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

                        Button(action: { chooseDestination() }) {
                            Text(L("btn.choose")).frame(width: 80)
                        }.disabled(state.isRunning)
                    }
                    if state.destinationOnSameDisk {
                        Text(L("warn.sameDisk"))
                            .font(ui).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Cosa recuperare — 6 pulsanti toggle su tre colonne
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("section.what")).bold().font(ui)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                              spacing: 6) {
                        ForEach(state.categories) { cat in
                            CategoryButton(category: cat, font: ui) {
                                state.toggleCategory(cat.id)
                            }
                        }
                    }
                }

                Divider()
                // Area stato+progresso ad ALTEZZA FISSA: non fa mai cambiare la finestra.
                VStack(alignment: .leading, spacing: 2) {
                    if state.postProcessing {
                        // Fase di post-elaborazione (nomi + date): barra indeterminata animata,
                        // così è chiaro che l'app sta lavorando e non è bloccata.
                        ProgressView().progressViewStyle(.linear)
                    } else if state.isRunning || state.finished {
                        ProgressView(value: state.progress)
                    }
                    if !state.statusText.isEmpty {
                        Text(state.statusText)
                            .font(ui)
                            .foregroundColor(state.finished ? .green : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 40, alignment: .top)

                // Opzioni avanzate — tra l'area stato e il tasto, senza divider.
                if state.advancedMode {
                    VStack(alignment: .leading, spacing: 4) {
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                            GridItem(.flexible(), alignment: .leading)],
                                  alignment: .leading, spacing: 2) {
                            Toggle(L("adv.fullScan"), isOn: $state.optFullScan).font(ui)
                            Toggle(L("adv.paranoid"), isOn: $state.optParanoid).font(ui)
                            Toggle(L("adv.bruteForce"), isOn: $state.optBruteForce).font(ui)
                            Toggle(L("adv.keepCorrupted"), isOn: $state.optKeepCorrupted).font(ui)
                        }
                        Toggle(L("adv.originalNames"), isOn: $state.optOriginalNames).font(ui)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }

                HStack {
                    Button(action: { state.start() }) {
                        Text(state.isRunning ? L("btn.recovering") : L("btn.start"))
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isRunning || state.selectedDiskID == nil || state.destination == nil
                              || state.hasFullDiskAccess == false
                              || state.destinationOnSameDisk
                              || !state.categories.contains { $0.enabled })

                    if state.isRunning {
                        Button(action: { confirmCancel() }) {
                            Text(state.isCancelling ? L("btn.stopping") : L("btn.cancel")).frame(width: 80)
                        }
                        .disabled(state.isCancelling)
                    }

                    if state.finished, let dir = state.resultDir {
                        Button(L("btn.openFolder")) { NSWorkspace.shared.open(dir) }
                    }
                }

                // Riga finale: versione + link alla repo, piccola e centrata.
                (Text("v\(state.appVersion) · ")
                 + Text("GitHub").underline())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onTapGesture {
                        if let url = URL(string: "https://github.com/\(state.updateRepo)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
        }
        .font(ui)
        .padding(16)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            state.refreshDisks()
            state.checkFullDiskAccess()
            state.checkForUpdate()
        }
    }

    var updateBanner: some View {
        HStack {
            Image(systemName: "arrow.down.circle")
            Text(String(format: L("update.available"), state.updateVersion))
                .font(ui)
            Spacer(minLength: 0)
            Button(state.isUpdating ? L("update.updating") : L("update.button")) {
                state.performUpdate()
            }
            .disabled(state.isUpdating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5)))
    }

    var fdaBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("fda.title")).bold().font(ui)
            Text(L("fda.enable"))
                .font(ui).fixedSize(horizontal: false, vertical: true)
            Text(L("fda.steps"))
                .font(ui).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("btn.openPrivacy")) { state.openPrivacySettings() }
                Button(L("btn.recheck")) { state.checkFullDiskAccess() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5)))
    }

    func confirmCancel() {
        let alert = NSAlert()
        alert.messageText = L("dlg.stopTitle")
        alert.informativeText = L("dlg.stopBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("dlg.stop"))
        alert.addButton(withTitle: L("dlg.keep"))
        if alert.runModal() == .alertFirstButtonReturn {
            state.cancel()
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("panel.choose")
        panel.message = L("panel.chooseFolder")
        if panel.runModal() == .OK {
            state.destination = panel.url
            state.updateSameDiskWarning()
            state.resetResultStateIfNeeded()
        }
    }
}

// Pulsante-categoria in stile bottone di sistema (come "Aggiorna"/"Scegli…"),
// con una casella di spunta a sinistra che indica lo stato.
struct CategoryButton: View {
    let category: FileCategory
    let font: Font
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.enabled ? "checkmark.square.fill" : "square")
                    .foregroundColor(category.enabled ? .accentColor : .secondary)
                Text(category.label)
                Spacer(minLength: 0)
            }
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Scena SwiftUI dell'app

struct PhotoRecFacileScene: App {
    @StateObject var state = AppState()

    var body: some Scene {
        WindowGroup { ContentView(state: state) }
            .windowResizability(.contentSize)
            .commands {
                CommandMenu(L("menu.options")) {
                    Toggle(L("menu.advanced"), isOn: $state.advancedMode)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                }
            }
    }
}

// MARK: - Entry point
//
// Con -parse-as-library l'ingresso è il main() statico del tipo @main.
// Modalità nascosta "scanner": se l'app è invocata con --exfat-scan, non apre la GUI
// ma legge la struttura exFAT del device e scrive l'elenco nomi (per il recupero nomi
// originali). Serve perché la lettura del device grezzo richiede sia root sia l'accesso
// completo al disco dell'APP: eseguendo l'app stessa come figlio del comando root già
// autorizzato, entrambi i requisiti sono soddisfatti senza chiedere una seconda password.
// In tutti gli altri casi avvia normalmente l'interfaccia.
@main
struct PhotoRecFacileMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 5 && args[1] == "--exfat-scan" {
            let device = args[2]
            let startSector = UInt64(args[3]) ?? 0
            let outPath = args[4]
            ExfatNames.runScan(devicePath: device, startSector: startSector, outPath: outPath)
            exit(0)
        }
        PhotoRecFacileScene.main()
    }
}
