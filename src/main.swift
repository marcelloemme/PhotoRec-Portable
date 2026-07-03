import SwiftUI
import AppKit

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

    // Accesso completo al disco: nil = non verificato, true = ok, false = mancante.
    @Published var hasFullDiskAccess: Bool? = nil

    private var monitorTimer: Timer? = nil
    private var imageSize: Int64 = 0

    var photorecPath: String { Bundle.main.bundlePath + "/Contents/Resources/bin/photorec" }

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
                self?.hasFullDiskAccess = verdict
                if !verdict {
                    self?.statusText = L("status.noFDA.hint")
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

    // MARK: RECUPERO

    // Percorsi correnti del recupero (per monitor, annulla, riorganizzazione).
    private var workDir = ""       // cartella temporanea dove lavora photorec
    private var pidFile = ""       // file col PID di photorec (per l'annulla)
    @Published var isCancelling = false

    func start() {
        guard let diskID = selectedDiskID else { statusText = L("status.selectDisk"); return }
        guard let dest = destination else { statusText = L("status.chooseDest"); return }

        let rawDevice = diskID.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let diskDev = diskID.replacingOccurrences(of: "/dev/", with: "")
        let destPath = dest.path
        // Cartella temporanea nascosta DENTRO la destinazione: photorec lavora qui,
        // poi riorganizzo i file per estensione nella destinazione e la cancello.
        let work = dest.appendingPathComponent(".photorec_lavoro").path
        let recupPath = work + "/recup_dir"
        let logPath = work + "/log.txt"
        let pidF = work + "/photorec.pid"
        let batch = "partition_none,\(fileoptCommand()),search"
        let pr = photorecPath
        let uid = getuid()

        self.workDir = work
        self.pidFile = pidF

        // Un solo comando come root (una sola password):
        // prepara cartella → smonta la card → lancia photorec scrivendone il PID →
        // aspetta la fine → rimonta → riassegna i file all'utente.
        let shell = """
        rm -rf '\(work)' ; mkdir -p '\(work)' ; \
        /usr/sbin/diskutil unmountDisk '\(diskDev)' || true ; \
        '\(pr)' /d '\(recupPath)' /cmd '\(rawDevice)' \(batch) > '\(logPath)' 2>&1 & \
        PRPID=$! ; echo $PRPID > '\(pidF)' ; \
        wait $PRPID ; PRSTATUS=$? ; \
        /usr/sbin/diskutil mountDisk '\(diskDev)' || true ; \
        /usr/sbin/chown -R \(uid) '\(work)' 2>/dev/null || true ; \
        exit $PRSTATUS
        """

        isRunning = true
        isCancelling = false
        finished = false
        progress = 0
        filesFound = 0
        resultDir = dest
        statusText = L("status.auth")

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
                    return
                }
                // Annullato dall'utente al dialogo password.
                if case .cancelled = outcome, !cancelled {
                    self.isRunning = false; self.finished = true
                    self.statusText = L("status.cancelled")
                    return
                }

                // In tutti gli altri casi (successo, annullato durante, o errore generico)
                // riorganizzo i file già recuperati e faccio pulizia.
                self.statusText = L("status.sorting")
                DispatchQueue.global().async {
                    let moved = Self.organizeAndCleanup(workDir: work, destination: destPath)
                    DispatchQueue.main.async {
                        self.isRunning = false
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

    // MARK: Riorganizzazione per estensione (merge non distruttivo)

    // Sposta i file da workDir/recup_dir.N/ in destination/<estensione>/,
    // gestendo le collisioni con rinomina. Restituisce quanti file sono stati sistemati.
    nonisolated static func organizeAndCleanup(workDir: String, destination: String) -> Int {
        let fm = FileManager.default
        var moved = 0
        var idx = 1
        while true {
            let dir = "\(workDir)/recup_dir.\(idx)"
            guard fm.fileExists(atPath: dir) else { break }
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files {
                    if f == "report.xml" { continue }
                    let src = "\(dir)/\(f)"
                    var ext = (f as NSString).pathExtension.lowercased()
                    if ext.isEmpty { ext = "altri" }
                    let destDir = "\(destination)/\(ext)"
                    try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                    let target = uniqueDestination(dir: destDir, filename: f)
                    do {
                        try fm.moveItem(atPath: src, toPath: target)
                        moved += 1
                    } catch {
                        // fallback: copia se il move fallisce (es. cross-device)
                        if (try? fm.copyItem(atPath: src, toPath: target)) != nil { moved += 1 }
                    }
                }
            }
            idx += 1
        }
        // Rimuovo la cartella di lavoro (recup_dir.N, log, pid).
        try? fm.removeItem(atPath: workDir)
        return moved
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

    private func pollProgress(destBase: String) {
        let size = imageSize
        DispatchQueue.global().async { [weak self] in
            let (count, lastOffset) = Self.scanProgress(destBase: destBase)
            let pct = size > 0 ? min(0.99, Double(lastOffset) / Double(size)) : 0
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.filesFound = count
                if size > 0 { self.progress = pct }
                let pctStr = size > 0 ? " — \(Int(self.progress * 100))%" : ""
                self.statusText = String(format: L("status.recovering"), count, pctStr)
            }
        }
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
    @StateObject var state = AppState()

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

                if state.hasFullDiskAccess == false { fdaBanner }

                // Disco di input
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("section.source")).bold().font(ui)
                    HStack {
                        Picker("", selection: Binding(
                            get: { state.selectedDiskID ?? "" },
                            set: { state.selectedDiskID = $0; state.updateSameDiskWarning() })) {
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
                ProgressView(value: state.progress)
                    .opacity(state.isRunning || state.finished ? 1 : 0.3)
                if !state.statusText.isEmpty {
                    Text(state.statusText)
                        .font(ui)
                        .foregroundColor(state.finished ? .green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
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
        }
        .font(ui)
        .padding(16)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            state.refreshDisks()
            state.checkFullDiskAccess()
        }
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

@main
struct PhotoRecFacileApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
