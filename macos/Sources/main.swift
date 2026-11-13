// Post-it — petite app de listes de tâches façon Stickies
// Chaque note = une fenêtre. Les données sont enregistrées dans
// ~/Library/Application Support/Post-it/notes.json

import AppKit
import SwiftUI
import Combine
import EventKit

// MARK: - Données

/// Mode démo (`open -n -a Post-it --args --demo`) : notes fictives, rien n'est lu
/// ni écrit dans tes vraies données, aucun lien avec Calendrier ou Rappels.
let demoMode = CommandLine.arguments.contains("--demo")

/// `--demo --screenshots <dossier>` : l'app enregistre une image de chacune de ses
/// fenêtres de démonstration dans ce dossier, puis se ferme.
let screenshotDir: URL? = {
    let a = CommandLine.arguments
    guard demoMode, let i = a.firstIndex(of: "--screenshots"), i + 1 < a.count else { return nil }
    return URL(fileURLWithPath: (a[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
}()

/// Image d'une fenêtre de l'app elle-même (barre du haut comprise), sans autorisation d'écran
func captureWindow(_ win: NSWindow, to url: URL) {
    guard let view = win.contentView?.superview ?? win.contentView else { return }
    captureView(view, to: url)
}

@discardableResult
func captureView(_ view: NSView, to url: URL) -> Bool {
    view.layoutSubtreeIfNeeded()
    view.display()
    let name = url.lastPathComponent
    guard view.bounds.width > 1, view.bounds.height > 1,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("  ✗ \(name) : vue vide (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
        return false
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else {
        print("  ✗ \(name) : écriture impossible")
        return false
    }
    print("  ✓ \(name)")
    return true
}

func demoNotes() -> [NoteData] {
    let cal = Calendar.current
    func at(_ days: Int, _ h: Int, _ m: Int = 0) -> Date {
        let d = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
    }
    let x = Double((NSScreen.main?.visibleFrame.midX ?? 700) - 430)
    let y = Double((NSScreen.main?.visibleFrame.midY ?? 450) - 160)

    var a = NoteData()
    a.title = "Projet site web"; a.color = 0; a.x = x; a.y = y; a.w = 290; a.h = 360
    let design = TaskGroup(name: "Design")
    let dev = TaskGroup(name: "Développement")
    a.groups = [design, dev]
    a.items = [
        TodoItem(text: "Valider la **maquette** de l'accueil", done: true, group: design.id),
        TodoItem(text: "Choisir la *palette* de couleurs", group: design.id),
        TodoItem(text: "Relire la [documentation](https://developer.apple.com)", group: dev.id),
        TodoItem(text: "Réunion avec l'équipe", group: dev.id,
                 due: at(1, 10), kind: "event", end: at(1, 11), eventId: "demo"),
        TodoItem(text: "Mettre en ligne la ~~version 1~~ **version 2**", group: dev.id,
                 due: at(3, 14), end: at(3, 14, 30), reminderId: "demo"),
    ]

    var b = NoteData()
    b.title = "Courses"; b.color = 1; b.x = x + 310; b.y = y + 120; b.w = 240; b.h = 230
    b.floating = true
    b.items = [
        TodoItem(text: "Pain"), TodoItem(text: "Tomates", done: true),
        TodoItem(text: "Fromage"), TodoItem(text: "Café **en grains**"),
    ]

    var c = NoteData()
    c.title = "Lectures"; c.color = 2; c.x = x + 310; c.y = y - 150; c.w = 250; c.h = 200
    c.items = [
        TodoItem(text: "*Le Petit Prince*", done: true),
        TodoItem(text: "Un roman policier"),
        TodoItem(text: "Article sur l'histoire de l'imprimerie"),
    ]
    return [a, b, c]
}

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var group: UUID? = nil     // rubrique de la tâche (nil = sans rubrique)
    var due: Date? = nil       // date/heure de la tâche (→ événement Calendrier)
    var allDay: Bool? = nil    // true = toute la journée
    var kind: String? = nil       // "event" = rendez-vous ; nil = rappel à cocher
    var duration: Int? = nil      // (ancien) durée en minutes
    var end: Date? = nil          // fin du rendez-vous
    var eventId: String? = nil    // identifiant du rendez-vous dans Calendrier
    var reminderId: String? = nil // identifiant du rappel (affiché à cocher dans Calendrier)
}

// MARK: - Calendrier (EventKit) : rendez-vous (événements) ou rappels à cocher

final class CalendarSync {
    static let shared = CalendarSync()
    private(set) var store = EKEventStore()
    private var alerted = false
    private typealias Synced = (sig: String, id: String, done: Bool, event: Bool)
    private var synced: [UUID: Synced] = [:]
    private var missing: [UUID: Int] = [:]   // éléments introuvables (iCloud peut être momentanément vide)

    /// Introuvable deux fois de suite, avec des calendriers bien chargés → vraiment supprimé
    private func reallyGone(_ id: UUID, _ t: EKEntityType) -> Bool {
        guard !store.calendars(for: t).isEmpty else { return false }
        let n = (missing[id] ?? 0) + 1
        missing[id] = n
        return n >= 2
    }

    func isEvent(_ it: TodoItem) -> Bool { it.kind == "event" }

    func authorized(_ t: EKEntityType) -> Bool {
        let s = EKEventStore.authorizationStatus(for: t)
        return s == .fullAccess
    }

    func ensureAccess(_ t: EKEntityType, _ done: @escaping (Bool) -> Void) {
        if authorized(t) { done(true); return }
        let name = (t == .event) ? "Calendriers" : "Rappels"
        let pane = (t == .event) ? "Privacy_Calendars" : "Privacy_Reminders"
        let cb: (Bool, Error?) -> Void = { [weak self] ok, _ in
            DispatchQueue.main.async {
                // Après une autorisation, l'ancien EKEventStore ne voit souvent rien
                if ok { self?.store = EKEventStore() }
                else { self?.report("Post-it n'a pas accès aux \(name).",
                                    "Autorise-le dans Réglages Système → Confidentialité et sécurité → \(name) (accès complet), puis reviens dans Post-it.",
                                    pane: pane) }
                done(ok)
            }
        }
        if t == .event { store.requestFullAccessToEvents(completion: cb) }
        else { store.requestFullAccessToReminders(completion: cb) }
    }

    private func plainTitle(_ it: TodoItem) -> String {
        let t = String(richText(it.text).characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Tâche" : t
    }

    private func signature(_ it: TodoItem) -> String {
        "\(it.kind ?? "rappel")|\(plainTitle(it))|\(it.due?.timeIntervalSince1970 ?? 0)|\(it.allDay ?? false)|\(eventEnd(it)?.timeIntervalSince1970 ?? 0)|\(it.done)"
    }

    /// Au lancement : on mémorise les éléments déjà liés
    func prime(_ models: [NoteModel]) {
        for m in models {
            for it in m.data.items where it.due != nil {
                if isEvent(it), let e = it.eventId { synced[it.id] = (signature(it), e, it.done, true) }
                if !isEvent(it), let r = it.reminderId { synced[it.id] = (signature(it), r, it.done, false) }
            }
        }
    }

    // MARK: Rendez-vous

    private func upsertEvent(_ it: TodoItem) -> String? {
        guard let due = it.due else { return nil }
        var ev: EKEvent? = nil
        if let eid = it.eventId { ev = store.event(withIdentifier: eid) }
        if ev == nil {
            let cal = store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first { $0.allowsContentModifications }
            guard let cal = cal else {
                report("Aucun calendrier modifiable trouvé.",
                       "Ouvre Calendrier et vérifie qu'un calendrier existe et est choisi par défaut dans ses réglages.")
                return nil
            }
            let e = EKEvent(eventStore: store)
            e.calendar = cal
            e.notes = "Créé depuis Post-it"
            ev = e
        }
        guard let e = ev else { return nil }
        let allDay = it.allDay ?? false
        e.title = (it.done ? "✓ " : "") + plainTitle(it)
        e.isAllDay = allDay
        e.startDate = due
        e.endDate = eventEnd(it) ?? due
        do {
            try store.save(e, span: .thisEvent, commit: true)
        } catch {
            report("Le rendez-vous n'a pas pu être créé.", error.localizedDescription)
            return nil
        }
        return e.eventIdentifier
    }

    private func removeEvent(_ id: String) {
        guard authorized(.event), let e = store.event(withIdentifier: id) else { return }
        try? store.remove(e, span: .thisEvent, commit: true)
    }

    // MARK: Rappels (à cocher, visibles aussi dans Calendrier)

    private func reminder(_ id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    private func upsertReminder(_ it: TodoItem) -> String? {
        guard let due = it.due else { return nil }
        var r: EKReminder? = nil
        if let rid = it.reminderId { r = reminder(rid) }
        if r == nil {
            let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first { $0.allowsContentModifications }
            guard let list = list else {
                report("Aucune liste de rappels trouvée.",
                       "Ouvre l'app Rappels et crée une liste, puis choisis Note → Synchroniser avec Calendrier.")
                return nil
            }
            let n = EKReminder(eventStore: store)
            n.calendar = list
            r = n
        }
        guard let rem = r else { return nil }
        let allDay = it.allDay ?? false
        let comps: Set<Calendar.Component> = allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
        rem.title = plainTitle(it)
        rem.notes = rangeText(it) + "\nCréé depuis Post-it"
        rem.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
        rem.isCompleted = it.done
        rem.alarms?.forEach { rem.removeAlarm($0) }
        if !allDay { rem.addAlarm(EKAlarm(absoluteDate: due)) }
        do {
            try store.save(rem, commit: true)
        } catch {
            report("Le rappel n'a pas pu être créé.", error.localizedDescription)
            return nil
        }
        return rem.calendarItemIdentifier
    }

    private func removeReminder(_ id: String) {
        guard authorized(.reminder), let r = reminder(id) else { return }
        try? store.remove(r, commit: true)
    }

    // MARK: Messages

    /// Affiche une seule fois par session le problème rencontré
    func report(_ title: String, _ info: String, pane: String? = nil) {
        guard !alerted else { return }
        alerted = true
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = info
            if pane != nil {
                a.addButton(withTitle: "Ouvrir les Réglages")
                a.addButton(withTitle: "Plus tard")
            } else {
                a.addButton(withTitle: "OK")
            }
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn, let pane = pane,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Relance manuelle (menu Note → Synchroniser avec Calendrier)
    func retry(_ models: [NoteModel]) {
        alerted = false
        synced.removeAll()
        reconcile(models)
    }

    // MARK: Synchronisation

    /// Appelé après chaque modification : crée / met à jour / supprime
    func reconcile(_ models: [NoteModel]) {
        var alive = Set<UUID>()
        var pending = Set<UUID>()
        var needEvent = false, needReminder = false
        for m in models {
            for (i, it) in m.data.items.enumerated() {
                let ev = isEvent(it)
                // Lien du mauvais type (changement rappel ↔ rendez-vous) ou date retirée
                if let r = it.reminderId, it.due == nil || ev {
                    removeReminder(r)
                    m.data.items[i].reminderId = nil
                }
                if let e = it.eventId, it.due == nil || !ev {
                    removeEvent(e)
                    m.data.items[i].eventId = nil
                }
                guard it.due != nil else { synced[it.id] = nil; continue }
                alive.insert(it.id)
                let linked = ev ? it.eventId : it.reminderId
                if linked == nil || synced[it.id]?.sig != signature(it) {
                    pending.insert(it.id)
                    if ev { needEvent = true } else { needReminder = true }
                }
            }
        }
        // Tâche supprimée : on retire l'élément, sauf s'il était fait
        // (« Effacer les tâches faites » garde l'historique dans Calendrier)
        for (id, s) in synced where !alive.contains(id) {
            if !s.done { if s.event { removeEvent(s.id) } else { removeReminder(s.id) } }
            synced[id] = nil
        }
        let run: (EKEntityType) -> Void = { [weak self] t in
            self?.ensureAccess(t) { ok in
                guard ok, let self = self else { return }
                for m in models {
                    for i in m.data.items.indices where pending.contains(m.data.items[i].id) {
                        let it = m.data.items[i]
                        guard it.due != nil, self.isEvent(it) == (t == .event) else { continue }
                        if t == .event {
                            guard let id = self.upsertEvent(it) else { continue }
                            if it.eventId != id { m.data.items[i].eventId = id }
                            self.synced[it.id] = (self.signature(it), id, it.done, true)
                        } else {
                            guard let id = self.upsertReminder(it) else { continue }
                            if it.reminderId != id { m.data.items[i].reminderId = id }
                            self.synced[it.id] = (self.signature(it), id, it.done, false)
                        }
                    }
                }
            }
        }
        if needEvent { run(.event) }
        if needReminder { run(.reminder) }
    }

    /// Au retour dans l'app : on récupère ce qui a été changé dans Calendrier / Rappels
    func pull(_ models: [NoteModel]) {
        store.refreshSourcesIfNecessary()
        for m in models {
            for (i, it) in m.data.items.enumerated() {
                if isEvent(it), let eid = it.eventId, authorized(.event) {
                    if let e = store.event(withIdentifier: eid) {
                        missing[it.id] = nil
                        let allDay = e.isAllDay
                        let endChanged = !allDay && e.endDate != eventEnd(it)
                        if e.startDate != it.due || allDay != (it.allDay ?? false) || endChanged {
                            m.data.items[i].due = e.startDate
                            m.data.items[i].allDay = allDay ? true : nil
                            m.data.items[i].end = e.endDate
                            let n = m.data.items[i]
                            synced[it.id] = (signature(n), eid, n.done, true)
                        }
                    } else if reallyGone(it.id, .event) {
                        missing[it.id] = nil
                        synced[it.id] = nil
                        m.data.items[i].eventId = nil
                        m.data.items[i].allDay = nil
                        m.data.items[i].due = nil
                    }
                } else if !isEvent(it), let rid = it.reminderId, authorized(.reminder) {
                    if let r = reminder(rid) {
                        missing[it.id] = nil
                        var changed = false
                        if r.isCompleted != it.done { m.data.items[i].done = r.isCompleted; changed = true }
                        if let c = r.dueDateComponents, let d = Calendar.current.date(from: c) {
                            let allDay = (c.hour == nil)
                            if d != it.due || allDay != (it.allDay ?? false) {
                                if let oldStart = it.due, let oldEnd = eventEnd(it) {
                                    m.data.items[i].end = d.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
                                }
                                m.data.items[i].due = d
                                m.data.items[i].allDay = allDay ? true : nil
                                changed = true
                            }
                        }
                        if changed {
                            let n = m.data.items[i]
                            synced[it.id] = (signature(n), rid, n.done, false)
                        }
                    } else if reallyGone(it.id, .reminder) {
                        missing[it.id] = nil
                        synced[it.id] = nil
                        m.data.items[i].reminderId = nil
                        m.data.items[i].allDay = nil
                        m.data.items[i].due = nil
                    }
                }
            }
        }
    }
}

func eventEnd(_ it: TodoItem) -> Date? {
    guard let start = it.due else { return nil }
    if it.allDay ?? false {
        return max(Calendar.current.startOfDay(for: it.end ?? start), start)
    }
    if let e = it.end, e > start { return e }
    return start.addingTimeInterval(TimeInterval((it.duration ?? (it.kind == "event" ? 60 : 30)) * 60))
}

/// « De lun. 17 nov., 09:00 à 09:30 » / « Du 17 nov. au 19 nov. »
func rangeText(_ it: TodoItem) -> String {
    guard let d = it.due else { return "" }
    let allDay = it.allDay ?? false
    let e = eventEnd(it) ?? d
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    if allDay {
        f.setLocalizedDateFormatFromTemplate("EEEdMMMM")
        return cal.isDate(e, inSameDayAs: d) ? "Le " + f.string(from: d)
                                             : "Du " + f.string(from: d) + " au " + f.string(from: e)
    }
    f.setLocalizedDateFormatFromTemplate("EEEdMMMMHHmm")
    let h = DateFormatter()
    h.locale = Locale(identifier: "fr_FR")
    h.setLocalizedDateFormatFromTemplate("HHmm")
    return "De " + f.string(from: d) + " à " + (cal.isDate(e, inSameDayAs: d) ? h.string(from: e) : f.string(from: e))
}

func durationLabel(_ m: Int) -> String {
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)"
}

func dueLabel(_ d: Date, allDay: Bool) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    let day: String
    if cal.isDateInToday(d) { day = "Aujourd'hui" }
    else if cal.isDateInTomorrow(d) { day = "Demain" }
    else if cal.isDateInYesterday(d) { day = "Hier" }
    else { f.setLocalizedDateFormatFromTemplate("EEEdMMM"); day = f.string(from: d) }
    if allDay { return day }
    f.setLocalizedDateFormatFromTemplate("HHmm")
    return day + ", " + f.string(from: d)
}

struct DueEditor: View {
    @Binding var item: TodoItem
    var close: () -> Void
    @State private var date: Date
    @State private var end: Date
    @State private var span: TimeInterval
    @State private var allDay: Bool
    @State private var asEvent: Bool

    init(item: Binding<TodoItem>, close: @escaping () -> Void) {
        _item = item
        self.close = close
        let it = item.wrappedValue
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let def = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let start = it.due ?? def
        let lastEvent = UserDefaults.standard.string(forKey: "lastDueKind") == "event"
        let isEv = it.due == nil ? lastEvent : it.kind == "event"
        let fin = it.due == nil ? start.addingTimeInterval(isEv ? 3600 : 1800)
                                : (eventEnd(it) ?? start.addingTimeInterval(isEv ? 3600 : 1800))
        _date = State(initialValue: start)
        _end = State(initialValue: fin)
        _span = State(initialValue: max(0, fin.timeIntervalSince(start)))
        _allDay = State(initialValue: it.allDay ?? false)
        // Nouvelle date : on reprend le dernier type choisi
        _asEvent = State(initialValue: isEv)
    }

    private var comps: DatePickerComponents { allDay ? [.date] : [.date, .hourAndMinute] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $asEvent) {
                Text("Rappel à cocher").tag(false)
                Text("Rendez-vous").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack {
                Text("Début").frame(width: 38, alignment: .leading)
                DatePicker("", selection: $date, displayedComponents: comps)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .fixedSize()   // largeur naturelle : l'heure n'est plus coupée
                Spacer()
            }
            HStack {
                Text("Fin").frame(width: 38, alignment: .leading)
                DatePicker("", selection: $end, in: date..., displayedComponents: comps)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .fixedSize()   // largeur naturelle : l'heure n'est plus coupée
                Spacer()
            }
            Toggle("Toute la journée", isOn: $allDay)

            HStack {
                if item.due != nil {
                    Button("Retirer") {
                        item.due = nil
                        item.end = nil
                        item.allDay = nil
                        close()
                    }
                }
                Spacer()
                Button("Annuler", action: close).keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 310)
        // Déplacer le début décale la fin en gardant la même durée
        .onChange(of: date) { _, d in end = d.addingTimeInterval(span) }
        .onChange(of: end) { _, e in span = max(0, e.timeIntervalSince(date)) }
        // Changer de type ajuste la durée si elle est encore celle par défaut
        .onChange(of: asEvent) { _, ev in
            if span == 1800 || span == 3600 { end = date.addingTimeInterval(ev ? 3600 : 1800) }
        }
    }

    private func save() {
        let cal = Calendar.current
        item.allDay = allDay ? true : nil
        item.kind = asEvent ? "event" : nil
        item.duration = nil
        if allDay {
            item.due = cal.startOfDay(for: date)
            item.end = cal.startOfDay(for: max(end, date))
        } else {
            item.due = date
            item.end = end > date ? end : date.addingTimeInterval(asEvent ? 3600 : 1800)
        }
        UserDefaults.standard.set(asEvent ? "event" : "rappel", forKey: "lastDueKind")
        close()
    }
}

struct TaskGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var collapsed = false
}

struct NoteData: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var color = 0
    var x: Double = 200
    var y: Double = 400
    var w: Double = 260
    var h: Double = 250
    var floating = false
    var items: [TodoItem] = []
    var pomoWork: Int? = nil   // minutes de travail (optionnel : compatible avec les anciennes notes)
    var pomoRest: Int? = nil   // minutes de pause
    var groups: [TaskGroup]? = nil   // rubriques (optionnel : compatible avec les anciennes notes)
    var opacity: Double? = nil       // opacité de la fenêtre (nil = 100 %)
}

let opacityLevels = [100, 90, 80, 70, 60, 50, 40]

extension NoteData {
    var sections: [TaskGroup] {
        get { groups ?? [] }
        set { groups = newValue.isEmpty ? nil : newValue }
    }

    /// Tâche sans rubrique (ou dont la rubrique n'existe plus)
    func isLoose(_ item: TodoItem) -> Bool {
        guard let g = item.group else { return true }
        return !sections.contains { $0.id == g }
    }
}

// MARK: - Pomodoro

final class Pomodoro: ObservableObject {
    enum Phase { case work, rest }

    @Published var phase: Phase = .work
    @Published var remaining: Int
    @Published var running = false
    @Published var workMin: Int { didSet { if !running && phase == .work { remaining = workMin * 60 }; onSettings?() } }
    @Published var restMin: Int { didSet { if !running && phase == .rest { remaining = restMin * 60 }; onSettings?() } }

    var onSettings: (() -> Void)?
    private var timer: Timer?
    private var end: Date?

    init(work: Int, rest: Int) {
        workMin = work
        restMin = rest
        remaining = work * 60
    }

    deinit { timer?.invalidate() }

    var label: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    func toggle() { running ? pause() : start() }

    func start() {
        end = Date().addingTimeInterval(TimeInterval(remaining))
        running = true
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate(); timer = nil
        running = false
    }

    func reset() {
        pause()
        phase = .work
        remaining = workMin * 60
    }

    func skip() {
        pause()
        phase = (phase == .work) ? .rest : .work
        remaining = (phase == .work ? workMin : restMin) * 60
    }

    private func tick() {
        guard let end = end else { return }
        let left = Int(end.timeIntervalSinceNow.rounded(.up))
        if left > 0 {
            if left != remaining { remaining = left }
            return
        }
        // Fin de la séance
        NSSound(named: phase == .work ? "Glass" : "Hero")?.play()
        NSApp.requestUserAttention(.informationalRequest)
        skip()
    }
}

struct PomodoroView: View {
    @ObservedObject var p: Pomodoro
    @ObservedObject var model: NoteModel

    private func mark(_ on: Bool) -> String { on ? "✓ " : "    " }

    var body: some View {
        HStack(spacing: 3) {
            Button { model.data.floating.toggle() } label: {
                Image(systemName: model.data.floating ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(model.data.floating ? 0.85 : 0.4)
            .help(model.data.floating ? "Ne plus garder au premier plan" : "Garder cette note au premier plan")

            Button(action: p.toggle) {
                HStack(spacing: 4) {
                    Image(systemName: p.running ? "pause.fill" : (p.phase == .work ? "timer" : "cup.and.saucer.fill"))
                        .font(.system(size: 9, weight: .semibold))
                    Text(p.label)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(p.phase == .work
                                   ? Color.red.opacity(p.running ? 0.22 : 0.10)
                                   : Color.green.opacity(p.running ? 0.30 : 0.15))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(p.running ? "Mettre en pause" : (p.phase == .work ? "Lancer le pomodoro" : "Lancer la pause"))

            Menu {
                Section("Travail") {
                    ForEach([15, 20, 25, 30, 45, 50, 60], id: \.self) { m in
                        Button(mark(p.workMin == m) + "\(m) min") { p.workMin = m }
                    }
                }
                Section("Pause") {
                    ForEach([5, 10, 15, 20], id: \.self) { m in
                        Button(mark(p.restMin == m) + "\(m) min") { p.restMin = m }
                    }
                }
                Divider()
                Button(p.phase == .work ? "Passer à la pause" : "Passer au travail") { p.skip() }
                Button("Réinitialiser") { p.reset() }
                Divider()
                Menu("Transparence") {
                    ForEach(opacityLevels, id: \.self) { v in
                        let cur = Int(((model.data.opacity ?? 1) * 100).rounded())
                        Button(mark(cur == v) + "\(v) %") {
                            model.data.opacity = (v == 100) ? nil : Double(v) / 100
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.55)
            .help("Régler le pomodoro")
        }
        .foregroundColor(Color.black.opacity(0.75))
        .padding(.trailing, 8)
        .frame(height: 28)
        .environment(\.colorScheme, .light)
    }
}

struct Palette {
    let name: String
    let body: NSColor
    let bar: NSColor
}

func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255,
            green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255,
            alpha: 1)
}

let palettes: [Palette] = [
    Palette(name: "Jaune",  body: hex(0xFEF69A), bar: hex(0xF1E25F)),
    Palette(name: "Bleu",   body: hex(0xBFE5FB), bar: hex(0x93D0F5)),
    Palette(name: "Vert",   body: hex(0xCDF3B6), bar: hex(0xA6E386)),
    Palette(name: "Rose",   body: hex(0xFBCADF), bar: hex(0xF5A3C6)),
    Palette(name: "Violet", body: hex(0xE0CDFB), bar: hex(0xC5A5F5)),
    Palette(name: "Gris",   body: hex(0xEAEAEA), bar: hex(0xD0D0D0)),
]

final class NoteModel: ObservableObject {
    @Published var data: NoteData
    @Published var groupRequest = 0   // incrémenté par le menu « Nouvelle rubrique »
    init(_ d: NoteData) { data = d }
}

// MARK: - Sauvegarde

final class Store {
    private(set) var models: [NoteModel] = []
    private var subs: [UUID: AnyCancellable] = [:]
    private var pending: DispatchWorkItem?
    let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Post-it", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        url = demoMode
            ? FileManager.default.temporaryDirectory.appendingPathComponent("post-it-demo-\(UUID().uuidString).json")
            : dir.appendingPathComponent("notes.json")
    }

    func load() -> [NoteData] {
        if demoMode { return demoNotes() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let d = try Data(contentsOf: url)
            return try JSONDecoder().decode([NoteData].self, from: d)
        } catch {
            // Fichier illisible : on le met de côté au lieu de l'écraser
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("notes.json.illisible-\(f.string(from: Date()))")
            try? FileManager.default.moveItem(at: url, to: backup)
            let a = NSAlert()
            a.messageText = "Le fichier des notes était illisible"
            a.informativeText = "Il a été mis de côté, sans être effacé :\n\(backup.path)\n\n\(error.localizedDescription)"
            a.addButton(withTitle: "OK")
            a.runModal()
            return []
        }
    }

    func add(_ m: NoteModel) {
        models.append(m)
        subs[m.data.id] = m.$data.dropFirst().sink { [weak self] _ in self?.scheduleSave() }
        scheduleSave()
    }

    func remove(_ m: NoteModel) {
        models.removeAll { $0 === m }
        subs[m.data.id] = nil
        scheduleSave()
    }

    func scheduleSave() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.saveNow()
            if !demoMode { CalendarSync.shared.reconcile(self.models) }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private var saveErrorShown = false

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        do {
            let d = try enc.encode(models.map { $0.data })
            try d.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            saveErrorShown = false
        } catch {
            // Une seule alerte tant que le problème persiste
            guard !saveErrorShown else { return }
            saveErrorShown = true
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "Impossible d'enregistrer tes notes"
            a.informativeText = "Tes dernières modifications risquent d'être perdues si tu quittes Post-it.\n\n\(error.localizedDescription)"
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }
}

// MARK: - Vues

private func mark(_ on: Bool) -> String { on ? "✓ " : "    " }

struct ItemRow: View {
    @Binding var item: TodoItem
    var groups: [TaskGroup]
    var onMove: (UUID?) -> Void
    var onDelete: () -> Void
    @State private var hoverDelete = false
    @State private var hover = false
    @State private var editing = false
    @State private var linkClicked = false
    @State private var showDue = false
    @State private var hoverCal = false
    @State private var hoverFolder = false
    @FocusState private var focused: Bool

    private func dueText(_ d: Date) -> String {
        let allDay = item.allDay ?? false
        let start = dueLabel(d, allDay: allDay)
        guard let e = eventEnd(item) else { return start }
        let cal = Calendar.current
        if allDay {
            return cal.isDate(e, inSameDayAs: d) ? start : start + " → " + dueLabel(e, allDay: true)
        }
        if cal.isDate(e, inSameDayAs: d) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.setLocalizedDateFormatFromTemplate("HHmm")
            return start + "–" + f.string(from: e)
        }
        return start + " → " + dueLabel(e, allDay: false)
    }

    private var linked: Bool {
        item.kind == "event" ? item.eventId != nil : item.reminderId != nil
    }

    private var overdue: Bool {
        guard let d = item.due, !item.done else { return false }
        return (item.allDay ?? false) ? d < Calendar.current.startOfDay(for: Date()) : d < Date()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle("", isOn: $item.done)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
            if editing {
                // Mode édition : on voit le Markdown brut
                TextField("", text: $item.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = false }
            } else {
                // Mode lecture : texte mis en forme, liens cliquables
                Text(item.text.isEmpty ? AttributedString(" ") : richText(item.text, forDisplay: true))
                    .strikethrough(item.done)
                    .opacity(item.done ? 0.45 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .environment(\.openURL, OpenURLAction { url in
                        linkClicked = true
                        return isSafeLink(url) ? .systemAction : .discarded
                    })
                    .simultaneousGesture(TapGesture().onEnded {
                        // Un clic sur un lien l'ouvre ; ailleurs, il passe en édition
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if linkClicked { linkClicked = false } else { startEditing() }
                        }
                    })
                    .help("Cliquer pour modifier")
            }
            if let d = item.due {
                Button { showDue = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: linked ? (item.kind == "event" ? "calendar" : "checklist") : "exclamationmark.triangle")
                        Text(dueText(d))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(overdue ? .red : .black)
                    .opacity(item.done ? 0.35 : (overdue ? 0.8 : 0.5))
                }
                .buttonStyle(.plain)
                .help(linked ? (item.kind == "event" ? "Rendez-vous dans Calendrier" : "Rappel (visible dans Calendrier)") + " — cliquer pour modifier"
                            : "Pas encore dans Calendrier")
            }
            }
            Button { showDue = true } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.due == nil && (hover || hoverCal || showDue) ? (hoverCal ? 0.8 : 0.5) : 0)
            .onHover { hoverCal = $0 }
            .help("Ajouter une date (Calendrier)")
            if !groups.isEmpty {
                Menu {
                    Button(mark(item.group == nil) + "Sans rubrique") { onMove(nil) }
                    Divider()
                    ForEach(groups) { g in
                        Button(mark(item.group == g.id) + (g.name.isEmpty ? "Sans nom" : g.name)) { onMove(g.id) }
                    }
                } label: {
                    Image(systemName: "folder").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(2)
                .contentShape(Rectangle())
                .opacity(hover || hoverFolder ? (hoverFolder ? 0.8 : 0.5) : 0)
                .onHover { hoverFolder = $0 }
                .help("Ranger dans une rubrique")
            }
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hoverDelete ? 0.75 : 0.25)
            .onHover { hoverDelete = $0 }
            .help("Supprimer la tâche")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())   // toute la ligne (espaces et icônes masquées compris) déclenche le survol
        .onHover { hover = $0 }
        .popover(isPresented: $showDue, arrowEdge: .bottom) {
            DueEditor(item: $item) { showDue = false }
        }
        .onChange(of: focused) { _, f in if !f { editing = false } }
    }

    private func startEditing() {
        editing = true
        DispatchQueue.main.async { focused = true }
    }
}

/// Markdown en ligne (**gras**, *italique*, ~~barré~~, `code`, [lien](url))
/// + détection automatique des adresses web collées telles quelles.
func richText(_ s: String, forDisplay: Bool = false) -> AttributedString {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let plain = String(a.characters)
        for m in det.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = m.url, let r = Range(m.range, in: plain) else { continue }
            let lower = a.index(a.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let upper = a.index(lower, offsetByCharacters: plain.distance(from: r.lowerBound, to: r.upperBound))
            if a[lower..<upper].link == nil { a[lower..<upper].link = url }
        }
    }
    guard forDisplay else { return a }
    // Sécurité : seuls http, https et mailto restent cliquables, et si le texte
    // d'un lien ne montre pas sa vraie destination, on l'affiche à côté en gris.
    var links: [(Range<AttributedString.Index>, URL)] = []
    for (u, r) in a.runs[\.link] { if let u = u { links.append((r, u)) } }
    for (r, u) in links.reversed() {
        guard isSafeLink(u) else { a[r].link = nil; continue }
        let target = linkTarget(u)
        let label = String(a[r].characters).lowercased()
        if !target.isEmpty && !label.contains(target.lowercased()) {
            var tag = AttributedString(" (\(target))")
            tag.foregroundColor = .gray
            tag.font = .system(size: 10)
            a.insert(tag, at: r.upperBound)
        }
    }
    return a
}

func isSafeLink(_ u: URL) -> Bool {
    ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "")
}

/// Domaine (sans « www. ») ou adresse mail visée par un lien
func linkTarget(_ u: URL) -> String {
    if u.scheme?.lowercased() == "mailto" {
        return String(u.absoluteString.dropFirst("mailto:".count))
    }
    var h = u.host ?? u.absoluteString
    if h.lowercased().hasPrefix("www.") { h = String(h.dropFirst(4)) }
    return h
}

struct AddRow: View {
    var placeholder = "Ajouter une tâche…"
    var onAdd: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0.35)
                .frame(width: 14)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    onAdd(t)
                    text = ""
                    focused = true
                }
        }
    }
}

struct GroupHeader: View {
    @Binding var group: TaskGroup
    var done: Int
    var total: Int
    var isFirst: Bool
    var isLast: Bool
    var onMove: (Int) -> Void
    var onDelete: (Bool) -> Void   // true = supprimer aussi les tâches

    var body: some View {
        HStack(spacing: 4) {
            Button { group.collapsed.toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.5)
            .help(group.collapsed ? "Déplier" : "Replier")

            TextField("Rubrique", text: $group.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold))

            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.system(size: 10))
                    .opacity(0.45)
            }

            Menu {
                Button("Monter") { onMove(-1) }.disabled(isFirst)
                Button("Descendre") { onMove(1) }.disabled(isLast)
                Divider()
                Button("Supprimer la rubrique (garder les tâches)") { onDelete(false) }
                Button("Supprimer la rubrique et ses tâches") { onDelete(true) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.45)
            .help("Options de la rubrique")
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
        }
    }
}

struct NoteView: View {
    @ObservedObject var model: NoteModel
    @State private var addingGroup = false
    @State private var newGroupName = ""
    @FocusState private var groupFocused: Bool

    private var doneCount: Int { model.data.items.filter { $0.done }.count }

    var body: some View {
        let p = palettes[model.data.color % palettes.count]
        let loose = model.data.items.filter { model.data.isLoose($0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Sans titre", text: $model.data.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                if !model.data.items.isEmpty {
                    Text("\(doneCount)/\(model.data.items.count)")
                        .font(.system(size: 11))
                        .opacity(0.45)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    // Tâches sans rubrique
                    ForEach(loose) { item in row(item) }
                    if model.data.sections.isEmpty || !loose.isEmpty {
                        AddRow { addTask($0, to: nil) }
                    }

                    // Rubriques
                    ForEach($model.data.sections) { $g in
                        section($g)
                    }

                    if addingGroup {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 10, weight: .semibold))
                                .opacity(0.5)
                                .frame(width: 14)
                            TextField("Nom de la rubrique", text: $newGroupName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .bold))
                                .focused($groupFocused)
                                .onSubmit(addGroup)
                                .onExitCommand { addingGroup = false; newGroupName = "" }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button { startGroup() } label: {
                    Label("Rubrique", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Nouvelle rubrique (⇧⌘N)")
                Spacer()
                if doneCount > 0 {
                    Button("Effacer les tâches faites") { clearDone() }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            .opacity(0.5)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: p.body))
        .environment(\.colorScheme, .light)
        .onChange(of: model.groupRequest) { _, _ in startGroup() }
    }

    @ViewBuilder
    private func section(_ g: Binding<TaskGroup>) -> some View {
        let grp = g.wrappedValue
        let its = model.data.items.filter { $0.group == grp.id }
        GroupHeader(group: g,
                    done: its.filter { $0.done }.count,
                    total: its.count,
                    isFirst: grp.id == model.data.sections.first?.id,
                    isLast: grp.id == model.data.sections.last?.id,
                    onMove: { moveGroup(grp.id, by: $0) },
                    onDelete: { deleteGroup(grp.id, withTasks: $0) })
        if !grp.collapsed {
            ForEach(its) { item in row(item) }
            AddRow { addTask($0, to: grp.id) }
        }
    }

    private func row(_ item: TodoItem) -> some View {
        ItemRow(item: binding(item.id),
                groups: model.data.sections,
                onMove: { move(item.id, to: $0) },
                onDelete: { delete(item.id) })
    }

    private func binding(_ id: UUID) -> Binding<TodoItem> {
        Binding(
            get: { model.data.items.first { $0.id == id } ?? TodoItem(id: id, text: "") },
            set: { v in
                if let i = model.data.items.firstIndex(where: { $0.id == id }) {
                    model.data.items[i] = v
                }
            })
    }

    // MARK: Actions

    private func addTask(_ t: String, to g: UUID?) {
        // « # Nom » crée une rubrique (comme un titre Markdown)
        if t.hasPrefix("# ") {
            let name = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { model.data.sections.append(TaskGroup(name: name)) }
            return
        }
        model.data.items.append(TodoItem(text: t, group: g))
    }

    private func move(_ id: UUID, to g: UUID?) {
        guard let i = model.data.items.firstIndex(where: { $0.id == id }) else { return }
        model.data.items[i].group = g
    }

    private func startGroup() {
        addingGroup = true
        DispatchQueue.main.async { groupFocused = true }
    }

    private func addGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { model.data.sections.append(TaskGroup(name: name)) }
        newGroupName = ""
        addingGroup = false
    }

    private func moveGroup(_ id: UUID, by d: Int) {
        var s = model.data.sections
        guard let i = s.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard s.indices.contains(j) else { return }
        s.swapAt(i, j)
        model.data.sections = s
    }

    private func deleteGroup(_ id: UUID, withTasks: Bool) {
        DispatchQueue.main.async {
            var d = model.data
            if withTasks {
                d.items.removeAll { $0.group == id }
            } else {
                for i in d.items.indices where d.items[i].group == id { d.items[i].group = nil }
            }
            d.sections.removeAll { $0.id == id }
            model.data = d
        }
    }

    private func delete(_ id: UUID) {
        DispatchQueue.main.async {
            model.data.items.removeAll { $0.id == id }
        }
    }

    private func clearDone() {
        DispatchQueue.main.async {
            model.data.items.removeAll { $0.done }
        }
    }
}

// MARK: - Fenêtre d'une note

final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let model: NoteModel
    weak var app: AppDelegate?
    private var styleSub: AnyCancellable?
    let pomodoro: Pomodoro

    init(model: NoteModel, app: AppDelegate) {
        self.model = model
        self.app = app
        let d = model.data
        self.pomodoro = Pomodoro(work: d.pomoWork ?? 25, rest: d.pomoRest ?? 5)
        let win = NSWindow(contentRect: NSRect(x: d.x, y: d.y, width: d.w, height: d.h),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .aqua)
        win.minSize = NSSize(width: 180, height: 110)
        win.isReleasedWhenClosed = false
        win.title = d.title.isEmpty ? "Note" : d.title
        super.init(window: win)
        win.delegate = self

        let hosting = NSHostingView(rootView: NoteView(model: model))
        hosting.sizingOptions = []
        win.contentView = hosting

        // Pomodoro dans la barre du haut, à droite
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .trailing
        let pomoView = NSHostingView(rootView: PomodoroView(p: pomodoro, model: model))
        pomoView.frame = NSRect(x: 0, y: 0, width: 136, height: 28)
        acc.view = pomoView
        win.addTitlebarAccessoryViewController(acc)

        pomodoro.onSettings = { [weak self] in
            guard let self = self else { return }
            self.model.data.pomoWork = self.pomodoro.workMin
            self.model.data.pomoRest = self.pomodoro.restMin
        }

        styleSub = model.$data
            .map { ($0.color, $0.floating, $0.title, $0.opacity ?? 1) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] v in self?.applyStyle(color: v.0, floating: v.1, title: v.2, alpha: v.3) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Repli en barre (quand on passe à une autre app)

    private(set) var collapsed = false

    func setCollapsed(_ c: Bool) {
        guard let win = window, c != collapsed else { return }
        if c {
            let bar = win.frame.height - win.contentLayoutRect.height
            collapsed = true
            win.styleMask.remove(.resizable)
            win.minSize = NSSize(width: 180, height: bar)
            win.contentView?.isHidden = true   // sinon le contenu déborde sous la barre
            let f = win.frame
            win.setFrame(NSRect(x: f.minX, y: f.maxY - bar, width: f.width, height: bar),
                         display: true, animate: true)
            win.titleVisibility = .visible
        } else {
            let d = model.data
            win.titleVisibility = .hidden
            win.setFrame(NSRect(x: d.x, y: d.y, width: d.w, height: d.h), display: true, animate: true)
            collapsed = false
            win.contentView?.isHidden = false
            win.minSize = NSSize(width: 180, height: 110)
            win.styleMask.insert(.resizable)
        }
    }

    func applyStyle(color: Int, floating: Bool, title: String, alpha: Double) {
        if !floating && collapsed { setCollapsed(false) }
        window?.alphaValue = CGFloat(max(0.2, min(1, alpha)))
        let p = palettes[color % palettes.count]
        window?.backgroundColor = p.bar
        window?.hidesOnDeactivate = false
        window?.level = floating ? .floating : .normal
        window?.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
        if floating { window?.orderFrontRegardless() }
        window?.title = title.isEmpty ? "Note" : title   // utile pour le menu Fenêtre
    }

    func windowDidMove(_ notification: Notification) { syncFrame() }
    func windowDidResize(_ notification: Notification) { syncFrame() }

    private func syncFrame() {
        guard let f = window?.frame else { return }
        if collapsed {
            // Repliée : on mémorise la position, en gardant la taille dépliée
            model.data.x = f.origin.x
            model.data.y = f.maxY - model.data.h
            return
        }
        model.data.x = f.origin.x
        model.data.y = f.origin.y
        model.data.w = f.size.width
        model.data.h = f.size.height
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let d = model.data
        if d.items.isEmpty && d.title.isEmpty && d.sections.isEmpty {
            app?.remove(self)
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Supprimer cette note ?"
        alert.informativeText = "Ses tâches seront définitivement effacées."
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn {
            app?.remove(self)
            return true
        }
        return false
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = Store()
    var controllers: [NoteWindowController] = []

    var keyController: NoteWindowController? {
        controllers.first { $0.window === NSApp.keyWindow }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        var notes = store.load()
        if notes.isEmpty && !demoMode { notes = [welcomeNote()] }
        for d in notes { open(NoteModel(d)) }
        if !demoMode { CalendarSync.shared.prime(store.models) }
        if let dir = screenshotDir { takeScreenshots(in: dir) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidResign(_:)),
                       name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Notes épinglées : repliées en barre quand une autre app est au premier plan
    var autoCollapse: Bool {
        get { !UserDefaults.standard.bool(forKey: "noAutoCollapse") }
        set { UserDefaults.standard.set(!newValue, forKey: "noAutoCollapse") }
    }

    @objc func appDidResign(_ n: Notification) {
        guard autoCollapse else { return }
        controllers.filter { $0.model.data.floating }.forEach { $0.setCollapsed(true) }
    }

    @objc func appDidBecomeActive(_ n: Notification) {
        controllers.forEach { $0.setCollapsed(false) }
        guard !demoMode else { return }
        CalendarSync.shared.pull(store.models)
        CalendarSync.shared.reconcile(store.models)
    }

    @objc func syncCalendar(_ sender: Any?) {
        CalendarSync.shared.retry(store.models)
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        keyController?.model.data.opacity = (sender.tag == 100) ? nil : Double(sender.tag) / 100
    }

    @objc func toggleAutoCollapse(_ sender: Any?) {
        autoCollapse.toggle()
    }

    private func takeScreenshots(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Notes dépliées (même si l'app n'est pas au premier plan)
            self.controllers.forEach { $0.setCollapsed(false) }
            for (i, c) in self.controllers.enumerated() {
                if let w = c.window { captureWindow(w, to: dir.appendingPathComponent("mac-note-\(i + 1).png")) }
            }
            // Fenêtre de réglage de la date, pour le rendez-vous de démonstration
            var panel: NSWindow? = nil
            var host: NSView? = nil
            let event = self.controllers.lazy.flatMap { $0.model.data.items }.first { $0.kind == "event" }
            if let it = event {
                let h = NSHostingView(rootView: DueEditor(item: .constant(it), close: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light))
                var size = h.fittingSize
                if size.width < 50 || size.height < 50 { size = NSSize(width: 320, height: 480) }
                let p = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                p.isReleasedWhenClosed = false
                p.title = "Date de la tâche"
                p.contentView = h
                h.frame = NSRect(origin: .zero, size: size)
                p.orderFrontRegardless()
                panel = p
                host = h
                print("  fenêtre de date : \(Int(size.width))×\(Int(size.height))")
            } else {
                print("  ✗ aucune tâche « rendez-vous » dans les notes de démo")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let h = host, !captureView(h, to: dir.appendingPathComponent("mac-date.png")),
                   let p = panel {
                    captureWindow(p, to: dir.appendingPathComponent("mac-date.png"))  // seconde méthode
                }
                panel?.close()
                guard let pinned = self.controllers.first(where: { $0.model.data.floating }) else {
                    NSApp.terminate(nil); return
                }
                pinned.setCollapsed(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let w = pinned.window { captureWindow(w, to: dir.appendingPathComponent("mac-collapsed.png")) }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func welcomeNote() -> NoteData {
        var d = NoteData()
        if let s = NSScreen.main?.visibleFrame {
            d.x = s.midX - 130
            d.y = s.midY - 125
        }
        d.title = "À faire"
        d.items = [
            TodoItem(text: "⌘N pour créer une nouvelle note"),
            TodoItem(text: "Menu Note pour changer la couleur (⌘1 à ⌘6)"),
            TodoItem(text: "La punaise (ou ⌥⌘P) garde une note au premier plan"),
            TodoItem(text: "⇧⌘N ou « # Nom » pour créer une rubrique"),
            TodoItem(text: "**Gras** (⌘B), *italique* (⌘I), [lien](https://www.apple.com/fr/) (⌘K)"),
            TodoItem(text: "Survole une tâche → icône calendrier pour la dater"),
            TodoItem(text: "Cocher une tâche", done: true),
        ]
        return d
    }

    func open(_ m: NoteModel) {
        store.add(m)
        let c = NoteWindowController(model: m, app: self)
        controllers.append(c)
        c.showWindow(nil)
    }

    func remove(_ c: NoteWindowController) {
        store.remove(c.model)
        controllers.removeAll { $0 === c }
    }

    @objc func newNote(_ sender: Any?) {
        var d = NoteData()
        if let k = keyController, let f = k.window?.frame {
            d.x = f.origin.x + 28
            d.y = f.origin.y - 28
            d.color = k.model.data.color
        } else if let s = NSScreen.main?.visibleFrame {
            d.x = s.midX - 130
            d.y = s.midY - 125
        }
        open(NoteModel(d))
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func setColor(_ sender: NSMenuItem) {
        keyController?.model.data.color = sender.tag
    }

    @objc func toggleFloating(_ sender: Any?) {
        keyController?.model.data.floating.toggle()
    }

    @objc func clearDone(_ sender: Any?) {
        keyController?.model.data.items.removeAll { $0.done }
    }

    // MARK: Format (agit sur le champ en cours d'édition)

    private var fieldEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private func wrap(_ left: String, _ right: String) {
        guard let tv = fieldEditor else { return }
        let r = tv.selectedRange()
        let sel = (tv.string as NSString).substring(with: r)
        let l = (left as NSString).length, rl = (right as NSString).length
        // Déjà formaté → on retire la mise en forme
        if sel.hasPrefix(left) && sel.hasSuffix(right) && (sel as NSString).length >= l + rl {
            let inner = String(sel.dropFirst(left.count).dropLast(right.count))
            tv.insertText(inner, replacementRange: r)
            tv.setSelectedRange(NSRange(location: r.location, length: (inner as NSString).length))
            return
        }
        tv.insertText(left + sel + right, replacementRange: r)
        tv.setSelectedRange(NSRange(location: r.location + l, length: r.length))
    }

    @objc func formatBold(_ sender: Any?)   { wrap("**", "**") }
    @objc func formatItalic(_ sender: Any?) { wrap("*", "*") }
    @objc func formatStrike(_ sender: Any?) { wrap("~~", "~~") }
    @objc func formatCode(_ sender: Any?)   { wrap("`", "`") }

    @objc func formatLink(_ sender: Any?) {
        guard let tv = fieldEditor else { return }
        let r = tv.selectedRange()
        let sel = (tv.string as NSString).substring(with: r)
        // Si le presse-papiers contient une adresse web, on l'utilise directement
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasURL = clip.hasPrefix("http://") || clip.hasPrefix("https://")
        let url = hasURL ? clip : "https://"
        let label = sel.isEmpty ? "lien" : sel
        tv.insertText("[\(label)](\(url))", replacementRange: r)
        let labelLen = (label as NSString).length
        if !hasURL {
            // on sélectionne « https:// » pour taper/coller l'adresse
            tv.setSelectedRange(NSRange(location: r.location + labelLen + 3, length: (url as NSString).length))
        } else if sel.isEmpty {
            // on sélectionne « lien » pour le renommer
            tv.setSelectedRange(NSRange(location: r.location + 1, length: labelLen))
        }
    }

    @objc func newGroup(_ sender: Any?) {
        keyController?.model.groupRequest += 1
    }

    @objc func showAll(_ sender: Any?) {
        controllers.forEach { $0.window?.orderFront(nil) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let k = keyController
        switch item.action {
        case #selector(setColor(_:)):
            item.state = (k?.model.data.color == item.tag) ? .on : .off
            return k != nil
        case #selector(toggleFloating(_:)):
            item.state = (k?.model.data.floating ?? false) ? .on : .off
            return k != nil
        case #selector(newGroup(_:)):
            return k != nil
        case #selector(setOpacity(_:)):
            let cur = Int(((k?.model.data.opacity ?? 1) * 100).rounded())
            item.state = (k != nil && cur == item.tag) ? .on : .off
            return k != nil
        case #selector(toggleAutoCollapse(_:)):
            item.state = autoCollapse ? .on : .off
            return true
        case #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatStrike(_:)),
             #selector(formatCode(_:)), #selector(formatLink(_:)):
            return fieldEditor != nil
        case #selector(clearDone(_:)):
            return k?.model.data.items.contains { $0.done } ?? false
        default:
            return true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { newNote(nil) } else { showAll(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: Menus

    private func addMenu(_ main: NSMenu, _ m: NSMenu) {
        let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        item.submenu = m
        main.addItem(item)
    }

    func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Post-it")
        appMenu.addItem(withTitle: "À propos de Post-it",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Post-it", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Post-it", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(main, appMenu)

        let file = NSMenu(title: "Fichier")
        file.addItem(withTitle: "Nouvelle note", action: #selector(newNote(_:)), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Supprimer la note", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addMenu(main, file)

        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu(main, edit)

        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Gras", action: #selector(formatBold(_:)), keyEquivalent: "b").target = self
        format.addItem(withTitle: "Italique", action: #selector(formatItalic(_:)), keyEquivalent: "i").target = self
        let st = format.addItem(withTitle: "Barré", action: #selector(formatStrike(_:)), keyEquivalent: "x")
        st.keyEquivalentModifierMask = [.command, .shift]
        st.target = self
        format.addItem(withTitle: "Code", action: #selector(formatCode(_:)), keyEquivalent: "e").target = self
        format.addItem(.separator())
        format.addItem(withTitle: "Lien…", action: #selector(formatLink(_:)), keyEquivalent: "k").target = self
        addMenu(main, format)

        let note = NSMenu(title: "Note")
        for (i, p) in palettes.enumerated() {
            let it = note.addItem(withTitle: p.name, action: #selector(setColor(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i
            it.target = self
        }
        note.addItem(.separator())
        let fl = note.addItem(withTitle: "Toujours au premier plan", action: #selector(toggleFloating(_:)), keyEquivalent: "p")
        fl.keyEquivalentModifierMask = [.command, .option]
        fl.target = self
        let opMenu = NSMenu(title: "Transparence")
        for v in opacityLevels {
            let it = opMenu.addItem(withTitle: "\(v) %", action: #selector(setOpacity(_:)), keyEquivalent: "")
            it.tag = v
            it.target = self
        }
        let opItem = note.addItem(withTitle: "Transparence", action: nil, keyEquivalent: "")
        opItem.submenu = opMenu
        note.addItem(withTitle: "Synchroniser avec Calendrier", action: #selector(syncCalendar(_:)), keyEquivalent: "").target = self
        note.addItem(withTitle: "Replier les notes épinglées hors de Post-it",
                     action: #selector(toggleAutoCollapse(_:)), keyEquivalent: "").target = self
        let ng = note.addItem(withTitle: "Nouvelle rubrique", action: #selector(newGroup(_:)), keyEquivalent: "n")
        ng.keyEquivalentModifierMask = [.command, .shift]
        ng.target = self
        note.addItem(withTitle: "Effacer les tâches faites", action: #selector(clearDone(_:)), keyEquivalent: "").target = self
        addMenu(main, note)

        let win = NSMenu(title: "Fenêtre")
        win.addItem(withTitle: "Tout afficher", action: #selector(showAll(_:)), keyEquivalent: "").target = self
        addMenu(main, win)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

// MARK: - Lancement

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
