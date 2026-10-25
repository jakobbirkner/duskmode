// Dämmerung – läuft unsichtbar im Hintergrund: Wird es um den Mac herum dunkel, geht macOS
// in den Dark Mode, wird es wieder hell, zurück ins helle Erscheinungsbild.
//
// Kein Symbol in der Menüleiste (dort ist der Platz knapp, und verstellt wird selten).
// Einstellungen: Dämmerung noch einmal öffnen (Spotlight, Programme-Ordner) – dann kommt ein
// kleines Fenster, und solange es offen ist, steht die App auch im Dock. Fenster zu (⌘W) heißt
// nicht beenden – die App läuft weiter; nur ⌘Q / „Beenden“ hört auf. Im Fenster: Automatik an/aus,
// das Licht live (Horizont oder Skala, Klick schaltet um) mit Lichtfarbe, die Bildschirmhelligkeit
// als kleines MacBook, die Grenzen, „Gerade dunkel genug? Als Grenze nehmen“, Autostart und auf
// Wunsch doch ein Symbol in der Menüleiste (Sonne am Horizont – kein Mond, der sähe aus wie das
// Fokus-Symbol „Nicht stören“).
//
// Gemessen wird mit dem Umgebungslichtsensor neben der Kamera (derselbe, der die automatische
// Helligkeit und True Tone steuert). Er ist ein Farbsensor – ein Messpunkt, kein Bild – und liefert
// neben den Lux auch die Farbe des Lichts; daraus die Farbtemperatur (warm/neutral/kühl). Auf Wunsch
// zählt auch ein dunkel gestellter Bildschirm als dunkel (Grenze 5–30 %, Standard 10 %).
//
// Ohne Wartezeit: Sagt eine Messung „dunkel“ oder „hell“, wird umgeschaltet. Wie schnell, hängt nur
// davon ab, wie oft nachgesehen wird (siehe „Sparsam“). Beim Licht bleibt ein Abstand – dunkel unter
// der Schwelle, hell erst ab der dreifachen –, sonst schaltet das Rauschen des Sensors an der Grenze
// hin und her, und der Sensor sieht auch das Licht des Bildschirms selbst (im dunklen Zimmer bei
// voller Helligkeit ca. 3 lx). Die Bildschirmhelligkeit braucht keinen Abstand, sie schwankt nicht von
// selbst. Stellt man das Erscheinungsbild von Hand um, hält sich die App zurück, bis sich das Licht
// das nächste Mal wirklich ändert. Ist der Deckel zu (nur externer Bildschirm), misst sie nicht.
//
// Sparsam: Der Sensor läuft ohnehin (macOS liest ihn für Helligkeit und True Tone), ein Blick darauf
// kostet rund 40 µs. Bei offenem Fenster zehnmal pro Sekunde (Live-Grafik, sofortige Reaktion), sonst
// alle 20 s mit 10 s Spielraum zum Bündeln (rund 4.300 Blicke am Tag, zusammen ca. 0,2 s Rechenzeit);
// eine geänderte Bildschirmhelligkeit meldet macOS von selbst. Ist der Bildschirm aus, wird gar nicht
// gemessen. Nach dem Aufklappen erst nach 5 s – vorher ist der Sensor noch verdeckt gewesen und die
// Helligkeit blendet erst hoch (sonst wurde es kurz dunkel, 25.10.2026).
//
// macOS' eigenes „Erscheinungsbild: Automatisch“ (nach Uhrzeit) würde dazwischenfunken:
// Solange die Automatik hier an ist, ist es aus; beim Ausschalten oder Beenden wieder an.
//
// Interne Apple-Schnittstellen: Sensor (BezelServices, IOKit), Helligkeit (DisplayServices),
// Erscheinungsbild (SkyLight). Fehlt nach einem macOS-Update etwas, steht es im Fenster.
// Beim ersten Start trägt sich die App als Anmeldeobjekt ein (Autostart).
//
// Sprache: Deutsch, wenn der Mac auf Deutsch steht, sonst Englisch.

import AppKit
import ServiceManagement
import SwiftUI

let schwellen: [Double] = [2, 5, 10, 20, 50, 100]
let standardSchwelle = 10.0           // lx
let helligkeitsGrenzen: [Double] = [0, 0.05, 0.10, 0.20, 0.30]  // zur Auswahl; 0 = Bildschirm zählt nie
let themaMeldung = Notification.Name("AppleInterfaceThemeChangedNotification")

let deutsch = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
func t(_ de: String, _ en: String) -> String { deutsch ? de : en }

// MARK: - Interne Schnittstellen (über dlsym, damit ein Fehlen nicht zum Absturz führt)

func funktion<T>(_ rahmen: String, _ name: String, _: T.Type) -> T? {
    guard let h = dlopen(rahmen, RTLD_LAZY), let s = dlsym(h, name) else { return nil }
    return unsafeBitCast(s, to: T.self)
}

let privat = "/System/Library/PrivateFrameworks/"

/// Was der Sensor auf einmal liefert: Lux und die Farbe des Lichts (CIE XYZ, Y = Leuchtdichte)
struct Licht {
    let lux: Double
    let x: Double, y: Double, z: Double
}

enum Sensor {
    typealias Dienst = @convention(c) () -> OpaquePointer?
    typealias Ereignis = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias Feld = @convention(c) (CFTypeRef, Int32) -> Double
    static let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    static let ereignis = funktion(iokit, "IOHIDServiceClientCopyEvent", Ereignis.self)
    static let feld = funktion(iokit, "IOHIDEventGetFloatValue", Feld.self)
    static let dienst = funktion(privat + "BezelServices.framework/BezelServices",
                                 "ALCALSCopyALSServiceClient", Dienst.self)?()
    static let umgebungslicht: Int64 = 12  // kIOHIDEventTypeAmbientLightSensor

    /// Felder des Ereignisses: 0 Lux in ganzen Zahlen, 1–4 Rohkanäle, 7–9 X, Y, Z. Y ist derselbe Lux-Wert
    /// mit Nachkommastellen (14,9 statt 14) – für die Live-Anzeige zählt jede Kleinigkeit, darum Y.
    static func lesen() -> Licht? {
        guard let dienst, let ereignis, let feld,
              let e = ereignis(dienst, umgebungslicht, 0, 0)?.takeRetainedValue() else { return nil }
        func f(_ i: Int32) -> Double { feld(e, Int32(umgebungslicht << 16) | i) }
        let y = f(8)
        return Licht(lux: y > 0 ? y : f(0), x: f(7), y: y, z: f(9))
    }

    static func lux() -> Double? { lesen()?.lux }
}

enum Bildschirm {
    typealias Lesen = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Meldung = @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFString?,
                                        UnsafeRawPointer?, CFDictionary?) -> Void
    typealias Beobachten = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, Meldung) -> Int32
    static let rahmen = privat + "DisplayServices.framework/DisplayServices"
    static let lesen = funktion(rahmen, "DisplayServicesGetBrightness", Lesen.self)
    static let beobachten = funktion(rahmen, "DisplayServicesRegisterForBrightnessChangeNotifications",
                                     Beobachten.self)

    /// Der eingebaute Bildschirm, wenn er gerade an ist (zugeklappt: nil)
    static func eingebaut() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var anzahl: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &anzahl) == .success else { return nil }
        return ids.prefix(Int(anzahl)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Helligkeit 0…1
    static func helligkeit(_ id: CGDirectDisplayID) -> Double? {
        var wert: Float = 0
        guard let lesen, lesen(id, &wert) == 0 else { return nil }
        return Double(wert)
    }
}

enum Erscheinung {
    typealias Lesen = @convention(c) () -> Int32
    typealias Setzen = @convention(c) (Int32) -> Void
    typealias SchalterLesen = @convention(c) () -> Bool
    typealias SchalterSetzen = @convention(c) (Bool) -> Void
    static let rahmen = privat + "SkyLight.framework/SkyLight"
    static let lesen = funktion(rahmen, "SLSGetAppearanceThemeLegacy", Lesen.self)
    static let setzen = funktion(rahmen, "SLSSetAppearanceThemeLegacy", Setzen.self)
    static let uhrzeitLesen = funktion(rahmen, "SLSGetAppearanceThemeSwitchesAutomatically", SchalterLesen.self)
    static let uhrzeitSetzen = funktion(rahmen, "SLSSetAppearanceThemeSwitchesAutomatically", SchalterSetzen.self)

    static var dunkel: Bool {
        if let lesen { return lesen() == 1 }
        return UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"]
            as? String == "Dark"
    }

    /// Ohne SkyLight über „Systemereignisse“ – das fragt einmal nach der Erlaubnis.
    static func setze(dunkel: Bool) {
        if let setzen { return setzen(dunkel ? 1 : 0) }
        var fehler: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences"
                      + " to set dark mode to \(dunkel)")?.executeAndReturnError(&fehler)
    }

    /// macOS' eigenes „Automatisch“ (nach Uhrzeit)
    static var nachUhrzeit: Bool { uhrzeitLesen?() ?? false }
    static func nachUhrzeit(_ an: Bool) { uhrzeitSetzen?(an) }
}

struct Messung {
    let licht: Licht?
    let helligkeit: Double?
    var lux: Double? { licht?.lux }

    /// Farbtemperatur nach McCamy aus dem Farbort – eine Näherung, für warm/neutral/kühl genau genug.
    /// Im fast Dunkeln ist die Farbe nicht messbar (alle Kanäle 0), dann nil.
    var kelvin: Double? {
        guard let l = licht, l.y > 0.5 else { return nil }
        let summe: Double = l.x + l.y + l.z
        let fx: Double = l.x / summe
        let fy: Double = l.y / summe
        let n: Double = (fx - 0.3320) / (0.1858 - fy)
        let k: Double = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        return (1000...20000).contains(k) ? k : nil
    }

    /// Die Farbe des Lichts in sRGB, der hellste Kanal auf 1 gesetzt (nur der Farbton, nicht die Helligkeit)
    var farbton: (Double, Double, Double)? {
        guard let l = licht, l.y > 0.5 else { return nil }
        let r: Double = 3.2406 * l.x - 1.5372 * l.y - 0.4986 * l.z
        let g: Double = -0.9689 * l.x + 1.8758 * l.y + 0.0415 * l.z
        let b: Double = 0.0557 * l.x - 0.2040 * l.y + 1.0570 * l.z
        let hoechster = max(r, g, b)
        guard hoechster > 0 else { return nil }
        func gamma(_ v: Double) -> Double {
            let linear = max(0, v / hoechster)
            return linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        }
        return (gamma(r), gamma(g), gamma(b))
    }
}

/// Lux auf einer logarithmischen Skala von 0,1 bis 10.000 lx, als 0…1
func luxPosition(_ l: Double) -> Double { max(0, min(1, (log10(max(l, 0.1)) + 1) / 5)) }

/// Die Helligkeitsmeldung kommt als C-Funktion ohne Kontext, darum über die laufende App.
let helligkeitsMeldung: Bildschirm.Meldung = { _, _, _, _, _ in
    DispatchQueue.main.async { App.laufend?.helligkeitGeaendert() }
}

func uhrzeit(_ datum: Date) -> String {
    DateFormatter.localizedString(from: datum, dateStyle: .none, timeStyle: .short)
}

func lux(_ wert: Double) -> String {
    wert < 10 && wert != wert.rounded() ? String(format: "%.1f lx", wert) : "\(Int(wert.rounded())) lx"
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static weak var laufend: App?

    let ablage = UserDefaults.standard
    var eintrag: NSStatusItem?  // nur, wenn in den Einstellungen gewünscht
    var fenster: NSWindow?
    var mitlaufen: Timer?       // 10× pro Sekunde, solange das Fenster offen ist
    var takt: Timer?            // alle 20 s, solange der Bildschirm an ist
    var bald: Timer?            // kurz nach einer Helligkeitsänderung
    var aktivitaet: NSObjectProtocol?  // kein App Nap, solange der Bildschirm an ist
    var ruhigBis = Date.distantPast    // kurz nach dem Aufklappen nicht entscheiden
    var angehalten = false      // von Hand umgestellt
    var sollBeimAnhalten: Bool?
    var eigeneAenderung = Date.distantPast
    var zuletzt: (dunkel: Bool, zeit: Date)?
    var beobachtet: Set<CGDirectDisplayID> = []
    var gezeichnet = ""
    var alsAnmeldeobjekt = false
    var messung: Messung?       // fürs Fenster
    var weichLux: Double?       // geglättet, damit die Grafik fließt statt springt
    var weichHelligkeit: Double?
    var weichKelvin: Double?
    var weichFarbton: (Double, Double, Double)?
    var ansicht: Int {          // 0 Horizont, 1 Skala – Klick auf die Grafik schaltet um
        get { ablage.integer(forKey: "ansicht") % 2 }
        set {
            ablage.set(newValue, forKey: "ansicht")
            objectWillChange.send()
        }
    }

    var automatik: Bool {
        get { ablage.object(forKey: "automatik") as? Bool ?? true }
        set { ablage.set(newValue, forKey: "automatik") }
    }
    /// Unter so viel Lux gilt es als dunkel; hell erst ab `hellAb`.
    var schwelle: Double {
        get { ablage.object(forKey: "schwelle") as? Double ?? standardSchwelle }
        set { ablage.set(newValue, forKey: "schwelle") }
    }
    var hellAb: Double { max(schwelle * 3, schwelle + 5) }
    /// Darunter zählt auch der Bildschirm als dunkel (0 = nie). Bis 25.10.2026 nur an/aus bei 10 %.
    var helligkeitsGrenze: Double {
        get {
            if let wert = ablage.object(forKey: "helligkeitsGrenze") as? Double { return wert }
            return ablage.object(forKey: "auchHelligkeit") as? Bool == false ? 0 : 0.10
        }
        set { ablage.set(newValue, forKey: "helligkeitsGrenze") }
    }
    var symbolZeigen: Bool {
        get { ablage.bool(forKey: "symbolZeigen") }
        set {
            ablage.set(newValue, forKey: "symbolZeigen")
            symbolAnpassen()
        }
    }

    func applicationWillFinishLaunching(_ n: Notification) {
        // Beim Anmelden still starten, von Hand geöffnet gleich die Einstellungen zeigen
        let e = NSAppleEventManager.shared().currentAppleEvent
        alsAnmeldeobjekt = e?.eventID == AEEventID(kAEOpenApplication)
            && e?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        App.laufend = self
        NSApp.mainMenu = hauptmenue()
        ablage.removeObject(forKey: "wartezeit")  // gab es bis 25.10.2026

        let arbeitsplatz = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            arbeitsplatz.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.aufgewacht() }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            arbeitsplatz.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.ruhe() }
        }
        DistributedNotificationCenter.default().addObserver(forName: themaMeldung, object: nil, queue: .main) {
            [weak self] _ in self?.erscheinungGeaendert()
        }
        // Deckel auf/zu, Bildschirm an- oder abgesteckt – wie nach dem Aufwachen erst kurz warten
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.beobachteHelligkeit()
            self?.gleichNachsehen()
        }

        let ersterStart = !ablage.bool(forKey: "autostartErledigt")
        autostartEinmalig()
        beobachteHelligkeit()
        symbolAnpassen()
        if automatik {
            uhrzeitAutomatikAus()
            bewerte(frisch: true)
        }
        starteTakt()
        if ersterStart || !alsAnmeldeobjekt { zeigeEinstellungen() }
    }

    /// Dämmerung läuft schon und wird noch einmal geöffnet: Einstellungen zeigen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        zeigeEinstellungen()
        return false
    }

    func applicationWillTerminate(_ n: Notification) { uhrzeitAutomatikZurueck() }

    /// Nur beim allerersten Start: als Anmeldeobjekt eintragen. Wer es danach wieder
    /// ausschaltet, wird nicht überstimmt.
    func autostartEinmalig() {
        guard !ablage.bool(forKey: "autostartErledigt") else { return }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        ablage.set(true, forKey: "autostartErledigt")
    }

    // MARK: Wann nachsehen

    /// macOS meldet jede Änderung der Helligkeit (von Hand oder automatisch) – kein Abfragen nötig.
    func beobachteHelligkeit() {
        guard let beobachten = Bildschirm.beobachten, let id = Bildschirm.eingebaut(),
              !beobachtet.contains(id) else { return }
        if beobachten(id, nil, helligkeitsMeldung) == 0 { beobachtet.insert(id) }
    }

    /// Beim Ziehen am Regler kommen viele Meldungen – nachgesehen wird einmal, kurz danach.
    func helligkeitGeaendert() {
        guard automatik, bald == nil else { return }
        let einmal = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.bald = nil
            self?.bewerte()
        }
        einmal.tolerance = 0.2
        RunLoop.main.add(einmal, forMode: .common)
        bald = einmal
    }

    /// Ohne sichtbares Fenster bremst macOS die App sonst aus (App Nap): Der Takt kam dann
    /// erst nach mehreren Minuten (25.10.2026). Der Spielraum zum Bündeln bleibt.
    func starteTakt() {
        guard takt == nil else { return }
        let neu = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.bewerte() }
        neu.tolerance = 10
        RunLoop.main.add(neu, forMode: .common)
        takt = neu
        if aktivitaet == nil {
            aktivitaet = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Licht alle 20 s prüfen")
        }
    }

    /// Bildschirm aus, Ruhezustand oder anderer Benutzer: niemand schaut hin, also nicht messen.
    func ruhe() {
        takt?.invalidate()
        takt = nil
        if let a = aktivitaet {
            ProcessInfo.processInfo.endActivity(a)
            aktivitaet = nil
        }
        bald?.invalidate()
        bald = nil
    }

    func aufgewacht() {
        starteTakt()
        gleichNachsehen()
    }

    /// Nach dem Aufklappen sind die Werte kurz unzuverlässig: Der Sensor war verdeckt, die Helligkeit
    /// blendet erst von 0 hoch. Darum 5 s lang nicht entscheiden, dann frisch an der Mitte.
    func gleichNachsehen() {
        ruhigBis = Date().addingTimeInterval(5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in self?.bewerte(frisch: true) }
    }

    // MARK: Entscheiden

    func messen() -> Messung? {
        guard let id = Bildschirm.eingebaut() else { return nil }  // zugeklappt: Sensor verdeckt
        return Messung(licht: Sensor.lesen(), helligkeit: Bildschirm.helligkeit(id))
    }

    /// true = dunkel, false = hell, nil = dazwischen (bleibt, wie es ist)
    func soll(_ m: Messung) -> Bool? {
        let schwach = (m.helligkeit ?? 1) < helligkeitsGrenze
        guard let l = m.lux else { return schwach ? true : nil }
        if l < schwelle || schwach { return true }
        if l >= hellAb { return false }
        return nil
    }

    func bewerte(frisch: Bool = false) {
        entscheide(messen(), frisch: frisch)
        anzeigen()
    }

    /// Ohne Wartezeit: Sagt die Messung „dunkel“ oder „hell“, wird gleich umgeschaltet.
    /// `frisch`: beim Start oder Aufwachen gibt es keinen eigenen letzten Stand, den der Abstand schützen
    /// müsste (macOS hat beim Beenden vielleicht selbst umgestellt) – dann im Zwischenbereich an der Mitte.
    func entscheide(_ gemessen: Messung?, frisch: Bool = false) {
        guard automatik, let m = gemessen, Date() >= ruhigBis,
              -eigeneAenderung.timeIntervalSinceNow > 1 else { return }  // eben erst umgeschaltet
        var s = soll(m)
        if s == nil && frisch, let l = m.lux { s = l < (schwelle + hellAb) / 2 }
        if angehalten {
            // Pause endet, sobald sich das Licht wirklich ändert
            guard let s, s != sollBeimAnhalten else { return }
            angehalten = false
        }
        guard let s, s != Erscheinung.dunkel else { return }
        umschalten(dunkel: s)
    }

    func umschalten(dunkel: Bool) {
        eigeneAenderung = Date()
        Erscheinung.setze(dunkel: dunkel)
        zuletzt = (dunkel, Date())
    }

    /// Kam die Änderung nicht von hier, hat jemand von Hand umgestellt.
    func erscheinungGeaendert() {
        defer { anzeigen() }
        guard automatik, -eigeneAenderung.timeIntervalSinceNow > 5 else { return }
        angehalten = true
        sollBeimAnhalten = messen().flatMap(soll)
    }

    // MARK: macOS-Automatik nach Uhrzeit

    func uhrzeitAutomatikAus() {
        guard Erscheinung.nachUhrzeit else { return }
        ablage.set(true, forKey: "uhrzeitWarAn")  // gemerkt, auch falls die App abstürzt
        eigeneAenderung = Date()
        Erscheinung.nachUhrzeit(false)
    }

    func uhrzeitAutomatikZurueck() {
        guard ablage.bool(forKey: "uhrzeitWarAn") else { return }
        ablage.set(false, forKey: "uhrzeitWarAn")
        eigeneAenderung = Date()
        Erscheinung.nachUhrzeit(true)
    }

    // MARK: Einstellungen

    func setzeAutomatik(_ an: Bool) {
        automatik = an
        angehalten = false
        if an {
            uhrzeitAutomatikAus()
            eigeneAenderung = .distantPast  // gleich entscheiden, nicht erst in einer Sekunde
            bewerte(frisch: true)
        } else {
            uhrzeitAutomatikZurueck()
            anzeigen()
        }
    }

    func setzeSchwelle(_ wert: Double) {
        schwelle = wert
        angehalten = false
        bewerte()
    }

    /// Das Licht gerade soll schon als dunkel zählen: Grenze knapp darüber.
    func kalibrieren() {
        guard let l = Sensor.lux() else { return }
        schwelle = max(2, (l * 1.25).rounded(.up) + 1)
        angehalten = false
        bewerte(frisch: true)
    }

    func setzeHelligkeitsGrenze(_ wert: Double) {
        helligkeitsGrenze = wert
        angehalten = false
        bewerte()
    }

    var autostart: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            anzeigen()
        }
    }

    // MARK: Anzeige

    /// Fenster und (falls gewünscht) Symbol auf den neuen Stand bringen. Bei offenem Fenster läuft das
    /// zehnmal pro Sekunde – dann wird auch gleich entschieden, also sofort umgeschaltet.
    func anzeigen() {
        if fenster?.isVisible == true {
            let m = messen()
            messung = m
            entscheide(m)
            glaetten(m)
            objectWillChange.send()
        }
        guard let knopf = eintrag?.button else { return }
        let stand = "\(automatik) \(angehalten)"
        guard stand != gezeichnet else { return }  // nur neu zeichnen, wenn sich etwas ändert
        gezeichnet = stand
        let bild = NSImage(systemSymbolName: automatik ? "sun.horizon.fill" : "sun.horizon",
                           accessibilityDescription: "Dämmerung")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        bild?.isTemplate = true
        knopf.image = bild
        knopf.appearsDisabled = !automatik || angehalten
        knopf.toolTip = "Dämmerung – " + zustandText()
    }

    /// Der Sensor liefert etwa alle 0,4 s einen neuen Wert; dazwischen gleitet die Anzeige hin
    /// (Lux auf der logarithmischen Skala, sonst springt sie im Dunkeln).
    func glaetten(_ m: Messung?) {
        func hin(_ alt: Double?, _ neu: Double) -> Double { alt.map { $0 + (neu - $0) * 0.3 } ?? neu }
        if let l = m?.lux {
            let ziel = max(l, 0.05)
            weichLux = weichLux.map { $0 * pow(ziel / max($0, 0.05), 0.3) } ?? ziel
        } else {
            weichLux = nil
        }
        if let h = m?.helligkeit { weichHelligkeit = hin(weichHelligkeit, h) }
        if let k = m?.kelvin { weichKelvin = hin(weichKelvin, k) } else { weichKelvin = nil }
        if let ton = m?.farbton {
            weichFarbton = (hin(weichFarbton?.0, ton.0), hin(weichFarbton?.1, ton.1), hin(weichFarbton?.2, ton.2))
        } else {
            weichFarbton = nil
        }
    }

    func symbolAnpassen() {
        if symbolZeigen && eintrag == nil {
            let neu = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            neu.button?.target = self
            neu.button?.action = #selector(zeigeEinstellungen)
            eintrag = neu
            gezeichnet = ""
            anzeigen()
        } else if !symbolZeigen, let alt = eintrag {
            NSStatusBar.system.removeStatusItem(alt)
            eintrag = nil
        }
    }

    func zustandText() -> String {
        guard automatik else {
            return ablage.bool(forKey: "uhrzeitWarAn") || Erscheinung.nachUhrzeit
                ? t("Aus – macOS stellt nach Uhrzeit um", "Off – macOS switches by time of day")
                : t("Aus", "Off")
        }
        if angehalten {
            return t("Pausiert, weil von Hand umgestellt – bis sich das Licht ändert",
                     "Paused because you switched by hand – until the light changes")
        }
        let jetzt = Erscheinung.dunkel ? t("Gerade dunkel", "Dark right now") : t("Gerade hell", "Light right now")
        // warum – damit klar ist, ob das Licht oder der Bildschirm entschieden hat
        var grund = ""
        if let m = messung, Erscheinung.dunkel {
            if (m.helligkeit ?? 1) < helligkeitsGrenze && (m.lux ?? 0) >= schwelle {
                grund = t(" – wegen der Bildschirmhelligkeit", " – because of the screen brightness")
            } else if let l = m.lux, l >= schwelle, l < hellAb {
                grund = t(" – hell wird es erst ab \(lux(hellAb))", " – turns light from \(lux(hellAb))")
            }
        }
        guard let zuletzt, zuletzt.dunkel == Erscheinung.dunkel else { return jetzt + grund }
        return jetzt + t(", seit \(uhrzeit(zuletzt.zeit))", " since \(uhrzeit(zuletzt.zeit))") + grund
    }

    /// Solange das Fenster offen ist, steht die App im Dock und hat ein eigenes Menü.
    @objc func zeigeEinstellungen() {
        if fenster == nil {
            let f = NSWindow(contentViewController: NSHostingController(rootView: Einstellungen(app: self)))
            f.title = "Dämmerung"
            f.styleMask = [.titled, .closable, .miniaturizable]
            f.isReleasedWhenClosed = false
            f.delegate = self
            f.center()
            f.setFrameAutosaveName("Einstellungen")
            fenster = f
        }
        // gemerkte Stelle ragt über den Bildschirm (z. B. von einer früheren, höheren Fassung): mittig
        if let f = fenster, let schirm = (f.screen ?? NSScreen.main)?.visibleFrame, !schirm.contains(f.frame) {
            f.center()
        }
        // Der Wechsel in den Dock-Modus wirkt erst nach diesem Durchlauf; direkt danach aktiviert
        // blieb das Fenster hinter der vorderen App. Darum gleich nach vorn stellen und kurz darauf aktivieren.
        NSApp.setActivationPolicy(.regular)
        fenster?.makeKeyAndOrderFront(nil)
        fenster?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.fenster?.makeKeyAndOrderFront(nil)
        }
        if mitlaufen == nil {
            // nur bei offenem Fenster so oft: ein Blick kostet 40 µs, das Zeichnen etwas mehr
            let neu = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.anzeigen() }
            neu.tolerance = 0.02
            RunLoop.main.add(neu, forMode: .common)
            mitlaufen = neu
        }
        anzeigen()
    }

    func windowWillClose(_ n: Notification) {
        mitlaufen?.invalidate()
        mitlaufen = nil
        NSApp.setActivationPolicy(.accessory)  // zurück in den Hintergrund
    }

    func hauptmenue() -> NSMenu {
        let leiste = NSMenu()
        let appMenue = NSMenu()
        appMenue.addItem(withTitle: t("Dämmerung beenden", "Quit Dämmerung"),
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fensterMenue = NSMenu(title: t("Fenster", "Window"))
        fensterMenue.addItem(withTitle: t("Schließen", "Close"), action: #selector(NSWindow.performClose(_:)),
                             keyEquivalent: "w")
        for untermenue in [appMenue, fensterMenue] {
            let punkt = NSMenuItem()
            punkt.submenu = untermenue
            leiste.addItem(punkt)
        }
        return leiste
    }
}

// MARK: - Fenster

struct Einstellungen: View {
    @ObservedObject var app: App

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { app.automatik }, set: { app.setzeAutomatik($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Hell und dunkel nach dem Umgebungslicht", "Light and dark follow the ambient light"))
                        Text(app.zustandText()).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section(t("Licht", "Light")) {
                LichtGrafik(app: app)
                BildschirmZeile(app: app)
            }

            Section {
                Picker(t("Dunkel unter", "Dark below"),
                       selection: Binding(get: { app.schwelle }, set: { app.setzeSchwelle($0) })) {
                    ForEach(auswahl, id: \.self) { Text(lux($0)).tag($0) }
                }
                LabeledContent(t("Hell wieder ab", "Light again from"), value: lux(app.hellAb))
                LabeledContent(t("Gerade dunkel genug?", "Dark enough right now?")) {
                    Button(t("Als Grenze nehmen", "Use as limit")) { app.kalibrieren() }
                        .disabled(Sensor.dienst == nil)
                }
                Picker(t("Auch dunkel, wenn Bildschirm", "Also dark when screen is"),
                       selection: Binding(get: { app.helligkeitsGrenze }, set: { app.setzeHelligkeitsGrenze($0) })) {
                    ForEach(helligkeitsAuswahl, id: \.self) { wert in
                        Text(wert == 0 ? t("nie", "never") : t("unter \(prozent(wert))", "below \(prozent(wert))"))
                            .tag(wert)
                    }
                }
            } header: {
                Text(t("Grenze", "Threshold"))
            } footer: {
                Text(t("Bei offenem Fenster reagiert Dämmerung sofort, sonst schaut sie alle 20 s nach – eine "
                       + "geänderte Bildschirmhelligkeit meldet macOS sofort. Ins Helle erst ab der höheren Grenze, "
                       + "weil der Sensor auch das Licht des Bildschirms sieht.",
                       "With this window open Dämmerung reacts instantly, otherwise it checks every 20 s – macOS "
                       + "reports brightness changes right away. Back to light only from the higher limit, because "
                       + "the sensor also sees the screen's own light."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(t("Beim Anmelden starten", "Start at login"),
                       isOn: Binding(get: { app.autostart }, set: { app.autostart = $0 }))
                Toggle(t("Symbol in der Menüleiste zeigen", "Show icon in the menu bar"),
                       isOn: Binding(get: { app.symbolZeigen }, set: { app.symbolZeigen = $0; app.objectWillChange.send() }))
            } header: {
                Text(t("Allgemein", "General"))
            }

            // Schließen und Beenden sehen gleich aus (das Dock-Symbol verschwindet beide Male) –
            // darum steht hier ausdrücklich, was welches tut.
            Section {
                LabeledContent(t("Fenster schließen (⌘W)", "Close window (⌘W)")) {
                    Text(t("Dämmerung läuft unsichtbar weiter", "Dämmerung keeps running invisibly"))
                }
                LabeledContent {
                    Button(t("Beenden", "Quit")) { NSApp.terminate(nil) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Beenden (⌘Q)", "Quit (⌘Q)"))
                        Text(app.autostart
                             ? t("Schaltet nichts mehr um bis zum nächsten Anmelden",
                                 "Stops switching until you next log in")
                             : t("Schaltet nichts mehr um, bis du Dämmerung wieder öffnest",
                                 "Stops switching until you open Dämmerung again"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Im Hintergrund", "In the background"))
            } footer: {
                Text(fehlt.isEmpty
                     ? t("Zurück zu diesen Einstellungen: Dämmerung noch einmal öffnen (Spotlight, Programme).",
                         "To get back here: open Dämmerung again (Spotlight, Applications).")
                     : t("Nicht verfügbar: ", "Not available: ") + fehlt)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // feste Höhe, der Rest scrollt – mit der Grafik war das Fenster sonst höher als der Bildschirm
        .frame(width: 480, height: 720)
    }

    var auswahl: [Double] { schwellen.contains(app.schwelle) ? schwellen : (schwellen + [app.schwelle]).sorted() }

    // von Hand gesetzte Werte (defaults write) trotzdem anzeigen
    var helligkeitsAuswahl: [Double] {
        helligkeitsGrenzen.contains(app.helligkeitsGrenze) ? helligkeitsGrenzen
            : (helligkeitsGrenzen + [app.helligkeitsGrenze]).sorted()
    }

    func prozent(_ wert: Double) -> String { "\(Int((wert * 100).rounded())) %" }

    var fehlt: String {
        [Sensor.dienst == nil ? t("Lichtsensor", "light sensor") : nil,
         Bildschirm.lesen == nil ? t("Helligkeit", "brightness") : nil,
         Erscheinung.setzen == nil ? t("direktes Umschalten (nutzt Systemereignisse)", "direct switching (uses System Events)") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Live-Grafiken (nur bei offenem Fenster, 10× pro Sekunde)

func farbe(_ hex: Int, _ deckkraft: Double = 1) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
          blue: Double(hex & 255) / 255, opacity: deckkraft)
}

/// Für die Grafiken genauer als `lux(_:)`: unter 100 lx mit einer Nachkommastelle
func luxGenau(_ wert: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale.current
    f.numberStyle = .decimal
    f.maximumFractionDigits = wert < 100 ? 1 : 0
    f.minimumFractionDigits = wert < 100 ? 1 : 0
    return (f.string(from: NSNumber(value: wert)) ?? "\(wert)") + " lx"
}

func zone(_ l: Double, _ app: App) -> String {
    l < app.schwelle ? t("dunkel", "dark") : l >= app.hellAb ? t("hell", "light") : t("dazwischen", "in between")
}

/// „2.800 K · warm“ – auf 50 K gerundet, mehr gibt die Näherung nicht her
func lichtfarbeText(_ k: Double) -> String {
    let gerundet = NumberFormatter.localizedString(from: NSNumber(value: (k / 50).rounded() * 50), number: .decimal)
    let art = k < 3300 ? t("warm", "warm") : k < 5000 ? t("neutral", "neutral") : t("kühl", "cool")
    return "\(gerundet) K · \(art)"
}

func lichtfarbe(_ ton: (Double, Double, Double)?, _ deckkraft: Double = 1) -> Color? {
    ton.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2, opacity: deckkraft) }
}

let dunkelFarbe = 0x534AB7, mitteFarbe = 0xB4B2A9, hellFarbe = 0xFAC775

/// Horizont oder Skala – ein Klick schaltet um, die Wahl bleibt gespeichert.
struct LichtGrafik: View {
    @ObservedObject var app: App

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if app.messung == nil {
                    Text(t("Deckel zu – misst gerade nicht", "Lid closed – not measuring"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if app.weichLux == nil {
                    Text(t("Lichtsensor nicht lesbar", "Light sensor not readable"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if app.ansicht == 1 {
                    Skala(app: app)
                } else {
                    Horizont(app: app)
                }
            }
            .frame(height: 124)
            .contentShape(Rectangle())
            .onTapGesture { app.ansicht = (app.ansicht + 1) % 2 }
            .help(t("Klicken: andere Darstellung", "Click for another view"))
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(i == app.ansicht ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Ein kleiner Himmel: je heller, desto höher die Sonne; im Dunkeln Mond und Sterne.
/// Die Sonne leuchtet in der gemessenen Lichtfarbe – warmes Licht gibt eine orange Sonne.
struct Horizont: View {
    @ObservedObject var app: App
    static let sterne: [(Double, Double)] = [(0.07, 0.18), (0.2, 0.42), (0.33, 0.12), (0.47, 0.32), (0.6, 0.1),
                                            (0.74, 0.36), (0.88, 0.16), (0.13, 0.68), (0.66, 0.6), (0.4, 0.62)]

    /// Himmelsfarbe oben und unten, von Nacht über Dämmerung zu Tag
    static func himmel(_ p: Double) -> (Color, Color) {
        let stufen: [(Double, Int, Int)] = [(0, 0x0E0C24, 0x221E52), (0.3, 0x2A2570, 0x4A42A8),
                                            (0.45, 0x5B55C0, 0xD98A9A), (0.6, 0x6FA3E0, 0xF5C78E),
                                            (1, 0x3D8FE0, 0xBFE0FA)]
        let i = max(1, stufen.firstIndex { $0.0 >= p } ?? stufen.count - 1)
        let (a, b) = (stufen[i - 1], stufen[i])
        let f = (p - a.0) / max(0.001, b.0 - a.0)
        func misch(_ x: Int, _ y: Int) -> Color {
            func k(_ h: Int, _ s: Int) -> Double { Double((h >> s) & 255) / 255 }
            return Color(.sRGB, red: k(x, 16) + (k(y, 16) - k(x, 16)) * f, green: k(x, 8) + (k(y, 8) - k(x, 8)) * f,
                         blue: k(x, 0) + (k(y, 0) - k(x, 0)) * f)
        }
        return (misch(a.1, b.1), misch(a.2, b.2))
    }

    var body: some View {
        Canvas { ctx, size in
            let l = app.weichLux ?? 0
            let p = luxPosition(l)
            let form = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
            ctx.clip(to: form)
            let (oben, unten) = Self.himmel(p)
            ctx.fill(form, with: .linearGradient(Gradient(colors: [oben, unten]), startPoint: .zero,
                                                 endPoint: CGPoint(x: 0, y: size.height)))
            let boden = size.height - 30
            if p < 0.5 {
                for (x, y) in Self.sterne {
                    ctx.fill(Path(ellipseIn: CGRect(x: x * size.width, y: y * boden, width: 2.2, height: 2.2)),
                             with: .color(.white.opacity(min(1, (0.5 - p) * 3))))
                }
            }
            let x = 40 + p * (size.width - 80)
            let y = boden + 6 - sin(p * .pi / 2) * (boden - 18)
            if l < app.schwelle || p < 0.3 {
                let r = 12.0
                let mond = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    .subtracting(Path(ellipseIn: CGRect(x: x - r + 7, y: y - r - 4, width: 2 * r, height: 2 * r)))
                ctx.fill(mond, with: .color(farbe(0xF1EFE8)))
            } else {
                let sonne = lichtfarbe(app.weichFarbton) ?? farbe(0xFFC94D)
                let schein = lichtfarbe(app.weichFarbton, 0.55) ?? farbe(0xFFD98A, 0.55)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 34, y: y - 34, width: 68, height: 68)),
                         with: .radialGradient(Gradient(colors: [schein, schein.opacity(0)]),
                                               center: CGPoint(x: x, y: y), startRadius: 8, endRadius: 34))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 13, y: y - 13, width: 26, height: 26)), with: .color(sonne))
            }
            ctx.fill(Path(CGRect(x: 0, y: boden, width: size.width, height: size.height - boden)),
                     with: .color(farbe(0x1F1E1C, 0.92)))
            ctx.draw(Text("\(luxGenau(l)) · \(zone(l, app))").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundColor(.white),
                     at: CGPoint(x: 12, y: boden + 15), anchor: .leading)
            if let k = app.weichKelvin {
                let text = ctx.resolve(Text(lichtfarbeText(k)).font(.system(size: 12)).monospacedDigit()
                                        .foregroundColor(.white.opacity(0.85)))
                let breite = text.measure(in: size).width
                ctx.draw(text, at: CGPoint(x: size.width - 12, y: boden + 15), anchor: .trailing)
                if let punkt = lichtfarbe(app.weichFarbton) {
                    ctx.fill(Path(ellipseIn: CGRect(x: size.width - 12 - breite - 14, y: boden + 10, width: 9, height: 9)),
                             with: .color(punkt))
                }
            }
        }
    }
}

/// Logarithmische Skala von 0,1 bis 10.000 lx mit den eigenen Zonen und dem Zeiger.
struct Skala: View {
    @ObservedObject var app: App

    var body: some View {
        Canvas { ctx, size in
            let l = app.weichLux ?? 0
            let links = 24.0, breite = size.width - 48  // Platz für „10.000“ am Rand
            func x(_ v: Double) -> Double { links + luxPosition(v) * breite }
            let balken = CGRect(x: links, y: size.height / 2 + 2, width: breite, height: 16)
            var zonen = ctx
            zonen.clip(to: Path(roundedRect: balken, cornerRadius: 8))
            for (von, bis, f) in [(links, x(app.schwelle), dunkelFarbe), (x(app.schwelle), x(app.hellAb), mitteFarbe),
                                  (x(app.hellAb), links + breite, hellFarbe)] {
                zonen.fill(Path(CGRect(x: von, y: balken.minY, width: bis - von, height: balken.height)), with: .color(farbe(f)))
            }
            for v in [0.1, 1, 10, 100, 1000, 10000] {
                let px = x(v)
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: balken.maxY + 3)); $0.addLine(to: CGPoint(x: px, y: balken.maxY + 8)) },
                           with: .color(.secondary), lineWidth: 1)
                let text = v < 1 ? (Locale.current.decimalSeparator == "," ? "0,1" : "0.1")
                    : NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
                ctx.draw(Text(text).font(.system(size: 11)).foregroundColor(.secondary),
                         at: CGPoint(x: px, y: balken.maxY + 18), anchor: .center)
            }
            let px = x(l)
            ctx.fill(Path { $0.move(to: CGPoint(x: px - 7, y: balken.minY - 12)); $0.addLine(to: CGPoint(x: px + 7, y: balken.minY - 12))
                $0.addLine(to: CGPoint(x: px, y: balken.minY - 2)); $0.closeSubpath() }, with: .color(.primary))
            let rand = max(links + 40, min(links + breite - 40, px))
            ctx.draw(Text("\(luxGenau(l)) · \(zone(l, app))").font(.system(size: 13, weight: .medium)).monospacedDigit(),
                     at: CGPoint(x: rand, y: balken.minY - 26), anchor: .center)
            // Lichtfarbe oben rechts, mit einem Punkt in genau dieser Farbe
            if let k = app.weichKelvin {
                let text = ctx.resolve(Text(lichtfarbeText(k)).font(.system(size: 11)).monospacedDigit()
                                        .foregroundColor(.secondary))
                let textBreite = text.measure(in: size).width
                ctx.draw(text, at: CGPoint(x: links + breite, y: 9), anchor: .trailing)
                if let punkt = lichtfarbe(app.weichFarbton) {
                    ctx.fill(Path(ellipseIn: CGRect(x: links + breite - textBreite - 13, y: 4.5, width: 9, height: 9)),
                             with: .color(punkt))
                }
            }
        }
    }
}

/// Ein kleines MacBook, dessen Bildschirm so hell leuchtet wie eingestellt, mit der Prozentzahl darin.
struct BildschirmZeile: View {
    @ObservedObject var app: App

    var body: some View {
        let b = app.messung?.helligkeit.flatMap { _ in app.weichHelligkeit }
        let grenze = app.helligkeitsGrenze
        HStack(spacing: 14) {
            Canvas { ctx, size in
                let deckel = CGRect(x: 8, y: 2, width: size.width - 16, height: size.height - 10)
                ctx.fill(Path(roundedRect: deckel, cornerRadius: 5), with: .color(farbe(0x3A3A3C)))
                let schirm = deckel.insetBy(dx: 3.5, dy: 3.5)
                ctx.fill(Path(roundedRect: schirm, cornerRadius: 2), with: .color(Color(white: 0.07 + (b ?? 0) * 0.9)))
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height - 8, width: size.width, height: 5), cornerRadius: 2),
                         with: .color(farbe(0x8E8E93)))
                ctx.draw(Text(b.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundColor((b ?? 0) > 0.45 ? .black : .white),
                         at: CGPoint(x: schirm.midX, y: schirm.midY), anchor: .center)
            }
            .frame(width: 96, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(t("Bildschirmhelligkeit", "Screen brightness"))
                Text(grenze == 0 ? t("zählt nicht mit", "doesn't count")
                     : (app.messung?.helligkeit ?? 1) < grenze
                        ? t("zählt gerade als dunkel (unter \(Int(grenze * 100)) %)",
                            "counts as dark right now (below \(Int(grenze * 100)) %)")
                        : t("unter \(Int(grenze * 100)) % zählt als dunkel", "below \(Int(grenze * 100)) % counts as dark"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

let app = NSApplication.shared
let delegat = App()
app.delegate = delegat
app.setActivationPolicy(.accessory)
app.run()
