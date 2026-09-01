#!/usr/bin/env python3
"""
AsenaDPI — Windows tray (winws/WinDivert + DoH DNS + blockcheck).
Logon'da YONETICI olarak baslar (scheduled task, highest) -> winws + DNS'i dogrudan yonetir,
her ac/kapada UAC sormaz. SOL tik = ayarlar, SAG tik = menu.
"""
import os, sys, subprocess, shutil, threading, time
from pathlib import Path

from PySide6.QtWidgets import (
    QApplication, QSystemTrayIcon, QMenu, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QRadioButton, QCheckBox, QPushButton, QButtonGroup, QFrame, QPlainTextEdit, QMessageBox,
    QProgressBar, QInputDialog,
)
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QBrush, QPen, QPixmap, QPainterPath, QFont, QTextCursor
from PySide6.QtCore import QTimer, Qt, QPointF, QProcess

INSTALL_DIR = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "AsenaDPI"
WINWS_DIR = INSTALL_DIR / "zapret-winws"           # winws burada calismali (WinDivert dosyalari)
WINWS = WINWS_DIR / "winws.exe"
# blockcheck OTOMATIK: interaktif .cmd yerine cygwin bash ile blockcheck.sh non-interaktif
CYG_BASH = INSTALL_DIR / "cygwin" / "bin" / "bash.exe"
BLOCKCHECK_SH = INSTALL_DIR / "blockcheck" / "zapret" / "blockcheck.sh"
OPTIMIZE_DOMAINS = "discord.com gateway.discord.gg"   # blockcheck hedefi (istenirse degistir)
CFG = Path(os.environ.get("APPDATA", str(Path.home()))) / "AsenaDPI"
BLACKLIST = CFG / "blacklist.txt"
CLEAN = CFG / "hostlist_clean.txt"
SETTINGS = CFG / "settings.conf"
STRAT_FILE = CFG / "tcp443.conf"
LOG = CFG / "winws.log"
REPO_FILE = CFG / "repo_dir"
LAST_UPDATE_CHECK = CFG / "last_update_check"
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


_TRAY = None   # QSystemTrayIcon referansi (Windows'ta notify-send yok -> tray balonu)


def notify(title, body):
    try:
        if _TRAY is not None:
            _TRAY.showMessage(title, body, QSystemTrayIcon.Information, 5000)
    except Exception:
        pass


def to_cygpath(p):
    """C:\\X\\Y -> /cygdrive/c/X/Y (bosluklu yollar korunur)."""
    p = str(p)
    return "/cygdrive/" + p[0].lower() + p[2:].replace("\\", "/")


def parse_best_strategy(text):
    """blockcheck ciktisindan en iyi TLS1.3 winws/nfqws stratejisini sec (agdan-bagimsiz fooling
    tercih; autottl bizim kurulumda guvenilmez). Yalniz --dpi-desync... kismini dondurur."""
    import re
    lines = text.splitlines()
    cands = []
    for i, l in enumerate(lines):
        m = re.search(r'curl_test_https_tls13.*?(?:nfqws|winws)\s+(.*)$', l)
        if m and any("AVAILABLE" in lines[j] for j in range(i + 1, min(i + 3, len(lines)))):
            cands.append(m.group(1))
    insum = False
    for l in lines:
        if "* SUMMARY" in l:
            insum = True
        if insum:
            m = re.search(r'curl_test_https_tls13.*?(?:nfqws|winws)\s+(.*)$', l)
            if m:
                cands.append(m.group(1))
    out = []
    for c in cands:
        idx = c.find("--dpi-desync")   # --wf-* kismini at (start_on kendi ekliyor)
        if idx >= 0:
            out.append(c[idx:].strip())

    def score(s):
        sc = 0.0
        if "autottl" in s: sc -= 5
        if re.search(r'--dpi-desync-ttl=\d', s) and "autottl" not in s: sc -= 1
        if "fooling=md5sig" in s: sc += 4
        elif "fooling=badseq" in s: sc += 3
        elif "fooling=" in s: sc += 2
        if any(x in s for x in ("fakedsplit", "fakeddisorder", "multidisorder")): sc += 2
        sc -= s.count("--") * 0.1
        return sc

    seen, uniq = set(), []
    for c in out:
        if c and c not in seen:
            seen.add(c); uniq.append(c)
    if not uniq:
        return None
    uniq.sort(key=score, reverse=True)
    return uniq[0]


def load_settings() -> dict:
    s = dict(DEFAULTS)
    try:
        for line in SETTINGS.read_text(encoding="utf-8-sig").splitlines():
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
        for line in STRAT_FILE.read_text(encoding="utf-8-sig").splitlines():
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
        for ln in BLACKLIST.read_text(encoding="utf-8-sig").splitlines():
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
        subprocess.Popen(winws_args(s), cwd=str(WINWS_DIR), stdout=lf, stderr=lf,
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
    """Herkesin anlayacagi hos popup: buyuk durum yazisi + animasyonlu ilerleme + sade sonuc.
    Ham blockcheck/git ciktisi 'Detaylar'da gizli. optimize ve update icin ortak."""
    def __init__(self, tray):
        super().__init__()
        self.tray = tray; self.proc = None; self._on_done = None
        self.setWindowTitle("AsenaDPI")
        self.setWindowIcon(make_icon(True)); self.setMinimumWidth(460)
        self.setStyleSheet(f"""
            QWidget {{ background:#1b1f27; color:#e6e9ee; font-size:12px; }}
            QLabel#title {{ font-size:16px; font-weight:700; }}
            QLabel#sub {{ color:#a6adc8; }}
            QProgressBar {{ background:#2a2f37; border:none; border-radius:6px; height:10px; }}
            QProgressBar::chunk {{ background:{ACCENT}; border-radius:6px; }}
            QPushButton {{ background:#2a2f37; border:1px solid #3a414c; border-radius:6px; padding:7px 14px; }}
            QPushButton:hover {{ background:#333a44; }}
            QPlainTextEdit {{ background:#0e1116; color:#8fb8ab; border:1px solid #262c36;
                              border-radius:6px; font-family:Consolas,monospace; font-size:10px; }}
        """)
        v = QVBoxLayout(self); v.setContentsMargins(20, 18, 20, 16); v.setSpacing(11)
        self.title = QLabel("Hazır"); self.title.setObjectName("title")
        self.sub = QLabel(""); self.sub.setObjectName("sub"); self.sub.setWordWrap(True)
        v.addWidget(self.title); v.addWidget(self.sub)
        self.bar = QProgressBar(); self.bar.setTextVisible(False); v.addWidget(self.bar)
        self.out = QPlainTextEdit(); self.out.setReadOnly(True); self.out.setFixedHeight(170); self.out.hide()
        v.addWidget(self.out)
        row = QHBoxLayout()
        self.detail_btn = QPushButton("Detayları göster"); self.detail_btn.setCheckable(True)
        self.detail_btn.toggled.connect(self._toggle_detail)
        row.addWidget(self.detail_btn); row.addStretch(1)
        self.btn_stop = QPushButton("Durdur"); self.btn_stop.clicked.connect(self.stop)
        self.btn_close = QPushButton("Kapat"); self.btn_close.clicked.connect(self.close)
        row.addWidget(self.btn_stop); row.addWidget(self.btn_close)
        v.addLayout(row)

    def _toggle_detail(self, on):
        self.out.setVisible(on)
        self.detail_btn.setText("Detayları gizle" if on else "Detayları göster")
        self.adjustSize()

    def run_cmd(self, program, args, workdir, title, sub, on_done):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.show(); self.raise_(); return
        self._on_done = on_done
        self.title.setText(title); self.sub.setText(sub); self.out.clear()
        self.bar.setRange(0, 0)   # belirsiz/animasyonlu (sure bilinmiyor)
        self.btn_stop.setEnabled(True)
        self.show(); self.raise_(); self.activateWindow()
        self.proc = QProcess(self); self.proc.setProcessChannelMode(QProcess.MergedChannels)
        if workdir:
            self.proc.setWorkingDirectory(workdir)
        self.proc.readyRead.connect(self._read); self.proc.finished.connect(self._done)
        self.proc.start(program, args)

    def _read(self):
        self.out.moveCursor(QTextCursor.End)
        self.out.insertPlainText(bytes(self.proc.readAll()).decode("utf-8", "replace"))
        self.out.moveCursor(QTextCursor.End)

    def _done(self, code, _st):
        self.btn_stop.setEnabled(False)
        self.bar.setRange(0, 100); self.bar.setValue(100)
        if self._on_done:
            cb = self._on_done; self._on_done = None; cb(code)
        self.tray.refresh()

    def set_result(self, title, sub):
        self.title.setText(title); self.sub.setText(sub)
        self.bar.setRange(0, 100); self.bar.setValue(100); self.btn_stop.setEnabled(False)

    def stop(self):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.proc.kill()
        self.set_result("Durduruldu", "İşlem iptal edildi.")

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
        global _TRAY; _TRAY = self.tray   # notify() balon bildirimi icin
        self.act_toggle = QAction("Bağlan", self.menu); self.act_toggle.triggered.connect(self.toggle)
        self.menu.addAction(self.act_toggle)
        a_set = QAction("Ayarlar…", self.menu); a_set.triggered.connect(self.open_settings); self.menu.addAction(a_set)
        a_opt = QAction("En iyi stratejiyi bul", self.menu); a_opt.triggered.connect(self.optimize); self.menu.addAction(a_opt)
        self.menu.addSeparator()
        a_bl = QAction("Blacklist düzenle…", self.menu); a_bl.triggered.connect(lambda: os.startfile(str(BLACKLIST))); self.menu.addAction(a_bl)
        a_log = QAction("Logu göster", self.menu); a_log.triggered.connect(lambda: os.startfile(str(LOG)) if LOG.exists() else None); self.menu.addAction(a_log)
        a_upd = QAction("Güncelle (GitHub)", self.menu); a_upd.triggered.connect(self.update); self.menu.addAction(a_upd)
        self.menu.addSeparator()
        a_q = QAction("Çıkış (DPI'ı durdur)", self.menu); a_q.triggered.connect(self.quit_app); self.menu.addAction(a_q)
        self.tray.setContextMenu(self.menu); self.tray.activated.connect(self.on_act); self.tray.show()
        self.t = QTimer(); self.t.timeout.connect(self.refresh); self.t.start(3000); self.refresh()
        QTimer.singleShot(8000, self._autocheck)

    def open_settings(self):
        if self.win is None: self.win = SettingsWindow(self)
        self.win.open_fresh()

    def optimize(self):
        if not (CYG_BASH.exists() and BLOCKCHECK_SH.exists()):
            QMessageBox.warning(None, "AsenaDPI",
                "Gerekli dosyalar eksik (blockcheck/cygwin). Kurulumu tamamlamak için\n"
                "yönetici PowerShell'de install.ps1'i tekrar çalıştır.")
            return
        # ANLAMLI/KOLAY girdi: blockcheck'in karışık promptları yerine tek sade soru
        dom, ok = QInputDialog.getText(
            None, "En iyi ayarı bul",
            "Hangi site için en iyi ayar aransın?\n"
            "(açılmayan siteyi yaz; birden çoksa boşlukla ayır)",
            text=OPTIMIZE_DOMAINS)
        if not ok or not dom.strip():
            return
        dom = " ".join(dom.split())
        if self.optwin is None:
            self.optwin = OptimizeWindow(self)
        # temiz DNS ac (blockcheck gercek IP'yi cozsun) + kendi winws'imizi durdur (karismasin)
        dns_doh_on()
        subprocess.run(["taskkill", "/f", "/im", "winws.exe"], creationflags=NO_WINDOW, capture_output=True)
        cyg = to_cygpath(BLOCKCHECK_SH.parent)
        cmd = ("cd '%s' && export DOMAINS='%s' ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 "
               "ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 SCANLEVEL=standard BATCH=1 IPV=4 "
               "REPEATS=1 PARALLEL=0; yes '' | ./blockcheck.sh") % (cyg, dom)
        self.optwin.run_cmd(
            str(CYG_BASH), ["--login", "-c", cmd], str(BLOCKCHECK_SH.parent),
            "En iyi ayar aranıyor…",
            f"'{dom}' için ağ taranıyor; en iyi DPI ayarı bulunuyor. Birkaç dakika sürebilir.",
            self._optimize_done)

    def _optimize_done(self, code):
        best = parse_best_strategy(self.optwin.out.toPlainText())
        if best:
            try:
                CFG.mkdir(parents=True, exist_ok=True)
                STRAT_FILE.write_text("# blockcheck otomatik buldu\n" + best + "\n", encoding="utf-8")
            except Exception:
                pass
            self.optwin.set_result("✅ En iyi ayar bulundu ve uygulandı",
                "Ağın için en iyi DPI ayarı seçilip etkinleştirildi. Şimdi siteyi/uygulamayı dene.")
        else:
            self.optwin.set_result("ℹ️ Ekstra ayara gerek yok",
                "Bu ağda DPI engeli görünmüyor. DNS koruması (DoH) zaten yeterli — bağlan yeter.")
        start_on()   # winws'i (yeni strateji varsa onunla) + DoH ile yeniden baslat

    def _repo(self):
        try:
            r = REPO_FILE.read_text(encoding="utf-8-sig").strip()
            return r if r and os.path.isdir(os.path.join(r, ".git")) else None
        except OSError:
            return None

    def update(self):
        repo = self._repo()
        if not repo:
            QMessageBox.warning(None, "AsenaDPI",
                "Güncelleme kaynağı bulunamadı. install.ps1'i bir kez daha çalıştır.")
            return
        if self.optwin is None: self.optwin = OptimizeWindow(self)

        def done(code):
            if code != 0:
                self.optwin.set_result("Güncelleme başarısız",
                    "GitHub'a ulaşılamadı veya git hata verdi. Detaylara bakabilirsin.")
                return
            try:
                shutil.copy2(os.path.join(repo, "windows", "asena-dpi-tray.pyw"),
                             str(INSTALL_DIR / "asena-dpi-tray.pyw"))
                self.optwin.set_result("✅ Güncellendi",
                    "Yeni sürüm kuruldu. Uygulama birazdan yeniden başlatılıyor…")
                QTimer.singleShot(1400, self._restart)
            except Exception as e:
                self.optwin.set_result("Kopyalama hatası", str(e))
        self.optwin.run_cmd("git", ["-C", repo, "pull", "--ff-only"], repo,
                            "Güncelleniyor…", "GitHub'dan en son sürüm indiriliyor.", done)

    def quit_app(self):
        # cikista DPI'i TAMAMEN durdur (winws + QUIC block + DoH geri al) -> arka planda kalmasin
        try:
            stop_off()
        except Exception:
            pass
        self.app.quit()

    def _restart(self):
        # yeni tray'i baslat, sonra eskisini kapat (os.execv Windows'ta guvenilmez)
        try:
            DETACHED = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
            subprocess.Popen([sys.executable] + sys.argv, creationflags=DETACHED, close_fds=True)
        except Exception:
            pass
        QTimer.singleShot(400, self.app.quit)

    def _autocheck(self):
        threading.Thread(target=self._do_autocheck, daemon=True).start()

    def _do_autocheck(self):
        try:
            repo = self._repo()
            if not repo:
                return
            try:
                if time.time() - float(LAST_UPDATE_CHECK.read_text(encoding="utf-8")) < 21600:
                    return
            except (OSError, ValueError):
                pass
            run_hidden(["git", "-C", repo, "fetch", "--quiet"])
            r = run_hidden(["git", "-C", repo, "rev-list", "--count", "HEAD..@{u}"])
            try:
                LAST_UPDATE_CHECK.write_text(str(time.time()), encoding="utf-8")
            except OSError:
                pass
            n = (r.stdout or "0").strip()
            if n.isdigit() and int(n) > 0:
                subprocess.Popen(["msg", "*", f"AsenaDPI: {n} yeni sürüm var — sağ tık > Güncelle"],
                                 creationflags=NO_WINDOW)
        except Exception:
            pass

    def on_act(self, reason):
        if reason == QSystemTrayIcon.Trigger: self.toggle()   # sol tik = ac/kapat

    def toggle(self):
        if is_on(): stop_off()
        else: start_on()
        QTimer.singleShot(600, self.refresh)

    def refresh(self):
        on = is_on()
        self.tray.setIcon(self.icon_on if on else self.icon_off)
        self.act_toggle.setText("Bağlantıyı kes" if on else "Bağlan")
        self.tray.setToolTip(f"AsenaDPI: {'AÇIK' if on else 'kapalı'}  (sol tık: aç/kapat)")


def main():
    app = QApplication(sys.argv); app.setQuitOnLastWindowClosed(False); app.setApplicationName("AsenaDPI")
    _t = AsenaTray(app); sys.exit(app.exec())


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        try:
            CFG.mkdir(parents=True, exist_ok=True)
            (CFG / "tray-error.log").write_text(traceback.format_exc(), encoding="utf-8")
        except Exception:
            pass
        raise
