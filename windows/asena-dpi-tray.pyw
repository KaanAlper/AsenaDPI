#!/usr/bin/env python3
"""
AsenaDPI — Windows tray (winws/WinDivert + DoH DNS + blockcheck).
Logon'da YONETICI olarak baslar (scheduled task, highest) -> winws + DNS'i dogrudan yonetir,
her ac/kapada UAC sormaz. SOL tik = ayarlar, SAG tik = menu.
"""
import os, sys, subprocess
from pathlib import Path

from PySide6.QtWidgets import (
    QApplication, QSystemTrayIcon, QMenu, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QRadioButton, QCheckBox, QPushButton, QButtonGroup, QFrame, QPlainTextEdit,
)
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QBrush, QPen, QPixmap, QPainterPath, QFont, QTextCursor
from PySide6.QtCore import QTimer, Qt, QPointF, QProcess

INSTALL_DIR = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "AsenaDPI"
WINWS = INSTALL_DIR / "winws.exe"
BLOCKCHECK = INSTALL_DIR / "blockcheck" / "blockcheck.cmd"
CFG = Path(os.environ.get("APPDATA", str(Path.home()))) / "AsenaDPI"
BLACKLIST = CFG / "blacklist.txt"
CLEAN = CFG / "hostlist_clean.txt"
SETTINGS = CFG / "settings.conf"
STRAT_FILE = CFG / "tcp443.conf"
LOG = CFG / "winws.log"
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW — konsol penceresi acmasin

DEFAULTS = {"MODE": "blacklist", "HTTP": "1", "HTTP2": "1", "HTTP3": "bypass"}
LBL = {
    "MODE": ("Mod", {"blacklist": "Blacklist", "full": "Full"}),
    "HTTP": ("HTTP (80)", {"1": "açık", "0": "kapalı"}),
    "HTTP2": ("HTTP/2 (443)", {"1": "açık", "0": "kapalı"}),
    "HTTP3": ("HTTP/3·QUIC", {"bypass": "Bypass", "off": "Kapalı", "block": "Engelle"}),
}
ACCENT = "#26A69A"
DEFAULT_TCP443 = "--dpi-desync=fakedsplit --dpi-desync-fooling=md5sig --dpi-desync-split-pos=1"


def run_hidden(args, **kw):
    return subprocess.run(args, creationflags=NO_WINDOW, capture_output=True, text=True, **kw)


def ps(cmd):
    return run_hidden(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd])


def load_settings() -> dict:
    s = dict(DEFAULTS)
    try:
        for line in SETTINGS.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1); k = k.strip(); v = v.strip().strip('"').strip("'")
            if k in DEFAULTS:
                s[k] = v
    except FileNotFoundError:
        pass
    if s["HTTP3"] == "1": s["HTTP3"] = "bypass"
    elif s["HTTP3"] == "0": s["HTTP3"] = "off"
    return s


def save_settings(s: dict):
    CFG.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(
        "# AsenaDPI ayarlari (tray yazar)\n"
        f"MODE={s['MODE']}\nHTTP={s['HTTP']}\nHTTP2={s['HTTP2']}\nHTTP3={s['HTTP3']}\n",
        encoding="utf-8")


def tcp443_strategy() -> str:
    try:
        for line in STRAT_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    except FileNotFoundError:
        pass
    return DEFAULT_TCP443


def clean_hostlist():
    """*. ve #yorum kaldir -> winws --hostlist icin."""
    try:
        out = []
        for ln in BLACKLIST.read_text(encoding="utf-8").splitlines():
            ln = ln.split("#", 1)[0].strip().lstrip("*.").strip().lower().strip(".")
            if "." in ln:
                out.append(ln)
        CLEAN.write_text("\n".join(sorted(set(out))) + "\n", encoding="utf-8")
    except FileNotFoundError:
        CLEAN.write_text("", encoding="utf-8")


def is_on() -> bool:
    r = run_hidden(["tasklist", "/fi", "imagename eq winws.exe", "/nh"])
    return "winws.exe" in (r.stdout or "")


# ---- winws + DNS kontrol (tray YONETICI oldugu icin dogrudan) ----
def active_iface_index() -> str:
    r = ps("(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | "
           "Select-Object -First 1).InterfaceIndex")
    return (r.stdout or "").strip()


def dns_doh_on():
    ps("Add-DnsClientDohServerAddress -ServerAddress 1.1.1.1 "
       "-DohTemplate 'https://cloudflare-dns.com/dns-query' -AllowFallbackToUdp $false "
       "-AutoUpgrade $true -ErrorAction SilentlyContinue")
    idx = active_iface_index()
    if idx:
        (CFG / "dnsiface.txt").write_text(idx, encoding="utf-8")
        ps(f"Set-DnsClientServerAddress -InterfaceIndex {idx} -ServerAddresses 1.1.1.1 -ErrorAction SilentlyContinue")
        ps("Clear-DnsClientCache")


def dns_restore():
    idx = ""
    try: idx = (CFG / "dnsiface.txt").read_text(encoding="utf-8").strip()
    except FileNotFoundError: idx = active_iface_index()
    if idx:
        ps(f"Set-DnsClientServerAddress -InterfaceIndex {idx} -ResetServerAddresses -ErrorAction SilentlyContinue")
        ps("Clear-DnsClientCache")


def quic_block(on: bool):
    ps("Remove-NetFirewallRule -DisplayName AsenaDPI-QUIC -ErrorAction SilentlyContinue")
    if on:
        ps("New-NetFirewallRule -DisplayName AsenaDPI-QUIC -Direction Outbound -Action Block "
           "-Protocol UDP -RemotePort 443 -ErrorAction SilentlyContinue")


def winws_args(s):
    clean_hostlist()
    hl = [] if s["MODE"] == "full" else [f"--hostlist={CLEAN}"]
    a = [str(WINWS)]
    tcp_ports = [p for p, k in (("80", "HTTP"), ("443", "HTTP2")) if s[k] == "1"]
    if tcp_ports:
        a.append("--wf-tcp=" + ",".join(tcp_ports))
    if s["HTTP3"] == "bypass":
        a.append("--wf-udp=443")
    if s["HTTP"] == "1":
        a += ["--filter-tcp=80", "--dpi-desync=fake,multisplit", "--dpi-desync-split-pos=method+2",
              "--dpi-desync-fooling=md5sig"] + hl + ["--new"]
    if s["HTTP2"] == "1":
        a += ["--filter-tcp=443"] + tcp443_strategy().split() + hl + ["--new"]
    if s["HTTP3"] == "bypass":
        a += ["--filter-udp=443", "--dpi-desync=fake", "--dpi-desync-repeats=6"] + hl + ["--new"]
    if a and a[-1] == "--new":
        a.pop()
    return a


def start_on():
    s = load_settings()
    subprocess.run(["taskkill", "/f", "/im", "winws.exe"], creationflags=NO_WINDOW,
                   capture_output=True)
    quic_block(s["HTTP3"] == "block")
    with open(LOG, "w", encoding="utf-8", errors="replace") as lf:
        subprocess.Popen(winws_args(s), cwd=str(INSTALL_DIR), stdout=lf, stderr=lf,
                         creationflags=NO_WINDOW)
    dns_doh_on()


def stop_off():
    subprocess.run(["taskkill", "/f", "/im", "winws.exe"], creationflags=NO_WINDOW, capture_output=True)
    quic_block(False)
    dns_restore()


def make_icon(on: bool) -> QIcon:
    pm = QPixmap(64, 64); pm.fill(Qt.transparent)
    p = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.moveTo(32, 6); path.lineTo(54, 15); path.lineTo(54, 34)
    path.cubicTo(54, 48, 44, 55, 32, 60); path.cubicTo(20, 55, 10, 48, 10, 34)
    path.lineTo(10, 15); path.closeSubpath()
    if on:
        p.setBrush(QBrush(QColor(38, 166, 154))); p.setPen(QPen(QColor(19, 111, 99), 2)); p.drawPath(path)
        p.setPen(QPen(QColor(255, 255, 255), 6, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        p.drawPolyline([QPointF(23, 33), QPointF(30, 41), QPointF(43, 24)])
    else:
        p.setBrush(QBrush(QColor(70, 70, 74))); p.setPen(QPen(QColor(120, 120, 126), 2)); p.drawPath(path)
    p.end()
    return QIcon(pm)


def hline():
    f = QFrame(); f.setFrameShape(QFrame.HLine); f.setStyleSheet("color:#2a2f37;"); return f
def section(t):
    l = QLabel(t); f = QFont(); f.setBold(True); f.setPointSize(10); l.setFont(f)
    l.setStyleSheet(f"color:{ACCENT}; margin-top:4px;"); return l


class OptimizeWindow(QWidget):
    def __init__(self, tray):
        super().__init__()
        self.tray = tray; self.proc = None
        self.setWindowTitle("AsenaDPI — En iyi strateji (blockcheck)")
        self.resize(600, 400); self.setWindowIcon(make_icon(True))
        self.setStyleSheet("QWidget{background:#1b1f27;color:#e6e9ee;font-size:12px;}"
                           "QPushButton{background:#2a2f37;border:1px solid #3a414c;border-radius:6px;padding:6px 14px;}")
        v = QVBoxLayout(self); v.setContentsMargins(14, 14, 14, 14)
        self.status = QLabel("blockcheck çalışıyor… (birkaç dakika)"); self.status.setStyleSheet("font-weight:bold;")
        v.addWidget(self.status)
        self.out = QPlainTextEdit(); self.out.setReadOnly(True)
        self.out.setStyleSheet("background:#0e1116;color:#b8e0d2;border:1px solid #262c36;"
                               "border-radius:6px;font-family:Consolas,monospace;font-size:11px;")
        v.addWidget(self.out)
        h = QHBoxLayout(); h.addStretch(1)
        self.btn_stop = QPushButton("Durdur"); self.btn_stop.clicked.connect(self.stop)
        b_close = QPushButton("Kapat"); b_close.clicked.connect(self.close)
        h.addWidget(self.btn_stop); h.addWidget(b_close); v.addLayout(h)

    def run(self):
        if not BLOCKCHECK.exists():
            self.out.setPlainText(f"blockcheck bulunamadı:\n{BLOCKCHECK}\n(install.ps1 bundle'ı kurmamış olabilir)")
            self.show(); self.raise_(); return
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.show(); self.raise_(); return
        self.out.clear(); self.btn_stop.setEnabled(True)
        self.status.setText("blockcheck çalışıyor… (birkaç dakika)")
        self.show(); self.raise_(); self.activateWindow()
        self.proc = QProcess(self); self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.setWorkingDirectory(str(BLOCKCHECK.parent))
        self.proc.readyRead.connect(self._read); self.proc.finished.connect(self._done)
        # blockcheck'i Discord domainleri + non-interaktif env ile calistir
        env = self.proc.processEnvironment()
        self.proc.start("cmd", ["/c", str(BLOCKCHECK)])

    def _read(self):
        self.out.moveCursor(QTextCursor.End)
        self.out.insertPlainText(bytes(self.proc.readAll()).decode("utf-8", "replace"))
        self.out.moveCursor(QTextCursor.End)

    def _done(self, code, _st):
        self.btn_stop.setEnabled(False)
        self.status.setText(f"Bitti (kod {code}). Çalışan stratejiyi tcp443.conf'a elle yazabilirsin.")
        self.tray.refresh()

    def stop(self):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.proc.kill(); self.status.setText("Durduruldu.")

    def closeEvent(self, e):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.proc.kill()
        e.accept()


class SettingsWindow(QWidget):
    def __init__(self, tray):
        super().__init__()
        self.tray = tray; self._busy = False
        self.saved = load_settings(); self.pending = dict(self.saved)
        self.setWindowTitle("AsenaDPI — Ayarlar"); self.setMinimumWidth(450)
        self.setWindowIcon(make_icon(True))
        self.setStyleSheet(f"QWidget{{background:#1b1f27;color:#e6e9ee;font-size:12px;}}"
                           f"QPushButton{{background:#2a2f37;border:1px solid #3a414c;border-radius:6px;padding:7px 14px;}}"
                           f"QPushButton#apply{{background:{ACCENT};border:none;color:#04201c;font-weight:bold;}}"
                           f"QPushButton#apply:disabled{{background:#2a2f37;color:#5b636e;}}")
        root = QVBoxLayout(self); root.setContentsMargins(16, 16, 16, 16); root.setSpacing(9)
        top = QHBoxLayout()
        self.status = QLabel(); self.status.setStyleSheet("font-size:13px;font-weight:bold;")
        self.btn_power = QPushButton("Bağlan"); self.btn_power.clicked.connect(self.toggle_power)
        top.addWidget(self.status); top.addStretch(1); top.addWidget(self.btn_power)
        root.addLayout(top); root.addWidget(hline())
        root.addWidget(section("Mod"))
        self.g_mode = QButtonGroup(self)
        self.rb_bl = QRadioButton("Blacklist  —  yalnız listedeki siteler")
        self.rb_full = QRadioButton("Full  —  tüm trafik")
        for rb, val in ((self.rb_bl, "blacklist"), (self.rb_full, "full")):
            self.g_mode.addButton(rb); rb.toggled.connect(lambda c, v=val: c and self.setp("MODE", v)); root.addWidget(rb)
        root.addWidget(hline()); root.addWidget(section("HTTP/3 · QUIC"))
        self.g_h3 = QButtonGroup(self)
        self.rb_bypass = QRadioButton("Bypass  —  DPI'dan geçirmeye çalış")
        self.rb_h3off = QRadioButton("Kapalı  —  dokunma")
        self.rb_block = QRadioButton("Engelle  —  QUIC kes → TCP'ye düş (oyun)")
        for rb, val in ((self.rb_bypass, "bypass"), (self.rb_h3off, "off"), (self.rb_block, "block")):
            self.g_h3.addButton(rb); rb.toggled.connect(lambda c, v=val: c and self.setp("HTTP3", v)); root.addWidget(rb)
        root.addWidget(hline()); root.addWidget(section("Gelişmiş"))
        self.cb_http = QCheckBox("HTTP (80)"); self.cb_http.toggled.connect(lambda c: self.setp("HTTP", "1" if c else "0"))
        self.cb_http2 = QCheckBox("HTTP/2 (443) — kapatma"); self.cb_http2.toggled.connect(lambda c: self.setp("HTTP2", "1" if c else "0"))
        root.addWidget(self.cb_http); root.addWidget(self.cb_http2); root.addWidget(hline())
        root.addWidget(section("Değişecekler"))
        self.diff = QLabel("Değişiklik yok"); self.diff.setWordWrap(True)
        self.diff.setStyleSheet("color:#c7ccd4;font-size:11px;background:#181c23;border:1px solid #262c36;border-radius:8px;padding:8px;")
        root.addWidget(self.diff)
        btns = QHBoxLayout()
        b_edit = QPushButton("Blacklist…"); b_edit.clicked.connect(lambda: os.startfile(str(BLACKLIST)))
        b_opt = QPushButton("En iyiyi bul"); b_opt.clicked.connect(lambda: self.tray.optimize())
        btns.addWidget(b_edit); btns.addWidget(b_opt); btns.addStretch(1)
        self.btn_apply = QPushButton("⟳ Uygula"); self.btn_apply.setObjectName("apply"); self.btn_apply.clicked.connect(self.apply)
        b_close = QPushButton("Kapat"); b_close.clicked.connect(self.hide)
        btns.addWidget(self.btn_apply); btns.addWidget(b_close); root.addLayout(btns)
        self.sync(); self.refresh_status()
        self.t = QTimer(self); self.t.timeout.connect(self.refresh_status); self.t.start(2500)

    def refresh_status(self):
        on = is_on()
        self.status.setText("🟢  AsenaDPI AÇIK" if on else "⚪  AsenaDPI kapalı")
        self.status.setStyleSheet(f"font-size:13px;font-weight:bold;color:{'#3ddc97' if on else '#8a929c'};")
        self.btn_power.setText("Kapat" if on else "Bağlan")

    def toggle_power(self):
        if self._busy: return
        self._busy = True
        if is_on(): stop_off()
        else:
            save_settings(self.pending); self.saved = dict(self.pending); start_on()
        self._busy = False
        QTimer.singleShot(500, self.refresh_status); QTimer.singleShot(500, self.tray.refresh)
        QTimer.singleShot(550, self.update_diff)

    def setp(self, k, v): self.pending[k] = v; self.update_diff()

    def sync(self):
        p = self.pending
        self.rb_bl.setChecked(p["MODE"] != "full"); self.rb_full.setChecked(p["MODE"] == "full")
        self.rb_bypass.setChecked(p["HTTP3"] == "bypass"); self.rb_h3off.setChecked(p["HTTP3"] == "off")
        self.rb_block.setChecked(p["HTTP3"] == "block")
        self.cb_http.setChecked(p["HTTP"] == "1"); self.cb_http2.setChecked(p["HTTP2"] == "1"); self.update_diff()

    def update_diff(self):
        rows = []
        for k in ("MODE", "HTTP3", "HTTP", "HTTP2"):
            if self.pending[k] != self.saved[k]:
                name, vmap = LBL[k]
                rows.append(f"• {name}:  {vmap[self.saved[k]]}  →  <b style='color:{ACCENT}'>{vmap[self.pending[k]]}</b>")
        self.diff.setText("<br>".join(rows) if rows else "Değişiklik yok")
        self.btn_apply.setEnabled(bool(rows))

    def apply(self):
        if self._busy or self.pending == self.saved: return
        self._busy = True; save_settings(self.pending); self.saved = dict(self.pending)
        if is_on(): stop_off(); start_on()
        self._busy = False; self.update_diff()
        QTimer.singleShot(500, self.refresh_status); QTimer.singleShot(500, self.tray.refresh)

    def open_fresh(self):
        self.saved = load_settings(); self.pending = dict(self.saved); self.sync(); self.refresh_status()
        self.show(); self.raise_(); self.activateWindow()


class AsenaTray:
    def __init__(self, app):
        self.app = app; self.win = None; self.optwin = None
        self.icon_on = make_icon(True); self.icon_off = make_icon(False)
        self.tray = QSystemTrayIcon(); self.menu = QMenu()
        self.act_toggle = QAction("Bağlan", self.menu); self.act_toggle.triggered.connect(self.toggle)
        self.menu.addAction(self.act_toggle)
        a_set = QAction("Ayarlar…", self.menu); a_set.triggered.connect(self.open_settings); self.menu.addAction(a_set)
        a_opt = QAction("En iyi stratejiyi bul", self.menu); a_opt.triggered.connect(self.optimize); self.menu.addAction(a_opt)
        self.menu.addSeparator()
        a_bl = QAction("Blacklist düzenle…", self.menu); a_bl.triggered.connect(lambda: os.startfile(str(BLACKLIST))); self.menu.addAction(a_bl)
        a_log = QAction("Logu göster", self.menu); a_log.triggered.connect(lambda: os.startfile(str(LOG)) if LOG.exists() else None); self.menu.addAction(a_log)
        self.menu.addSeparator()
        a_q = QAction("Çıkış", self.menu); a_q.triggered.connect(app.quit); self.menu.addAction(a_q)
        self.tray.setContextMenu(self.menu); self.tray.activated.connect(self.on_act); self.tray.show()
        self.t = QTimer(); self.t.timeout.connect(self.refresh); self.t.start(3000); self.refresh()

    def open_settings(self):
        if self.win is None: self.win = SettingsWindow(self)
        self.win.open_fresh()

    def optimize(self):
        if self.optwin is None: self.optwin = OptimizeWindow(self)
        self.optwin.run()

    def on_act(self, reason):
        if reason == QSystemTrayIcon.Trigger: self.open_settings()

    def toggle(self):
        if is_on(): stop_off()
        else: start_on()
        QTimer.singleShot(600, self.refresh)

    def refresh(self):
        on = is_on()
        self.tray.setIcon(self.icon_on if on else self.icon_off)
        self.act_toggle.setText("Bağlantıyı kes" if on else "Bağlan")
        self.tray.setToolTip(f"AsenaDPI: {'AÇIK' if on else 'kapalı'}  (sol tık: ayarlar)")


def main():
    app = QApplication(sys.argv); app.setQuitOnLastWindowClosed(False); app.setApplicationName("AsenaDPI")
    _t = AsenaTray(app); sys.exit(app.exec())


if __name__ == "__main__":
    main()
