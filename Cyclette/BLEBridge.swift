//
//  BLEBridge.swift — Cyclette
//  Ponte tra la pagina web (navigator.bluetooth ricreato in ble-polyfill.js) e CoreBluetooth.
//  Ogni messaggio dalla pagina ha un "id": la risposta torna con window.__bleNative.resolve/reject(id, …).
//  Le notifiche (cadenza, velocità, battiti) arrivano con window.__bleNative.value(…).
//

import Foundation
import CoreBluetooth
import WebKit
import UIKit

/// Un dispositivo trovato durante la ricerca (per la finestra di scelta)
struct FoundDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var matches: Bool          // corrisponde a quello che la pagina cerca (es. servizio FTMS o cardio)
}

@MainActor
final class BLEBridge: NSObject, ObservableObject {

    // MARK: finestra di scelta del dispositivo
    @Published var pickerVisible = false
    @Published var found: [FoundDevice] = []
    @Published var showAll = false
    @Published var bluetoothMessage: String?

    weak var webView: WKWebView?

    // MARK: stato Bluetooth
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connected: Set<UUID> = []

    // richiesta di scelta in corso
    private var requestId: Int?
    private var requestFilters: [[String: Any]] = []
    private var requestAcceptAll = false
    private var pendingScan = false

    // operazioni in attesa della risposta di CoreBluetooth
    private var connectWaiters: [UUID: [Int]] = [:]
    private var serviceWaiters: [String: [Int]] = [:]   // "dispositivo|servizio"
    private var charWaiters: [String: [Int]] = [:]      // "dispositivo|servizio|caratteristica"
    private var notifyWaiters: [String: [Int]] = [:]
    private var readWaiters: [String: [Int]] = [:]
    private var writeWaiters: [String: [Int]] = [:]

    // MARK: - UUID nella forma di Web Bluetooth (lunga, minuscola)
    static func canon(_ u: CBUUID) -> String {
        let s = u.uuidString.lowercased()
        if s.count == 4 { return "0000\(s)-0000-1000-8000-00805f9b34fb" }
        if s.count == 8 { return "\(s)-0000-1000-8000-00805f9b34fb" }
        return s
    }

    private static func props(_ c: CBCharacteristic) -> [String: Bool] {
        let p = c.properties
        return ["read": p.contains(.read), "write": p.contains(.write),
                "writeWithoutResponse": p.contains(.writeWithoutResponse),
                "notify": p.contains(.notify), "indicate": p.contains(.indicate)]
    }

    private func ensureCentral() {
        if central == nil {
            // la prima volta iOS chiede il permesso Bluetooth
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    // MARK: - Risposte verso la pagina
    private func js(_ fn: String, _ args: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__bleNative && window.__bleNative.\(fn).apply(null, \(json));", completionHandler: nil)
    }
    private func resolve(_ id: Int, _ value: Any = NSNull()) { js("resolve", [id, value]) }
    private func reject(_ id: Int, _ name: String, _ message: String) { js("reject", [id, name, message]) }

    // MARK: - Ricerca e scelta del dispositivo
    private func startRequest(id: Int, body: [String: Any]) {
        if let old = requestId { reject(old, "NotFoundError", "Ricerca annullata") }
        requestId = id
        requestFilters = (body["filters"] as? [[String: Any]]) ?? []
        requestAcceptAll = (body["acceptAll"] as? Bool) ?? false
        showAll = requestAcceptAll
        found = []
        bluetoothMessage = nil
        pickerVisible = true
        ensureCentral()
        if central.state == .poweredOn { beginScan() } else { pendingScan = true; updateStateMessage() }
    }

    private func beginScan() {
        pendingScan = false
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        // dispositivi già collegati al telefono (non si fanno vedere nella ricerca)
        var wanted: [String] = []
        for f in requestFilters { wanted += (f["services"] as? [String]) ?? [] }
        for s in Set(wanted) {
            for p in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: s)]) {
                peripherals[p.identifier] = p
                addFound(p.identifier, name: p.name, rssi: -55, matches: matches(name: p.name, services: [s]))
            }
        }
    }

    private func matches(name: String?, services: [String]) -> Bool {
        if requestAcceptAll { return true }
        for f in requestFilters {
            let s = (f["services"] as? [String]) ?? []
            let n = f["name"] as? String
            let pre = f["namePrefix"] as? String
            if s.isEmpty && n == nil && pre == nil { continue }
            if !s.allSatisfy({ services.contains($0) }) { continue }
            if let n = n, name != n { continue }
            if let pre = pre, !(name ?? "").hasPrefix(pre) { continue }
            return true
        }
        return false
    }

    private func addFound(_ id: UUID, name: String?, rssi: Int, matches m: Bool) {
        let r = rssi == 127 ? -100 : rssi                    // 127 = segnale non disponibile
        if let i = found.firstIndex(where: { $0.id == id }) {
            var d = found[i]
            var changed = false
            if let n = name, !n.isEmpty, n != d.name { d.name = n; changed = true }
            if m && !d.matches { d.matches = true; changed = true }
            if abs(r - d.rssi) >= 6 { d.rssi = r; changed = true }
            if changed { found[i] = d }
        } else {
            found.append(FoundDevice(id: id, name: name ?? "", rssi: r, matches: m))
        }
    }

    /// Tocco su un dispositivo della lista
    func choose(_ d: FoundDevice) {
        guard let rid = requestId else { return }
        requestId = nil
        central?.stopScan()
        pickerVisible = false
        resolve(rid, ["id": d.id.uuidString, "name": d.name])
    }

    /// Finestra chiusa senza scegliere (Annulla o trascinata giù)
    func pickerDismissed() {
        guard let rid = requestId else { return }
        requestId = nil
        central?.stopScan()
        reject(rid, "NotFoundError", "Nessun dispositivo selezionato")
    }

    func cancelPicker() {
        pickerVisible = false
        pickerDismissed()
    }

    private func updateStateMessage() {
        guard let c = central else { return }
        switch c.state {
        case .poweredOff: bluetoothMessage = "Il Bluetooth è spento: attivalo dal Centro di Controllo."
        case .unauthorized: bluetoothMessage = "Bluetooth non autorizzato: Impostazioni → Cyclette → attiva Bluetooth."
        case .unsupported: bluetoothMessage = "Questo iPhone non supporta il Bluetooth LE."
        default: bluetoothMessage = nil
        }
    }

    // MARK: - Connessione
    private func connect(id: Int, dev: String?) {
        ensureCentral()
        guard let s = dev, let uuid = UUID(uuidString: s) else { reject(id, "NotFoundError", "Dispositivo sconosciuto"); return }
        var per = peripherals[uuid]
        if per == nil, let p = central.retrievePeripherals(withIdentifiers: [uuid]).first { peripherals[uuid] = p; per = p }
        guard let p = per else { reject(id, "NotFoundError", "Dispositivo non trovato: tocca di nuovo per cercarlo"); return }
        p.delegate = self
        if p.state == .connected { connected.insert(uuid); resolve(id); return }
        guard central.state == .poweredOn else { reject(id, "NetworkError", "Bluetooth spento o non autorizzato"); return }
        connectWaiters[uuid, default: []].append(id)
        central.connect(p, options: nil)
        Task { @MainActor [weak self] in                     // se dopo 15 s non si è collegato, rinuncia
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self = self, let w = self.connectWaiters[uuid], w.contains(id) else { return }
            self.connectWaiters[uuid] = w.filter { $0 != id }
            self.central.cancelPeripheralConnection(p)
            self.reject(id, "NetworkError", "Tempo scaduto: il dispositivo non risponde")
        }
    }

    private func disconnect(dev: String?) {
        guard let s = dev, let u = UUID(uuidString: s), let p = peripherals[u] else { return }
        central?.cancelPeripheralConnection(p)
    }

    /// Nuova pagina (ricarica o aggiornamento): si riparte puliti
    func resetForNewPage() {
        requestId = nil
        pickerVisible = false
        central?.stopScan()
        for u in connected { if let p = peripherals[u] { central?.cancelPeripheralConnection(p) } }
        connected.removeAll()
        connectWaiters.removeAll(); serviceWaiters.removeAll(); charWaiters.removeAll()
        notifyWaiters.removeAll(); readWaiters.removeAll(); writeWaiters.removeAll()
    }

    /// Dopo una disconnessione, tutte le operazioni in sospeso su quel dispositivo falliscono
    private func failWaiters(of dev: UUID) {
        let prefix = dev.uuidString + "|"
        func fail(_ dict: inout [String: [Int]]) {
            for (k, ids) in dict where k.hasPrefix(prefix) {
                dict[k] = nil
                ids.forEach { reject($0, "NetworkError", "Dispositivo disconnesso") }
            }
        }
        fail(&serviceWaiters); fail(&charWaiters); fail(&notifyWaiters); fail(&readWaiters); fail(&writeWaiters)
    }

    // MARK: - Servizi e caratteristiche
    private func connectedPeripheral(_ body: [String: Any], _ id: Int) -> CBPeripheral? {
        guard let s = body["device"] as? String, let u = UUID(uuidString: s), let p = peripherals[u], p.state == .connected else {
            reject(id, "NetworkError", "Dispositivo non connesso")
            return nil
        }
        return p
    }
    private func service(_ p: CBPeripheral, _ svc: String) -> CBService? {
        p.services?.first { BLEBridge.canon($0.uuid) == svc }
    }
    private func characteristic(_ p: CBPeripheral, _ body: [String: Any]) -> CBCharacteristic? {
        guard let svc = body["service"] as? String, let chr = body["char"] as? String, let s = service(p, svc) else { return nil }
        return s.characteristics?.first { BLEBridge.canon($0.uuid) == chr }
    }
    private func key(_ p: CBPeripheral, _ c: CBCharacteristic) -> String {
        let svc = c.service.map { BLEBridge.canon($0.uuid) } ?? ""
        return "\(p.identifier.uuidString)|\(svc)|\(BLEBridge.canon(c.uuid))"
    }

    private func getService(id: Int, body: [String: Any]) {
        guard let p = connectedPeripheral(body, id), let svc = body["service"] as? String else { return }
        if service(p, svc) != nil { resolve(id); return }
        serviceWaiters["\(p.identifier.uuidString)|\(svc)", default: []].append(id)
        p.discoverServices(nil)                               // tutti i servizi, poi si cerca quello richiesto
    }

    private func getChar(id: Int, body: [String: Any]) {
        guard let p = connectedPeripheral(body, id),
              let svc = body["service"] as? String, let chr = body["char"] as? String else { return }
        guard let s = service(p, svc) else { reject(id, "NotFoundError", "Servizio non trovato"); return }
        if let c = s.characteristics?.first(where: { BLEBridge.canon($0.uuid) == chr }) { resolve(id, BLEBridge.props(c)); return }
        charWaiters["\(p.identifier.uuidString)|\(svc)|\(chr)", default: []].append(id)
        p.discoverCharacteristics(nil, for: s)
    }

    private func notify(id: Int, body: [String: Any]) {
        guard let p = connectedPeripheral(body, id) else { return }
        guard let c = characteristic(p, body) else { reject(id, "InvalidStateError", "Caratteristica non pronta"); return }
        let on = (body["on"] as? Bool) ?? true
        if c.isNotifying == on { resolve(id); return }
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            reject(id, "NotSupportedError", "Notifiche non supportate"); return
        }
        notifyWaiters[key(p, c), default: []].append(id)
        p.setNotifyValue(on, for: c)
    }

    private func read(id: Int, body: [String: Any]) {
        guard let p = connectedPeripheral(body, id) else { return }
        guard let c = characteristic(p, body) else { reject(id, "InvalidStateError", "Caratteristica non pronta"); return }
        readWaiters[key(p, c), default: []].append(id)
        p.readValue(for: c)
    }

    private func write(id: Int, body: [String: Any]) {
        guard let p = connectedPeripheral(body, id) else { return }
        guard let c = characteristic(p, body), let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else {
            reject(id, "InvalidStateError", "Scrittura non possibile"); return
        }
        let withResponse = (body["withResponse"] as? Bool) ?? true
        if withResponse && c.properties.contains(.write) {
            writeWaiters[key(p, c), default: []].append(id)
            p.writeValue(data, for: c, type: .withResponse)
        } else {
            p.writeValue(data, for: c, type: .withoutResponse)
            resolve(id)
        }
    }

    // MARK: - Condivisione del backup (se WebKit non ha navigator.share)
    private func share(_ body: Any) {
        guard let b = body as? [String: Any], let text = b["text"] as? String else { return }
        let name = (b["name"] as? String) ?? "cyclette-backup.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard var top = webView?.window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        vc.popoverPresentationController?.sourceView = webView
        top.present(vc, animated: true)
    }
}

// MARK: - Messaggi dalla pagina
extension BLEBridge: @preconcurrency WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "share" { share(message.body); return }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        switch cmd {
        case "request": startRequest(id: id, body: body)
        case "connect": connect(id: id, dev: body["device"] as? String)
        case "disconnect": disconnect(dev: body["device"] as? String)
        case "getService": getService(id: id, body: body)
        case "getChar": getChar(id: id, body: body)
        case "notify": notify(id: id, body: body)
        case "read": read(id: id, body: body)
        case "write": write(id: id, body: body)
        case "availability": resolve(id, central == nil || central.state != .unsupported)
        default: reject(id, "NotSupportedError", "Comando non supportato: \(cmd)")
        }
    }
}

// MARK: - CoreBluetooth: stato, ricerca, connessione
extension BLEBridge: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        updateStateMessage()
        if c.state == .poweredOn {
            if pendingScan && requestId != nil { beginScan() }
        } else {
            for u in connected { js("disconnected", [u.uuidString]) }
            connected.removeAll()
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        guard requestId != nil else { return }
        peripherals[p.identifier] = p
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        var services: [String] = []
        for k in [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey] {
            if let list = adv[k] as? [CBUUID] { services += list.map { BLEBridge.canon($0) } }
        }
        addFound(p.identifier, name: name, rssi: RSSI.intValue, matches: matches(name: name, services: services))
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connected.insert(p.identifier)
        for id in connectWaiters.removeValue(forKey: p.identifier) ?? [] { resolve(id) }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        for id in connectWaiters.removeValue(forKey: p.identifier) ?? [] {
            reject(id, "NetworkError", error?.localizedDescription ?? "Connessione non riuscita")
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let wasConnected = connected.remove(p.identifier) != nil
        for id in connectWaiters.removeValue(forKey: p.identifier) ?? [] {
            reject(id, "NetworkError", error?.localizedDescription ?? "Connessione interrotta")
        }
        failWaiters(of: p.identifier)
        if wasConnected { js("disconnected", [p.identifier.uuidString]) }   // evento "gattserverdisconnected"
    }
}

// MARK: - CoreBluetooth: servizi, caratteristiche, dati
extension BLEBridge: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let prefix = p.identifier.uuidString + "|"
        for (k, ids) in serviceWaiters where k.hasPrefix(prefix) {
            serviceWaiters[k] = nil
            let svc = String(k.dropFirst(prefix.count))
            if error == nil, service(p, svc) != nil { ids.forEach { resolve($0) } }
            else { ids.forEach { reject($0, "NotFoundError", "Servizio non trovato") } }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let prefix = "\(p.identifier.uuidString)|\(BLEBridge.canon(s.uuid))|"
        for (k, ids) in charWaiters where k.hasPrefix(prefix) {
            charWaiters[k] = nil
            let chr = String(k.dropFirst(prefix.count))
            if let c = s.characteristics?.first(where: { BLEBridge.canon($0.uuid) == chr }) {
                ids.forEach { resolve($0, BLEBridge.props(c)) }
            } else {
                ids.forEach { reject($0, "NotFoundError", "Caratteristica non trovata") }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let ids = notifyWaiters.removeValue(forKey: key(p, c)) ?? []
        if let e = error { ids.forEach { reject($0, "NetworkError", e.localizedDescription) } }
        else { ids.forEach { resolve($0) } }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let k = key(p, c)
        let b64 = (c.value ?? Data()).base64EncodedString()
        if let ids = readWaiters.removeValue(forKey: k) {
            if let e = error { ids.forEach { reject($0, "NetworkError", e.localizedDescription) } }
            else { ids.forEach { resolve($0, b64) } }
        }
        guard error == nil else { return }
        let svc = c.service.map { BLEBridge.canon($0.uuid) } ?? ""
        js("value", [p.identifier.uuidString, svc, BLEBridge.canon(c.uuid), b64])
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let ids = writeWaiters.removeValue(forKey: key(p, c)) ?? []
        if let e = error { ids.forEach { reject($0, "NetworkError", e.localizedDescription) } }
        else { ids.forEach { resolve($0) } }
    }
}
