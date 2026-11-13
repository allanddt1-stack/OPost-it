#!/usr/bin/env python3
"""
OPost-it — notes de tâches façon Stickies, pour Windows et Linux (fonctionne aussi sur macOS).

Chaque note est une petite fenêtre colorée : tâches à cocher, rubriques, mise en forme
Markdown, pomodoro, dates avec export vers n'importe quel agenda (.ics).

Données : notes.json dans le dossier de données de l'utilisateur
  Windows : %APPDATA%/Post-it/Post-it      Linux : ~/.local/share/Post-it/Post-it
Licence MIT.
"""
from __future__ import annotations

import datetime as dt
import html
import json
import os
import re
import sys
import tempfile
import uuid
from urllib.parse import urlparse

from PySide6.QtCore import QDateTime, QLockFile, QSettings, QStandardPaths, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import (QColor, QDesktopServices, QGuiApplication, QIcon, QKeySequence, QPainter,
                           QPainterPath, QPen, QPixmap, QShortcut)
from PySide6.QtWidgets import (QApplication, QCheckBox, QDateTimeEdit, QDialog, QFileDialog,
                               QHBoxLayout, QLabel, QLineEdit, QMenu, QMessageBox, QPushButton,
                               QScrollArea, QSizeGrip, QSizePolicy, QStackedWidget,
                               QSystemTrayIcon, QToolButton, QVBoxLayout, QWidget)

APP_NAME = "Post-it"        # nom historique : sert au dossier de données, ne pas changer
DISPLAY_NAME = "OPost-it"

# Mode démo (python postit.py --demo) : notes fictives dans un dossier temporaire,
# tes vraies notes ne sont ni lues ni modifiées, rien n'est exporté vers l'agenda.
DEMO = "--demo" in sys.argv

# (nom, fond de la note, barre du haut)
PALETTES = [
    ("Jaune", "#FEF69A", "#F1E25F"),
    ("Bleu", "#BFE5FB", "#93D0F5"),
    ("Vert", "#CDF3B6", "#A6E386"),
    ("Rose", "#FBCADF", "#F5A3C6"),
    ("Violet", "#E0CDFB", "#C5A5F5"),
    ("Gris", "#EAEAEA", "#D0D0D0"),
]
OPACITY_LEVELS = [100, 90, 80, 70, 60, 50, 40]
WORK_CHOICES = [15, 20, 25, 30, 45, 50, 60]
REST_CHOICES = [5, 10, 15, 20]

JOURS = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]
MOIS = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]


def new_id() -> str:
    return str(uuid.uuid4())


# ───────────────────────────── Données ─────────────────────────────

def make_note(**kw) -> dict:
    n = {"id": new_id(), "title": "", "color": 0, "x": 200, "y": 200, "w": 280, "h": 320,
         "floating": False, "opacity": 1.0, "items": [], "groups": [], "pomoWork": 25, "pomoRest": 5}
    n.update(kw)
    return n


def make_item(text: str, group: str | None = None, **kw) -> dict:
    it = {"id": new_id(), "text": text, "done": False, "group": group,
          "due": None, "end": None, "allDay": False}
    it.update(kw)
    return it


def normalize_note(n: dict) -> dict:
    """Complète une note lue sur disque (fichiers anciens ou modifiés à la main)."""
    base = make_note()
    base.update({k: v for k, v in n.items() if k in base or k == "id"})
    base["items"] = [dict(make_item(""), **i) for i in n.get("items", []) if isinstance(i, dict)]
    base["groups"] = [dict({"id": new_id(), "name": "", "collapsed": False}, **g)
                      for g in n.get("groups", []) if isinstance(g, dict)]
    return base


def parse_dt(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s)
    except ValueError:
        return None


def item_start(it: dict) -> dt.datetime | None:
    return parse_dt(it.get("due"))


def item_end(it: dict) -> dt.datetime | None:
    start = item_start(it)
    if start is None:
        return None
    end = parse_dt(it.get("end"))
    if it.get("allDay"):
        return max(end or start, start)
    if end and end > start:
        return end
    return start + dt.timedelta(minutes=30)


def fr_day(d: dt.datetime) -> str:
    today = dt.date.today()
    if d.date() == today:
        return "Aujourd'hui"
    if d.date() == today + dt.timedelta(days=1):
        return "Demain"
    if d.date() == today - dt.timedelta(days=1):
        return "Hier"
    s = f"{JOURS[d.weekday()]} {d.day} {MOIS[d.month - 1]}"
    return s if d.year == today.year else f"{s} {d.year}"


def due_text(it: dict) -> str:
    start, end = item_start(it), item_end(it)
    if start is None:
        return ""
    if it.get("allDay"):
        if end.date() == start.date():
            return fr_day(start)
        return f"{fr_day(start)} → {fr_day(end)}"
    s = f"{fr_day(start)}, {start:%H:%M}"
    if end.date() == start.date():
        return f"{s}–{end:%H:%M}"
    return f"{s} → {fr_day(end)}, {end:%H:%M}"


def is_overdue(it: dict) -> bool:
    start = item_start(it)
    if start is None or it.get("done"):
        return False
    if it.get("allDay"):
        return start.date() < dt.date.today()
    return start < dt.datetime.now()


# ───────────────────────────── Markdown (sous-ensemble sûr) ─────────────────────────────

SAFE_SCHEMES = ("http", "https", "mailto")


def is_safe_link(url: str) -> bool:
    return urlparse(url).scheme.lower() in SAFE_SCHEMES


def link_target(url: str) -> str:
    p = urlparse(url)
    if p.scheme.lower() == "mailto":
        return p.path
    host = p.netloc or url
    return host[4:] if host.lower().startswith("www.") else host


def _inline(s: str) -> str:
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"<i>\1</i>", s)
    s = re.sub(r"~~(.+?)~~", r"<s>\1</s>", s)
    return s


def _link_html(label_html: str, url: str, label_plain: str) -> str:
    # Seuls http, https et mailto sont cliquables ; si le texte ne montre pas
    # la vraie destination, on l'affiche à côté en gris (anti-hameçonnage).
    if not is_safe_link(url):
        return label_html
    target = link_target(url)
    extra = ""
    if target and target.lower() not in label_plain.lower():
        extra = f" <span style='color:#777; font-size:small'>({html.escape(target)})</span>"
    return f"<a href=\"{html.escape(url, quote=True)}\" style='color:#1a5fb4'>{label_html}</a>{extra}"


def md_to_html(text: str) -> str:
    held: list[str] = []

    def hold(s: str) -> str:
        held.append(s)
        return f"\x00{len(held) - 1}\x00"

    t = re.sub(r"`([^`]+)`",
               lambda m: hold("<code style='background:rgba(0,0,0,0.08)'>"
                              f"{html.escape(m.group(1))}</code>"), text)
    t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
               lambda m: hold(_link_html(_inline(m.group(1)), m.group(2), m.group(1))), t)
    t = re.sub(r"(?:https?://|www\.)[^\s<>\"]*[^\s<>\".,;:!?)\]]",
               lambda m: hold(_link_html(html.escape(m.group(0)),
                                         m.group(0) if "://" in m.group(0) else "https://" + m.group(0),
                                         m.group(0))), t)
    t = _inline(t).replace("\n", "<br>")
    return re.sub(r"\x00(\d+)\x00", lambda m: held[int(m.group(1))], t)


def md_to_plain(text: str) -> str:
    t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r"\1", text)
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)
    t = re.sub(r"~~(.+?)~~", r"\1", t)
    t = re.sub(r"`([^`]+)`", r"\1", t)
    t = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"\1", t)
    return t.strip() or "Tâche"


# ───────────────────────────── Export agenda (.ics) ─────────────────────────────

def _ics_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def _fold(line: str) -> str:
    """Coupe les lignes à 75 octets (RFC 5545)."""
    out, cur = [], b""
    for ch in line:
        b = ch.encode("utf-8")
        if len(cur) + len(b) > 75:
            out.append(cur.decode("utf-8"))
            cur = b" " + b
        else:
            cur += b
    out.append(cur.decode("utf-8"))
    return "\r\n".join(out)


def _utc(d: dt.datetime) -> str:
    return d.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def vevent(it: dict) -> list[str]:
    start, end = item_start(it), item_end(it)
    lines = ["BEGIN:VEVENT",
             f"UID:{it['id']}@postit",
             f"SEQUENCE:{it.get('icsSeq', 0)}",
             f"DTSTAMP:{_utc(dt.datetime.now())}",
             f"SUMMARY:{_ics_escape(md_to_plain(it['text']))}",
             "DESCRIPTION:" + _ics_escape("Créé depuis OPost-it")]
    if it.get("allDay"):
        lines.append(f"DTSTART;VALUE=DATE:{start:%Y%m%d}")
        lines.append(f"DTEND;VALUE=DATE:{(end + dt.timedelta(days=1)):%Y%m%d}")
    else:
        lines.append(f"DTSTART:{_utc(start)}")
        lines.append(f"DTEND:{_utc(end)}")
        lines += ["BEGIN:VALARM", "ACTION:DISPLAY",
                  "DESCRIPTION:" + _ics_escape(md_to_plain(it["text"])),
                  "TRIGGER:-PT0M", "END:VALARM"]
    lines.append("END:VEVENT")
    return lines


def make_ics(items: list[dict]) -> str:
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OPost-it//FR", "CALSCALE:GREGORIAN",
             "METHOD:PUBLISH"]
    for it in items:
        lines += vevent(it)
    lines.append("END:VCALENDAR")
    return "\r\n".join(_fold(l) for l in lines) + "\r\n"


# ───────────────────────────── Notes de démonstration ─────────────────────────────

def demo_notes() -> list[dict]:
    def at(days: int, h: int, m: int = 0) -> str:
        d = dt.datetime.combine(dt.date.today() + dt.timedelta(days=days), dt.time(h, m))
        return d.isoformat()

    design, dev = ({"id": new_id(), "name": n, "collapsed": False} for n in ("Design", "Développement"))
    a = make_note(title="Projet site web", color=0, x=120, y=120, w=300, h=400, groups=[design, dev])
    a["items"] = [
        make_item("Valider la **maquette** de l'accueil", design["id"], done=True),
        make_item("Choisir la *palette* de couleurs", design["id"]),
        make_item("Relire la [documentation](https://doc.qt.io)", dev["id"]),
        make_item("Réunion avec l'équipe", dev["id"], due=at(1, 10), end=at(1, 11)),
        make_item("Mettre en ligne la ~~version 1~~ **version 2**", dev["id"],
                  due=at(3, 14), end=at(3, 14, 30)),
    ]
    b = make_note(title="Courses", color=1, x=440, y=300, w=250, h=250, floating=True)
    b["items"] = [make_item("Pain"), make_item("Tomates", done=True),
                  make_item("Fromage"), make_item("Café **en grains**")]
    c = make_note(title="Lectures", color=2, x=440, y=80, w=260, h=200)
    c["items"] = [make_item("*Le Petit Prince*", done=True), make_item("Un roman policier"),
                  make_item("Article sur l'histoire de l'imprimerie")]
    return [a, b, c]


# ───────────────────────────── Sauvegarde ─────────────────────────────

class Store:
    def __init__(self):
        self.dir = (tempfile.mkdtemp(prefix="post-it-demo-") if DEMO
                    else QStandardPaths.writableLocation(QStandardPaths.AppDataLocation))
        os.makedirs(self.dir, exist_ok=True)
        try:
            os.chmod(self.dir, 0o700)
        except OSError:
            pass
        self.path = os.path.join(self.dir, "notes.json")
        self.notes: list[dict] = []
        self._timer = QTimer(singleShot=True, interval=400)
        self._timer.timeout.connect(self.save_now)
        self._error_shown = False

    def load(self) -> list[dict]:
        if DEMO:
            return demo_notes()
        if not os.path.exists(self.path):
            return []
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, list):
                raise ValueError("format inattendu")
            return [normalize_note(n) for n in data if isinstance(n, dict)]
        except (OSError, ValueError) as e:
            # On ne réécrit jamais par-dessus un fichier illisible : on le met de côté
            backup = self.path + f".illisible-{dt.datetime.now():%Y%m%d-%H%M%S}"
            try:
                os.replace(self.path, backup)
            except OSError:
                backup = "(impossible de le déplacer)"
            QMessageBox.warning(None, DISPLAY_NAME,
                                "Le fichier des notes était illisible ; il a été mis de côté :\n"
                                f"{backup}\n\n{e}")
            return []

    def schedule(self):
        self._timer.start()

    def save_now(self):
        try:
            data = json.dumps(self.notes, ensure_ascii=False, indent=2)
            fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".notes-", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(data)
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
            os.replace(tmp, self.path)  # écriture atomique
            self._error_shown = False
        except Exception as e:  # noqa: BLE001 — on prévient l'utilisateur quoi qu'il arrive
            if not self._error_shown:
                self._error_shown = True
                QMessageBox.critical(None, DISPLAY_NAME,
                                     "Impossible d'enregistrer tes notes.\n"
                                     "Tes dernières modifications risquent d'être perdues.\n\n" + str(e))


# ───────────────────────────── Icône ─────────────────────────────

def app_icon() -> QIcon:
    # L'icône du projet si elle est là (dépôt ou exécutable PyInstaller), sinon on la dessine
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(base, "assets", "icon.png")
    if os.path.exists(path):
        return QIcon(path)
    pm = QPixmap(256, 256)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(24, 24, 208, 208, 28, 28)
    p.fillPath(path, QColor("#FEF69A"))
    top = QPainterPath()
    top.addRoundedRect(24, 24, 208, 52, 28, 28)
    top.addRect(24, 50, 208, 26)
    p.fillPath(top.simplified(), QColor("#F1E25F"))
    p.setPen(QPen(QColor(0, 0, 0, 110), 10, Qt.SolidLine, Qt.RoundCap))
    for i, w in enumerate((120, 96, 132)):
        y = 112 + i * 36
        p.drawRect(60, y - 9, 18, 18)
        p.drawLine(96, y, 96 + w, y)
    p.end()
    return QIcon(pm)


# ───────────────────────────── Pomodoro ─────────────────────────────

class Pomodoro:
    def __init__(self, work: int, rest: int, on_change, on_end):
        self.work, self.rest = work, rest
        self.phase = "work"
        self.remaining = work * 60
        self.running = False
        self._end: dt.datetime | None = None
        self._timer = QTimer(interval=500)
        self._timer.timeout.connect(self._tick)
        self.on_change, self.on_end = on_change, on_end

    def label(self) -> str:
        return f"{self.remaining // 60:02d}:{self.remaining % 60:02d}"

    def toggle(self):
        if self.running:
            self._timer.stop()
            self.running = False
        else:
            self._end = dt.datetime.now() + dt.timedelta(seconds=self.remaining)
            self.running = True
            self._timer.start()
        self.on_change()

    def reset(self):
        self._timer.stop()
        self.running = False
        self.phase = "work"
        self.remaining = self.work * 60
        self.on_change()

    def skip(self):
        self._timer.stop()
        self.running = False
        self.phase = "rest" if self.phase == "work" else "work"
        self.remaining = (self.work if self.phase == "work" else self.rest) * 60
        self.on_change()

    def set_work(self, m: int):
        self.work = m
        if not self.running and self.phase == "work":
            self.remaining = m * 60
        self.on_change()

    def set_rest(self, m: int):
        self.rest = m
        if not self.running and self.phase == "rest":
            self.remaining = m * 60
        self.on_change()

    def _tick(self):
        left = int((self._end - dt.datetime.now()).total_seconds() + 0.999)
        if left > 0:
            if left != self.remaining:
                self.remaining = left
                self.on_change()
            return
        finished = self.phase
        self.skip()
        self.on_end(finished)


# ───────────────────────────── Petits widgets ─────────────────────────────

def tool_button(text: str, tip: str = "", size: int = 22) -> QToolButton:
    b = QToolButton()
    b.setText(text)
    b.setToolTip(tip)
    b.setAutoRaise(True)
    b.setCursor(Qt.PointingHandCursor)
    b.setFixedHeight(size)
    b.setMinimumWidth(size)
    return b


class ClickLabel(QLabel):
    """Texte mis en forme : un clic sur un lien l'ouvre, ailleurs il passe en édition."""
    clicked = Signal()

    def __init__(self, *a):
        super().__init__(*a)
        self._hover = ""
        self.linkHovered.connect(self._set_hover)

    def _set_hover(self, link: str):
        self._hover = link

    def mouseReleaseEvent(self, e):
        super().mouseReleaseEvent(e)
        if e.button() == Qt.LeftButton and not self._hover:
            self.clicked.emit()


class FormatLineEdit(QLineEdit):
    """Champ texte avec raccourcis Markdown : Ctrl+B, Ctrl+I, Ctrl+Maj+X, Ctrl+E, Ctrl+K."""
    cancelled = Signal()

    def keyPressEvent(self, e):
        ctrl = e.modifiers() & Qt.ControlModifier
        shift = e.modifiers() & Qt.ShiftModifier
        k = e.key()
        if ctrl and not shift and k == Qt.Key_B:
            return self.wrap("**", "**")
        if ctrl and not shift and k == Qt.Key_I:
            return self.wrap("*", "*")
        if ctrl and shift and k == Qt.Key_X:
            return self.wrap("~~", "~~")
        if ctrl and not shift and k == Qt.Key_E:
            return self.wrap("`", "`")
        if ctrl and not shift and k == Qt.Key_K:
            return self.make_link()
        if k == Qt.Key_Escape:
            self.cancelled.emit()
            return
        super().keyPressEvent(e)

    def _selection(self) -> tuple[int, str]:
        if self.hasSelectedText():
            return self.selectionStart(), self.selectedText()
        return self.cursorPosition(), ""

    def wrap(self, left: str, right: str):
        start, sel = self._selection()
        if sel.startswith(left) and sel.endswith(right) and len(sel) >= len(left) + len(right):
            inner = sel[len(left):len(sel) - len(right)]
            self.insert(inner)
            self.setSelection(start, len(inner))
            return
        self.insert(left + sel + right)
        self.setSelection(start + len(left), len(sel))

    def make_link(self):
        start, sel = self._selection()
        clip = (QGuiApplication.clipboard().text() or "").strip()
        has_url = clip.startswith(("http://", "https://"))
        url = clip if has_url else "https://"
        label = sel or "lien"
        self.insert(f"[{label}]({url})")
        if not has_url:
            self.setSelection(start + len(label) + 3, len(url))
        elif not sel:
            self.setSelection(start + 1, len(label))


# ───────────────────────────── Dialogue de date ─────────────────────────────

DIALOG_STYLE = """
    QDialog { background: palette(window); }
    QPushButton { border: 1px solid rgba(0,0,0,0.25); border-radius: 5px; padding: 4px 12px;
                  background: white; color: #222; }
    QPushButton:default { background: #2a6fdb; color: white; border-color: #2a6fdb; }
    QPushButton:hover { border-color: rgba(0,0,0,0.5); }
"""


class DueDialog(QDialog):
    def __init__(self, item: dict, parent=None):
        super().__init__(parent)
        self.setStyleSheet(DIALOG_STYLE)
        self.setWindowFlag(Qt.WindowStaysOnTopHint)
        self.setWindowTitle("Date de la tâche")
        self.item = item
        self.removed = False
        settings = QSettings()

        start = item_start(item)
        if start is None:
            start = dt.datetime.combine(dt.date.today() + dt.timedelta(days=1), dt.time(9, 0))
            end = start + dt.timedelta(minutes=30)
        else:
            end = item_end(item)

        lay = QVBoxLayout(self)
        lay.addWidget(QLabel(f"<b>{html.escape(md_to_plain(item['text']))}</b>"))

        self.all_day = QCheckBox("Toute la journée")
        self.all_day.setChecked(bool(item.get("allDay")))
        self.start = QDateTimeEdit(QDateTime(start))
        self.end = QDateTimeEdit(QDateTime(end))
        for w in (self.start, self.end):
            w.setCalendarPopup(True)
        row1, row2 = QHBoxLayout(), QHBoxLayout()
        row1.addWidget(QLabel("Début")), row1.addWidget(self.start, 1)
        row2.addWidget(QLabel("Fin")), row2.addWidget(self.end, 1)
        for r in (row1, row2):
            r.itemAt(0).widget().setFixedWidth(40)
            lay.addLayout(r)
        lay.addWidget(self.all_day)

        self.export = QCheckBox("Ajouter à mon agenda (fichier .ics) en enregistrant")
        self.export.setChecked(settings.value("exportIcs", True, type=bool))
        lay.addWidget(self.export)
        hint = QLabel("Le fichier s'ouvre dans ton application d'agenda par défaut "
                      "(Outlook, Thunderbird, Calendrier…). Il contient une alerte à l'heure de début.")
        hint.setWordWrap(True)
        hint.setStyleSheet("color:#666; font-size:11px")
        lay.addWidget(hint)

        buttons = QHBoxLayout()
        if item_start(item) is not None:
            rm = QPushButton("Retirer la date")
            rm.clicked.connect(self._remove)
            buttons.addWidget(rm)
        buttons.addStretch(1)
        cancel = QPushButton("Annuler")
        cancel.clicked.connect(self.reject)
        ok = QPushButton("Enregistrer")
        ok.setDefault(True)
        ok.clicked.connect(self.accept)
        buttons.addWidget(cancel), buttons.addWidget(ok)
        lay.addLayout(buttons)

        self._span = self.start.dateTime().secsTo(self.end.dateTime())
        self.start.dateTimeChanged.connect(self._start_changed)
        self.end.dateTimeChanged.connect(self._end_changed)
        self.all_day.toggled.connect(self._formats)
        self._formats()

    def _formats(self):
        fmt = "dd/MM/yyyy" if self.all_day.isChecked() else "dd/MM/yyyy  HH:mm"
        for w in (self.start, self.end):
            w.setDisplayFormat(fmt)

    def _start_changed(self, v: QDateTime):
        self.end.blockSignals(True)
        self.end.setDateTime(v.addSecs(max(0, self._span)))
        self.end.blockSignals(False)

    def _end_changed(self, v: QDateTime):
        self._span = self.start.dateTime().secsTo(v)

    def _remove(self):
        self.removed = True
        self.accept()

    def apply(self) -> bool:
        """Écrit le résultat dans la tâche ; renvoie True s'il faut exporter vers l'agenda."""
        QSettings().setValue("exportIcs", self.export.isChecked())
        if self.removed:
            self.item.update(due=None, end=None, allDay=False)
            return False
        start = self.start.dateTime().toPython().replace(second=0, microsecond=0)
        end = self.end.dateTime().toPython().replace(second=0, microsecond=0)
        all_day = self.all_day.isChecked()
        if all_day:
            start = dt.datetime.combine(start.date(), dt.time())
            end = dt.datetime.combine(max(end.date(), start.date()), dt.time())
        elif end <= start:
            end = start + dt.timedelta(minutes=30)
        self.item.update(due=start.isoformat(), end=end.isoformat(), allDay=all_day, alerted=None)
        return self.export.isChecked()


# ───────────────────────────── Ligne de tâche ─────────────────────────────

class ItemRow(QWidget):
    def __init__(self, note_win: "NoteWindow", item: dict):
        super().__init__()
        self.nw, self.item = note_win, item
        self.setAttribute(Qt.WA_Hover)

        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 1, 0, 1)
        lay.setSpacing(5)

        self.check = QCheckBox()
        self.check.setChecked(item["done"])
        self.check.toggled.connect(self._toggle_done)
        lay.addWidget(self.check, 0, Qt.AlignTop)

        col = QVBoxLayout()
        col.setSpacing(1)
        self.stack = QStackedWidget()
        self.label = ClickLabel()
        self.label.setWordWrap(True)
        self.label.setTextFormat(Qt.RichText)
        self.label.setTextInteractionFlags(Qt.LinksAccessibleByMouse)
        self.label.setOpenExternalLinks(False)
        self.label.linkActivated.connect(open_link)
        self.label.clicked.connect(self.start_edit)
        self.label.setToolTip("Cliquer pour modifier")
        self.editor = FormatLineEdit()
        self.editor.editingFinished.connect(self.finish_edit)
        self.editor.cancelled.connect(self.cancel_edit)
        self.stack.addWidget(self.label)
        self.stack.addWidget(self.editor)
        self.stack.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        col.addWidget(self.stack)

        self.badge = ClickLabel()
        self.badge.setCursor(Qt.PointingHandCursor)
        self.badge.clicked.connect(self.edit_due)
        col.addWidget(self.badge)
        lay.addLayout(col, 1)

        self.cal_btn = tool_button("📅", "Ajouter une date (agenda)", 20)
        self.cal_btn.clicked.connect(self.edit_due)
        self.folder_btn = tool_button("📁", "Ranger dans une rubrique", 20)
        self.folder_btn.setPopupMode(QToolButton.InstantPopup)
        self.folder_btn.setMenu(QMenu(self.folder_btn))
        self.folder_btn.menu().aboutToShow.connect(self._fill_folder_menu)
        self.del_btn = tool_button("✕", "Supprimer la tâche", 20)
        self.del_btn.clicked.connect(lambda: self.nw.delete_item(self.item["id"]))
        for b in (self.cal_btn, self.folder_btn):
            sp = b.sizePolicy()
            sp.setRetainSizeWhenHidden(True)
            b.setSizePolicy(sp)
            b.hide()
        for b in (self.cal_btn, self.folder_btn, self.del_btn):
            lay.addWidget(b, 0, Qt.AlignTop)
        self.del_btn.setStyleSheet("color: rgba(0,0,0,0.35)")
        self.refresh()

    # Survol : les options apparaissent sur toute la largeur de la ligne
    def enterEvent(self, e):
        self.cal_btn.show()
        self.folder_btn.setVisible(bool(self.nw.note["groups"]))
        super().enterEvent(e)

    def leaveEvent(self, e):
        self.cal_btn.hide()
        self.folder_btn.hide()
        super().leaveEvent(e)

    def refresh(self):
        it = self.item
        style = "color:#999; text-decoration: line-through;" if it["done"] else ""
        self.label.setText(f"<span style='{style}'>{md_to_html(it['text']) or '&nbsp;'}</span>")
        if it.get("due"):
            color = "#c01c28" if is_overdue(it) else "#555"
            self.badge.setText(f"<span style='color:{color}; font-size:11px'>📅 "
                               f"{html.escape(due_text(it))}</span>")
            self.badge.setToolTip("Modifier la date / ajouter à l'agenda")
            self.badge.show()
        else:
            self.badge.hide()

    def _toggle_done(self, v: bool):
        self.item["done"] = v
        self.nw.changed(rebuild=True)

    def start_edit(self):
        self.editor.setText(self.item["text"])
        self.stack.setCurrentWidget(self.editor)
        self.editor.setFocus()
        self.editor.end(False)

    def finish_edit(self):
        if self.stack.currentWidget() is not self.editor:
            return
        self.item["text"] = self.editor.text().strip()
        self.stack.setCurrentWidget(self.label)
        self.refresh()
        self.nw.changed()

    def cancel_edit(self):
        self.stack.setCurrentWidget(self.label)

    def edit_due(self):
        d = DueDialog(self.item, self.nw)
        if d.exec():
            export = d.apply()
            self.nw.changed(rebuild=True)
            if export:
                self.nw.app.export_items([self.item], open_after=True)

    def _fill_folder_menu(self):
        m = self.folder_btn.menu()
        m.clear()
        groups = self.nw.note["groups"]
        ids = {g["id"] for g in groups}
        cur = self.item.get("group") if self.item.get("group") in ids else None
        a = m.addAction("Sans rubrique")
        a.setCheckable(True), a.setChecked(cur is None)
        a.triggered.connect(lambda: self.nw.move_item(self.item["id"], None))
        m.addSeparator()
        for g in groups:
            a = m.addAction(g["name"] or "Sans nom")
            a.setCheckable(True), a.setChecked(cur == g["id"])
            a.triggered.connect(lambda _=False, gid=g["id"]: self.nw.move_item(self.item["id"], gid))


class AddRow(QWidget):
    def __init__(self, note_win: "NoteWindow", group: str | None):
        super().__init__()
        lay = QHBoxLayout(self)
        lay.setContentsMargins(2, 0, 0, 0)
        lay.setSpacing(6)
        plus = QLabel("+")
        plus.setStyleSheet("color: rgba(0,0,0,0.35); font-weight: bold")
        lay.addWidget(plus)
        self.edit = FormatLineEdit()
        self.edit.setPlaceholderText("Ajouter une tâche…")
        lay.addWidget(self.edit, 1)
        self.edit.returnPressed.connect(lambda: note_win.add_task(self.edit.text(), group))


class GroupHeader(QWidget):
    def __init__(self, nw: "NoteWindow", g: dict, done: int, total: int, first: bool, last: bool):
        super().__init__()
        self.setObjectName("groupHeader")
        self.setAttribute(Qt.WA_StyledBackground)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 8, 0, 2)
        lay.setSpacing(3)
        chev = tool_button("▸" if g.get("collapsed") else "▾",
                           "Déplier" if g.get("collapsed") else "Replier", 18)
        chev.clicked.connect(lambda: nw.toggle_group(g["id"]))
        lay.addWidget(chev)
        self.name = QLineEdit(g["name"])
        self.name.setPlaceholderText("Rubrique")
        f = self.name.font()
        f.setBold(True)
        self.name.setFont(f)
        self.name.editingFinished.connect(lambda: nw.rename_group(g["id"], self.name.text()))
        lay.addWidget(self.name, 1)
        if total:
            c = QLabel(f"{done}/{total}")
            c.setStyleSheet("color: rgba(0,0,0,0.45); font-size: 11px")
            lay.addWidget(c)
        more = tool_button("⋯", "Options de la rubrique", 20)
        more.setPopupMode(QToolButton.InstantPopup)
        m = QMenu(more)
        up = m.addAction("Monter", lambda: nw.move_group(g["id"], -1))
        up.setEnabled(not first)
        down = m.addAction("Descendre", lambda: nw.move_group(g["id"], 1))
        down.setEnabled(not last)
        m.addSeparator()
        m.addAction("Supprimer la rubrique (garder les tâches)", lambda: nw.delete_group(g["id"], False))
        m.addAction("Supprimer la rubrique et ses tâches", lambda: nw.delete_group(g["id"], True))
        more.setMenu(m)
        lay.addWidget(more)


# ───────────────────────────── Fenêtre d'une note ─────────────────────────────

class Header(QWidget):
    """Barre du haut : sert aussi à déplacer la fenêtre."""

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton and self.window().windowHandle():
            self.window().windowHandle().startSystemMove()
        super().mousePressEvent(e)

    def mouseDoubleClickEvent(self, e):
        self.window().toggle_collapse_manual()


class NoteWindow(QWidget):
    HEADER_H = 30

    def __init__(self, app: "PostItApp", note: dict):
        super().__init__(None, Qt.Tool | Qt.FramelessWindowHint)
        self.app, self.note = app, note
        self.collapsed = False
        self._rebuild_pending = False
        self._refocus: tuple[str, str | None] | None = None
        self._add_edits: dict[str | None, QLineEdit] = {}
        self._group_edits: dict[str, QLineEdit] = {}
        self.setAttribute(Qt.WA_DeleteOnClose)
        self.setAttribute(Qt.WA_MacAlwaysShowToolWindow)
        self.setWindowTitle(note["title"] or "Note")
        self.setMinimumSize(190, 120)

        self.pomo = Pomodoro(note.get("pomoWork", 25), note.get("pomoRest", 5),
                             self._pomo_changed, self._pomo_end)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Barre du haut
        self.header = Header()
        self.header.setObjectName("header")
        self.header.setAttribute(Qt.WA_StyledBackground)
        self.header.setFixedHeight(self.HEADER_H)
        hl = QHBoxLayout(self.header)
        hl.setContentsMargins(6, 0, 6, 0)
        hl.setSpacing(2)
        close = tool_button("✕", "Supprimer la note (Ctrl+W)")
        close.clicked.connect(self.ask_close)
        hl.addWidget(close)
        self.bar_title = QLabel()
        self.bar_title.setStyleSheet("font-weight: 600")
        hl.addWidget(self.bar_title, 1)
        self.pin = tool_button("📌", "Garder au premier plan")
        self.pin.setCheckable(True)
        self.pin.clicked.connect(self.toggle_floating)
        hl.addWidget(self.pin)
        self.pomo_btn = tool_button("⏱ 25:00", "Lancer / mettre en pause le pomodoro")
        self.pomo_btn.clicked.connect(self.pomo.toggle)
        hl.addWidget(self.pomo_btn)
        menu_btn = tool_button("☰", "Menu")
        menu_btn.setPopupMode(QToolButton.InstantPopup)
        self.menu = QMenu(menu_btn)
        self.menu.aboutToShow.connect(self._fill_menu)
        menu_btn.setMenu(self.menu)
        hl.addWidget(menu_btn)
        root.addWidget(self.header)

        # Corps
        self.body = QWidget()
        self.body.setObjectName("body")
        self.body.setAttribute(Qt.WA_StyledBackground)
        bl = QVBoxLayout(self.body)
        bl.setContentsMargins(12, 6, 6, 4)
        bl.setSpacing(4)
        top = QHBoxLayout()
        self.title = QLineEdit(note["title"])
        self.title.setPlaceholderText("Sans titre")
        f = self.title.font()
        f.setPointSizeF(f.pointSizeF() + 2)
        f.setBold(True)
        self.title.setFont(f)
        self.title.textChanged.connect(self._title_changed)
        top.addWidget(self.title, 1)
        self.count = QLabel()
        self.count.setStyleSheet("color: rgba(0,0,0,0.45)")
        top.addWidget(self.count)
        bl.addLayout(top)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QScrollArea.NoFrame)
        self.list = QWidget()
        self.list.setObjectName("list")
        self.list_lay = QVBoxLayout(self.list)
        self.list_lay.setContentsMargins(0, 0, 4, 0)
        self.list_lay.setSpacing(3)
        self.scroll.setWidget(self.list)
        bl.addWidget(self.scroll, 1)

        bottom = QHBoxLayout()
        add_group = QPushButton("+ Rubrique")
        add_group.setFlat(True)
        add_group.setCursor(Qt.PointingHandCursor)
        add_group.setToolTip("Nouvelle rubrique (Ctrl+Maj+N)")
        add_group.clicked.connect(self.new_group)
        bottom.addWidget(add_group)
        bottom.addStretch(1)
        self.clear_btn = QPushButton("Effacer les faites")
        self.clear_btn.setToolTip("Effacer les tâches faites")
        self.clear_btn.setFlat(True)
        self.clear_btn.setCursor(Qt.PointingHandCursor)
        self.clear_btn.clicked.connect(self.clear_done)
        bottom.addWidget(self.clear_btn)
        bottom.addWidget(QSizeGrip(self), 0, Qt.AlignBottom | Qt.AlignRight)
        bl.addLayout(bottom)
        root.addWidget(self.body, 1)

        for seq, fn in (("Ctrl+N", app.new_note), ("Ctrl+Shift+N", self.new_group),
                        ("Ctrl+W", self.ask_close)):
            QShortcut(QKeySequence(seq), self, activated=fn)
        for i in range(len(PALETTES)):
            QShortcut(QKeySequence(f"Ctrl+{i + 1}"), self, activated=lambda c=i: self.set_color(c))

        self.setGeometry(int(note["x"]), int(note["y"]), int(note["w"]), int(note["h"]))
        self.apply_style()
        self.apply_floating()
        self._pomo_changed()
        self.rebuild()

    # ── Apparence ──
    def apply_style(self):
        _, body, bar = PALETTES[self.note["color"] % len(PALETTES)]
        self.setStyleSheet(f"""
            NoteWindow, #body, #list {{ background: {body}; }}
            #header {{ background: {bar}; }}
            QWidget {{ color: #222; }}
            QLineEdit {{ background: transparent; border: none; selection-background-color: rgba(0,0,0,0.18); }}
            QScrollArea, QScrollArea > QWidget > QWidget {{ background: transparent; }}
            QToolButton {{ border: none; background: transparent; padding: 0 3px; }}
            QToolButton:hover, QToolButton:checked {{ background: rgba(0,0,0,0.10); border-radius: 4px; }}
            QToolButton::menu-indicator {{ image: none; width: 0; }}
            QPushButton {{ border: none; background: transparent; color: rgba(0,0,0,0.55); padding: 2px 4px; }}
            QPushButton:hover {{ color: #000; }}
            #groupHeader {{ border-bottom: 1px solid rgba(0,0,0,0.12); }}
        """)
        self.setWindowOpacity(max(0.2, min(1.0, float(self.note.get("opacity", 1.0)))))

    def apply_floating(self):
        on = bool(self.note["floating"])
        self.pin.setChecked(on)
        self.pin.setToolTip("Ne plus garder au premier plan" if on else "Garder au premier plan")
        visible = self.isVisible()
        self.setWindowFlag(Qt.WindowStaysOnTopHint, on)
        if visible:
            self.show()
        if not on and self.collapsed:
            self.expand()

    def _title_changed(self, t: str):
        self.note["title"] = t
        self.setWindowTitle(t or "Note")
        self.bar_title.setText(t if self.collapsed else "")
        self.app.store.schedule()

    # ── Repli en barre ──
    def collapse(self):
        if self.collapsed:
            return
        self.collapsed = True
        self.body.hide()
        self.bar_title.setText(self.note["title"] or "Note")
        self.setMinimumHeight(self.HEADER_H)
        self.resize(self.width(), self.HEADER_H)

    def expand(self):
        if not self.collapsed:
            return
        # « collapsed » reste vrai pendant le redimensionnement : la taille
        # mémorisée de la note n'est pas écrasée par les étapes intermédiaires
        self.bar_title.setText("")
        self.body.show()
        self.setMinimumHeight(120)
        self.resize(int(self.note["w"]), int(self.note["h"]))
        self.collapsed = False

    def toggle_collapse_manual(self):
        self.expand() if self.collapsed else self.collapse()

    def moveEvent(self, e):
        self.note["x"], self.note["y"] = self.x(), self.y()
        self.app.store.schedule()
        super().moveEvent(e)

    def resizeEvent(self, e):
        if not self.collapsed:
            self.note["w"], self.note["h"] = self.width(), self.height()
            self.app.store.schedule()
        super().resizeEvent(e)

    # ── Menu ──
    def _fill_menu(self):
        m = self.menu
        m.clear()
        m.addAction("Nouvelle note", self.app.new_note, QKeySequence("Ctrl+N"))
        m.addAction("Nouvelle rubrique", self.new_group, QKeySequence("Ctrl+Shift+N"))
        m.addSeparator()
        colors = m.addMenu("Couleur")
        for i, (name, *_rest) in enumerate(PALETTES):
            a = colors.addAction(name, lambda c=i: self.set_color(c), QKeySequence(f"Ctrl+{i + 1}"))
            a.setCheckable(True)
            a.setChecked(self.note["color"] == i)
        trans = m.addMenu("Transparence")
        cur = round(float(self.note.get("opacity", 1.0)) * 100)
        for v in OPACITY_LEVELS:
            a = trans.addAction(f"{v} %", lambda v=v: self.set_opacity(v))
            a.setCheckable(True)
            a.setChecked(cur == v)
        a = m.addAction("Toujours au premier plan", self.toggle_floating)
        a.setCheckable(True)
        a.setChecked(bool(self.note["floating"]))
        a = m.addAction("Replier les notes épinglées hors de OPost-it", self.app.toggle_auto_collapse)
        a.setCheckable(True)
        a.setChecked(self.app.auto_collapse)
        pomo = m.addMenu("Pomodoro")
        work = pomo.addMenu("Travail")
        for v in WORK_CHOICES:
            a = work.addAction(f"{v} min", lambda v=v: self._set_work(v))
            a.setCheckable(True), a.setChecked(self.pomo.work == v)
        rest = pomo.addMenu("Pause")
        for v in REST_CHOICES:
            a = rest.addAction(f"{v} min", lambda v=v: self._set_rest(v))
            a.setCheckable(True), a.setChecked(self.pomo.rest == v)
        pomo.addSeparator()
        pomo.addAction("Passer à la pause" if self.pomo.phase == "work" else "Passer au travail",
                       self.pomo.skip)
        pomo.addAction("Réinitialiser", self.pomo.reset)
        m.addSeparator()
        dated = [i for i in self.note["items"] if i.get("due")]
        a = m.addAction("Exporter les tâches datées vers l'agenda (.ics)…",
                        lambda: self.app.export_items(dated, open_after=False, ask_path=True))
        a.setEnabled(bool(dated))
        a = m.addAction("Effacer les tâches faites", self.clear_done)
        a.setEnabled(any(i["done"] for i in self.note["items"]))
        m.addSeparator()
        m.addAction("Supprimer la note", self.ask_close, QKeySequence("Ctrl+W"))
        m.addAction("Quitter OPost-it", self.app.quit)

    def set_color(self, c: int):
        self.note["color"] = c
        self.apply_style()
        self.app.store.schedule()

    def set_opacity(self, v: int):
        self.note["opacity"] = v / 100
        self.apply_style()
        self.app.store.schedule()

    def toggle_floating(self):
        self.note["floating"] = not self.note["floating"]
        self.apply_floating()
        self.app.store.schedule()

    # ── Pomodoro ──
    def _set_work(self, v):
        self.pomo.set_work(v)
        self.note["pomoWork"] = v
        self.app.store.schedule()

    def _set_rest(self, v):
        self.pomo.set_rest(v)
        self.note["pomoRest"] = v
        self.app.store.schedule()

    def _pomo_changed(self):
        icon = "⏸" if self.pomo.running else ("⏱" if self.pomo.phase == "work" else "☕")
        self.pomo_btn.setText(f"{icon} {self.pomo.label()}")
        tint = "rgba(200,0,0,0.18)" if self.pomo.phase == "work" else "rgba(0,150,0,0.22)"
        self.pomo_btn.setStyleSheet(f"background: {tint if self.pomo.running else 'transparent'};"
                                    "border-radius: 9px; padding: 0 6px; font-family: monospace")

    def _pomo_end(self, finished: str):
        QApplication.beep()
        QApplication.alert(self)
        title = self.note["title"] or "Pomodoro"
        msg = "C'est l'heure de la pause !" if finished == "work" else "On se remet au travail !"
        self.app.notify(title, msg)

    # ── Liste ──
    def changed(self, rebuild: bool = False):
        self.app.store.schedule()
        if rebuild:
            self.request_rebuild()

    def request_rebuild(self):
        if not self._rebuild_pending:
            self._rebuild_pending = True
            QTimer.singleShot(0, self.rebuild)

    def rebuild(self):
        self._rebuild_pending = False
        while self.list_lay.count():
            w = self.list_lay.takeAt(0).widget()
            if w is not None:
                w.hide()
                w.deleteLater()
        self._add_edits.clear()
        self._group_edits.clear()
        items, groups = self.note["items"], self.note["groups"]
        gids = {g["id"] for g in groups}
        loose = [i for i in items if i.get("group") not in gids]
        for it in loose:
            self.list_lay.addWidget(ItemRow(self, it))
        if not groups or loose:
            row = AddRow(self, None)
            self._add_edits[None] = row.edit
            self.list_lay.addWidget(row)
        for n, g in enumerate(groups):
            its = [i for i in items if i.get("group") == g["id"]]
            hdr = GroupHeader(self, g, sum(i["done"] for i in its), len(its), n == 0, n == len(groups) - 1)
            self._group_edits[g["id"]] = hdr.name
            self.list_lay.addWidget(hdr)
            if not g.get("collapsed"):
                for it in its:
                    self.list_lay.addWidget(ItemRow(self, it))
                row = AddRow(self, g["id"])
                self._add_edits[g["id"]] = row.edit
                self.list_lay.addWidget(row)
        self.list_lay.addStretch(1)

        done = sum(i["done"] for i in items)
        self.count.setText(f"{done}/{len(items)}" if items else "")
        self.clear_btn.setVisible(done > 0)

        if self._refocus:
            kind, key = self._refocus
            self._refocus = None
            w = (self._add_edits if kind == "add" else self._group_edits).get(key)
            if w is not None:
                w.setFocus()
                if kind == "group":
                    w.selectAll()

    def add_task(self, text: str, group: str | None):
        t = text.strip()
        if not t:
            return
        if t.startswith("# "):  # « # Nom » crée une rubrique
            name = t[2:].strip()
            if name:
                self.note["groups"].append({"id": new_id(), "name": name, "collapsed": False})
            self._refocus = ("add", None if not name else self.note["groups"][-1]["id"])
        else:
            self.note["items"].append(make_item(t, group))
            self._refocus = ("add", group)
        self.changed(rebuild=True)

    def delete_item(self, iid: str):
        self.note["items"] = [i for i in self.note["items"] if i["id"] != iid]
        self.changed(rebuild=True)

    def move_item(self, iid: str, gid: str | None):
        for i in self.note["items"]:
            if i["id"] == iid:
                i["group"] = gid
        self.changed(rebuild=True)

    def clear_done(self):
        self.note["items"] = [i for i in self.note["items"] if not i["done"]]
        self.changed(rebuild=True)

    # ── Rubriques ──
    def new_group(self):
        g = {"id": new_id(), "name": "Nouvelle rubrique", "collapsed": False}
        self.note["groups"].append(g)
        self._refocus = ("group", g["id"])
        if self.collapsed:
            self.expand()
        self.changed(rebuild=True)

    def _group(self, gid):
        return next((g for g in self.note["groups"] if g["id"] == gid), None)

    def toggle_group(self, gid):
        g = self._group(gid)
        if g:
            g["collapsed"] = not g.get("collapsed")
            self.changed(rebuild=True)

    def rename_group(self, gid, name):
        g = self._group(gid)
        if g and g["name"] != name:
            g["name"] = name
            self.changed()

    def move_group(self, gid, d):
        gs = self.note["groups"]
        i = next((k for k, g in enumerate(gs) if g["id"] == gid), None)
        if i is not None and 0 <= i + d < len(gs):
            gs[i], gs[i + d] = gs[i + d], gs[i]
            self.changed(rebuild=True)

    def delete_group(self, gid, with_tasks: bool):
        if with_tasks:
            self.note["items"] = [i for i in self.note["items"] if i.get("group") != gid]
        else:
            for i in self.note["items"]:
                if i.get("group") == gid:
                    i["group"] = None
        self.note["groups"] = [g for g in self.note["groups"] if g["id"] != gid]
        self.changed(rebuild=True)

    # ── Fermeture = suppression ──
    def ask_close(self):
        n = self.note
        if n["items"] or n["title"] or n["groups"]:
            r = QMessageBox.question(None, "Supprimer cette note ?",
                                     "Ses tâches seront définitivement effacées.",
                                     QMessageBox.Yes | QMessageBox.Cancel, QMessageBox.Cancel)
            if r != QMessageBox.Yes:
                return
        self.app.remove_note(self)


# ───────────────────────────── Application ─────────────────────────────

def open_link(url: str):
    if is_safe_link(url):
        QDesktopServices.openUrl(QUrl(url))


class PostItApp:
    def __init__(self, qapp: QApplication):
        self.qapp = qapp
        self.store = Store()
        self.windows: list[NoteWindow] = []
        self.settings = QSettings()
        self.auto_collapse = self.settings.value("autoCollapse", True, type=bool)

        self.tray = None
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.tray = QSystemTrayIcon(app_icon())
            self.tray.setToolTip(DISPLAY_NAME)
            m = QMenu()
            m.addAction("Nouvelle note", self.new_note)
            m.addAction("Tout afficher", self.show_all)
            m.addSeparator()
            m.addAction("Quitter OPost-it", self.quit)
            self.tray.setContextMenu(m)
            self.tray.activated.connect(lambda r: self.show_all()
                                        if r == QSystemTrayIcon.Trigger else None)
            self.tray.show()
        qapp.setQuitOnLastWindowClosed(self.tray is None)

        notes = self.store.load() or [self.welcome_note()]
        for n in notes:
            self.open_note(n)
        qapp.applicationStateChanged.connect(self._app_state)
        qapp.aboutToQuit.connect(self.store.save_now)

        # Alerte à l'heure de début des tâches datées
        self._alarm = QTimer(interval=30_000)
        self._alarm.timeout.connect(self._check_alarms)
        if not DEMO:
            self._alarm.start()
            QTimer.singleShot(2000, self._check_alarms)

    def welcome_note(self) -> dict:
        screen = QGuiApplication.primaryScreen().availableGeometry()
        n = make_note(title="À faire", x=screen.center().x() - 140, y=screen.center().y() - 160)
        n["items"] = [make_item(t) for t in (
            "Ctrl+N pour créer une nouvelle note",
            "Menu ☰ pour la couleur (Ctrl+1 à Ctrl+6) et la transparence",
            "La punaise 📌 garde une note au premier plan",
            "Ctrl+Maj+N ou « # Nom » pour créer une rubrique",
            "**Gras** (Ctrl+B), *italique* (Ctrl+I), [lien](https://fr.wikipedia.org) (Ctrl+K)",
            "Survole une tâche → 📅 pour la dater et l'ajouter à ton agenda",
        )]
        n["items"].append(make_item("Cocher une tâche", done=True))
        return n

    def open_note(self, n: dict):
        self.store.notes.append(n)
        w = NoteWindow(self, n)
        self.windows.append(w)
        w.show()
        self.store.schedule()
        return w

    def new_note(self):
        src = next((w for w in self.windows if w.isActiveWindow()), None)
        if src:
            n = make_note(x=src.x() + 28, y=src.y() + 28, color=src.note["color"])
        else:
            c = QGuiApplication.primaryScreen().availableGeometry().center()
            n = make_note(x=c.x() - 140, y=c.y() - 160)
        w = self.open_note(n)
        w.activateWindow()
        w.raise_()
        w.title.setFocus()

    def remove_note(self, w: NoteWindow):
        w.pomo.reset()
        self.windows.remove(w)
        self.store.notes = [n for n in self.store.notes if n["id"] != w.note["id"]]
        self.store.schedule()
        w.close()

    def show_all(self):
        for w in self.windows:
            w.show()
            w.raise_()
        if self.windows:
            self.windows[-1].activateWindow()
        else:
            self.new_note()

    def quit(self):
        self.store.save_now()
        self.qapp.quit()

    def toggle_auto_collapse(self):
        self.auto_collapse = not self.auto_collapse
        self.settings.setValue("autoCollapse", self.auto_collapse)

    def _app_state(self, state):
        if state == Qt.ApplicationActive:
            for w in self.windows:
                w.expand()
        elif self.auto_collapse:
            for w in self.windows:
                if w.note["floating"]:
                    w.collapse()

    def notify(self, title: str, msg: str):
        if self.tray and self.tray.supportsMessages():
            self.tray.showMessage(title, msg, app_icon(), 15_000)
        else:
            box = QMessageBox(QMessageBox.Information, title, msg)
            box.setAttribute(Qt.WA_DeleteOnClose)
            box.setWindowFlag(Qt.WindowStaysOnTopHint)
            box.show()

    def _check_alarms(self):
        now = dt.datetime.now()
        dirty = False
        for w in self.windows:
            for it in w.note["items"]:
                start = item_start(it)
                if start is None or it.get("done") or it.get("allDay"):
                    continue
                # On ne prévient qu'une fois, et pas pour des tâches passées depuis longtemps
                if start <= now < start + dt.timedelta(hours=12) and it.get("alerted") != it["due"]:
                    it["alerted"] = it["due"]
                    dirty = True
                    QApplication.beep()
                    self.notify(f"⏰ {start:%H:%M}", md_to_plain(it["text"]))
            if dirty:
                w.request_rebuild()
        if dirty:
            self.store.schedule()

    def export_items(self, items: list[dict], open_after: bool, ask_path: bool = False):
        if DEMO:
            self.notify(DISPLAY_NAME, "Mode démo : rien n'est exporté vers l'agenda.")
            return
        items = [i for i in items if i.get("due")]
        if not items:
            return
        for it in items:  # même UID + numéro de version → l'agenda met à jour au lieu de dupliquer
            it["icsSeq"] = int(it.get("icsSeq", -1)) + 1
        self.store.schedule()
        if ask_path:
            path, _ = QFileDialog.getSaveFileName(None, "Exporter vers l'agenda",
                                                  os.path.expanduser("~/taches-post-it.ics"),
                                                  "Agenda (*.ics)")
            if not path:
                return
        else:
            folder = os.path.join(self.store.dir, "agenda")
            os.makedirs(folder, exist_ok=True)
            safe = re.sub(r"[^\w-]+", "-", md_to_plain(items[0]["text"]))[:40].strip("-") or "tache"
            path = os.path.join(folder, f"{safe}-{items[0]['id'][:8]}.ics")
        try:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(make_ics(items))
        except OSError as e:
            QMessageBox.critical(None, DISPLAY_NAME, f"Impossible d'écrire le fichier d'agenda :\n{e}")
            return
        if open_after or ask_path:
            if not QDesktopServices.openUrl(QUrl.fromLocalFile(path)):
                QMessageBox.information(None, DISPLAY_NAME,
                                        "Aucune application d'agenda n'a ouvert le fichier.\n"
                                        f"Tu peux l'importer à la main :\n{path}")


def main():
    QApplication.setApplicationName(APP_NAME)
    QApplication.setOrganizationName(APP_NAME)
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    qapp = QApplication(sys.argv)
    qapp.setApplicationDisplayName(DISPLAY_NAME)
    qapp.setWindowIcon(app_icon())

    if DEMO:
        app = PostItApp(qapp)  # noqa: F841
        return qapp.exec()

    # Une seule instance à la fois (sinon deux fenêtres écraseraient le même fichier)
    data_dir = QStandardPaths.writableLocation(QStandardPaths.AppDataLocation)
    os.makedirs(data_dir, exist_ok=True)
    lock = QLockFile(os.path.join(data_dir, "post-it.lock"))
    lock.setStaleLockTime(0)
    if not lock.tryLock(100):
        QMessageBox.information(None, DISPLAY_NAME, "OPost-it est déjà ouvert.")
        return 0

    app = PostItApp(qapp)  # noqa: F841 — garde l'application en vie
    code = qapp.exec()
    lock.unlock()
    return code


if __name__ == "__main__":
    sys.exit(main())
