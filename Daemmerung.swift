// Dämmerung – läuft unsichtbar im Hintergrund: Wird es um den Mac herum dunkel, geht macOS
// in den Dark Mode, wird es wieder hell, zurück ins helle Erscheinungsbild.
//
// Kein Symbol in der Menüleiste (dort ist der Platz knapp, und verstellt wird selten).
// Einstellungen: Dämmerung noch einmal öffnen (Spotlight, Programme-Ordner) – dann kommt ein
// kleines Fenster, und solange es offen ist, steht die App auch im Dock. Fenster zu (⌘W) heißt
// nicht beenden – die App läuft weiter; nur ⌘Q / „Beenden“ hört auf. Im Fenster: Automatik an/aus,
// das Licht gerade (läuft sekündlich mit), die Grenze, „Gerade dunkel genug? Als Grenze nehmen“,
// Autostart und auf Wunsch doch ein Symbol in der Menüleiste (Sonne am Horizont – kein Mond,
// der sähe aus wie das Fokus-Symbol „Nicht stören“).
//
// Gemessen wird mit dem Umgebungslichtsensor neben der Kamera (derselbe, der die
// automatische Helligkeit steuert). Auf Wunsch zählt auch ein dunkel gestellter
// Bildschirm als dunkel (Grenze einstellbar: 5–30 %, Standard 10 %).
//
// Ruhig: Gewechselt wird erst, wenn das Licht eine Weile auf der anderen Seite bleibt
// (einstellbar: sofort, 5 s, 20 s, 1 min; Standard 5 s). Das ist nur gegen Hin-und-her,
// wenn kurz etwas vor dem Sensor ist – mit Energie hat es nichts zu tun. Zurück ins Helle erst ab der dreifachen Schwelle – der Sensor sieht auch das Licht des
// Bildschirms selbst (im dunklen Zimmer bei voller Helligkeit ca. 3 lx), ohne Abstand
// würde er sich selbst hin- und herschalten. Stellt man das Erscheinungsbild von Hand
// um, hält sich die App zurück, bis sich das Licht das nächste Mal wirklich ändert.
// Ist der Deckel zu (nur externer Bildschirm), misst sie nicht.
//
// Sparsam: Der Sensor läuft ohnehin (macOS liest ihn für Helligkeit und True Tone),
// ein Blick darauf kostet rund 40 µs. Nachgesehen wird, wenn sich die Bildschirmhelligkeit
// ändert (meldet macOS von selbst), nach dem Aufwachen und sonst alle 20 s – mit 10 s
// Spielraum, damit macOS das bündeln kann (rund 4.300 Blicke am Tag, zusammen ca. 0,2 s
// Rechenzeit). Ist der Bildschirm aus, wird gar nicht gemessen. Während ein Wechsel
// ansteht, alle 5 s, und solange das Fenster offen ist, jede Sekunde.
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

let wartezeiten: [TimeInterval] = [0, 5, 20, 60]  // zur Auswahl: so lange muss das Licht auf der anderen Seite bleiben
let standardWartezeit: TimeInterval = 5
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

    /// Umgebungslicht in Lux
    static func lux() -> Double? {
        guard let dienst, let ereignis, let feld,
              let e = ereignis(dienst, umgebungslicht, 0, 0)?.takeRetainedValue() else { return nil }
        return feld(e, Int32(umgebungslicht << 16))
    }
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
    let lux: Double?
    let helligkeit: Double?
}

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
    var mitlaufen: Timer?       // jede Sekunde, solange das Fenster offen ist
    var takt: Timer?            // alle 20 s, solange der Bildschirm an ist
    var bald: Timer?            // kurz nach einer Helligkeitsänderung
    var pruefTakt: Timer?       // alle 5 s, solange ein Wechsel ansteht
    var kandidat: Bool?         // soll gleich dunkel (true) oder hell (false) werden …
    var kandidatSeit = Date()   // … und das seit
    var aktivitaet: NSObjectProtocol?  // kein App Nap, solange der Bildschirm an ist
    var wachSeit = Date.distantPast    // Bildschirm zuletzt angegangen
    var angehalten = false      // von Hand umgestellt
    var sollBeimAnhalten: Bool?
    var eigeneAenderung = Date.distantPast
    var zuletzt: (dunkel: Bool, zeit: Date)?
    var beobachtet: Set<CGDirectDisplayID> = []
    var gezeichnet = ""
    var alsAnmeldeobjekt = false
    var messung: Messung?       // fürs Fenster

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
    /// Nur gegen Hin-und-her-Schalten (Hand vor dem Sensor, kurzer Schatten), nicht wegen Energie.
    var wartezeit: TimeInterval {
        get { ablage.object(forKey: "wartezeit") as? Double ?? standardWartezeit }
        set { ablage.set(newValue, forKey: "wartezeit") }
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
        // Deckel auf/zu, Bildschirm an- oder abgesteckt
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.beobachteHelligkeit()
            self?.bewerte()
        }

        let ersterStart = !ablage.bool(forKey: "autostartErledigt")
        autostartEinmalig()
        beobachteHelligkeit()
        symbolAnpassen()
        if automatik {
            uhrzeitAutomatikAus()
            bewerte(sofort: true)
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
        let einmal = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            self?.bald = nil
            self?.bewerte()
        }
        einmal.tolerance = 1
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
        kandidatBeenden()
    }

    /// Nach dem Aufwachen zügig passend umschalten (siehe `geradeAufgewacht`).
    func aufgewacht() {
        starteTakt()
        wachSeit = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.bewerte() }
    }

    /// Kurz nach dem Aufklappen sind die Werte noch nicht verlässlich: Der Sensor war verdeckt und
    /// die Helligkeit blendet erst von 0 hoch. Sofort umgeschaltet, wurde es kurz dunkel (25.10.2026).
    /// Darum dann die Helligkeit nicht mitzählen und eine zweite Messung abwarten – nur kürzer als sonst.
    var geradeAufgewacht: Bool { -wachSeit.timeIntervalSinceNow < 15 }

    // MARK: Entscheiden

    func messen() -> Messung? {
        guard let id = Bildschirm.eingebaut() else { return nil }  // zugeklappt: Sensor verdeckt
        return Messung(lux: Sensor.lux(), helligkeit: Bildschirm.helligkeit(id))
    }

    /// true = dunkel, false = hell, nil = dazwischen (bleibt, wie es ist)
    func soll(_ m: Messung) -> Bool? {
        let hell = geradeAufgewacht ? 1 : m.helligkeit ?? 1
        let schwach = hell < helligkeitsGrenze
        guard let l = m.lux else { return schwach ? true : nil }
        if l < schwelle || schwach { return true }
        if l >= hellAb && !(helligkeitsGrenze > 0 && hell < helligkeitsGrenze + 0.05) { return false }
        return nil
    }

    func bewerte(sofort: Bool = false) {
        defer { anzeigen() }
        guard automatik, let m = messen() else {
            kandidatBeenden()
            return
        }
        var s = soll(m)
        // Beim Start oder Aufwachen gibt es keinen eigenen letzten Stand, den der Abstand schützen
        // müsste (macOS hat beim Beenden vielleicht selbst umgestellt) – dann an der Mitte entscheiden.
        if s == nil && (sofort || geradeAufgewacht), let l = m.lux { s = l < (schwelle + hellAb) / 2 }
        if angehalten {
            // Pause endet, sobald sich das Licht wirklich ändert
            guard let s, s != sollBeimAnhalten else {
                kandidatBeenden()
                return
            }
            angehalten = false
        }
        guard let s, s != Erscheinung.dunkel else {
            kandidatBeenden()
            return
        }
        // nach dem Aufwachen höchstens 4 s: eine zweite Messung reicht als Bestätigung
        let warten = geradeAufgewacht ? min(4, wartezeit) : wartezeit
        if sofort || warten == 0 || (kandidat == s && -kandidatSeit.timeIntervalSinceNow >= warten - 0.5) {
            umschalten(dunkel: s)
        } else if kandidat != s {
            kandidat = s
            kandidatSeit = Date()
            let neu = Timer(timeInterval: min(5, warten), repeats: true) { [weak self] _ in self?.bewerte() }
            neu.tolerance = 1
            RunLoop.main.add(neu, forMode: .common)
            pruefTakt?.invalidate()
            pruefTakt = neu
        }
    }

    func kandidatBeenden() {
        pruefTakt?.invalidate()
        pruefTakt = nil
        kandidat = nil
    }

    func umschalten(dunkel: Bool) {
        kandidatBeenden()
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
        kandidatBeenden()
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
            bewerte(sofort: true)
        } else {
            kandidatBeenden()
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
        bewerte(sofort: true)
    }

    func setzeHelligkeitsGrenze(_ wert: Double) {
        helligkeitsGrenze = wert
        angehalten = false
        bewerte()
    }

    func setzeWartezeit(_ wert: TimeInterval) {
        wartezeit = wert
        kandidatBeenden()  // neu anfangen, mit der neuen Zeit
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

    /// Fenster und (falls gewünscht) Symbol auf den neuen Stand bringen.
    func anzeigen() {
        if fenster?.isVisible == true {
            messung = messen()
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
        if let kandidat {
            let rest = max(1, Int((wartezeit + kandidatSeit.timeIntervalSinceNow).rounded(.up)))
            return kandidat ? t("Wird in \(rest) s dunkel", "Turning dark in \(rest) s")
                            : t("Wird in \(rest) s hell", "Turning light in \(rest) s")
        }
        let jetzt = Erscheinung.dunkel ? t("Gerade dunkel", "Dark right now") : t("Gerade hell", "Light right now")
        guard let zuletzt, zuletzt.dunkel == Erscheinung.dunkel else { return jetzt }
        return jetzt + t(", seit \(uhrzeit(zuletzt.zeit))", " since \(uhrzeit(zuletzt.zeit))")
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
            let neu = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.anzeigen() }
            neu.tolerance = 0.2
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
                LabeledContent(t("Umgebung jetzt", "Ambient light now"), value: lichtText)
                LabeledContent(t("Bildschirmhelligkeit", "Screen brightness"), value: helligkeitText)
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
                Picker(t("Wechseln nach", "Switch after"),
                       selection: Binding(get: { app.wartezeit }, set: { app.setzeWartezeit($0) })) {
                    ForEach(warteAuswahl, id: \.self) { Text(dauer($0)).tag($0) }
                }
            } header: {
                Text(t("Grenze", "Threshold"))
            } footer: {
                Text(t("Die Wartezeit verhindert Hin-und-her, wenn kurz etwas vor dem Sensor ist. Ins Helle erst "
                       + "deutlich heller, weil der Sensor auch das Licht des Bildschirms sieht.",
                       "The delay prevents flip-flopping when something briefly covers the sensor. Back to light only "
                       + "when clearly brighter, because the sensor also sees the screen's own light."))
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
        .frame(width: 480)
        .fixedSize()
    }

    var auswahl: [Double] { schwellen.contains(app.schwelle) ? schwellen : (schwellen + [app.schwelle]).sorted() }

    // von Hand gesetzte Werte (defaults write) trotzdem anzeigen
    var helligkeitsAuswahl: [Double] {
        helligkeitsGrenzen.contains(app.helligkeitsGrenze) ? helligkeitsGrenzen
            : (helligkeitsGrenzen + [app.helligkeitsGrenze]).sorted()
    }
    var warteAuswahl: [TimeInterval] {
        wartezeiten.contains(app.wartezeit) ? wartezeiten : (wartezeiten + [app.wartezeit]).sorted()
    }

    func prozent(_ wert: Double) -> String { "\(Int((wert * 100).rounded())) %" }

    func dauer(_ s: TimeInterval) -> String {
        s == 0 ? t("sofort", "immediately") : s < 60 ? "\(Int(s)) s" : "\(Int(s / 60)) min"
    }

    var lichtText: String {
        guard let m = app.messung else { return t("Deckel zu – misst nicht", "Lid closed – not measuring") }
        return m.lux.map(lux) ?? t("Sensor nicht lesbar", "Sensor not readable")
    }

    var helligkeitText: String {
        app.messung?.helligkeit.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
    }

    var fehlt: String {
        [Sensor.dienst == nil ? t("Lichtsensor", "light sensor") : nil,
         Bildschirm.lesen == nil ? t("Helligkeit", "brightness") : nil,
         Erscheinung.setzen == nil ? t("direktes Umschalten (nutzt Systemereignisse)", "direct switching (uses System Events)") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

let app = NSApplication.shared
let delegat = App()
app.delegate = delegat
app.setActivationPolicy(.accessory)
app.run()
