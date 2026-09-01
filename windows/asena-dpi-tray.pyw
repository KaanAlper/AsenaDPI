#!/usr/bin/env python3
"""
AsenaDPI - Windows tray + TEK kontrol penceresi (winws/WinDivert + DoH DNS + blockcheck).
Logon'da YONETICI olarak baslar (scheduled task, highest) -> winws + DNS'i dogrudan yonetir.
SOL TIK: ac/kapat.  SAG TIK: menu -> Kontrol Paneli (tek pencere, sekmeli).
Butun akislar (ayarlar / en iyi ayar-blockcheck / guncelle) TEK pencerede, ortak aktivite alaninda.
"""
import os, sys, subprocess, shutil, threading, time
from pathlib import Path

from PySide6.QtWidgets import (
    QApplication, QSystemTrayIcon, QMenu, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QRadioButton, QCheckBox, QPushButton, QButtonGroup, QFrame, QPlainTextEdit,
    QProgressBar, QTabWidget, QLineEdit, QMessageBox,
)
from PySide6.QtGui import QIcon, QAction, QPainter, QColor, QBrush, QPen, QPixmap, QPainterPath, QFont, QTextCursor, QImage
from PySide6.QtCore import QTimer, Qt, QPointF, QProcess, QRect

INSTALL_DIR = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "AsenaDPI"
WINWS_DIR = INSTALL_DIR / "zapret-winws"
WINWS = WINWS_DIR / "winws.exe"
CYG_BASH = INSTALL_DIR / "cygwin" / "bin" / "bash.exe"
BLOCKCHECK_SH = INSTALL_DIR / "blockcheck" / "zapret" / "blockcheck.sh"
ICO_PATH = INSTALL_DIR / "asena-dpi.ico"
OPTIMIZE_DOMAINS = "discord.com gateway.discord.gg"

CFG = Path(os.environ.get("APPDATA", str(Path.home()))) / "AsenaDPI"
BLACKLIST = CFG / "blacklist.txt"
CLEAN = CFG / "hostlist_clean.txt"
SETTINGS = CFG / "settings.conf"
STRAT_FILE = CFG / "tcp443.conf"
LOG = CFG / "winws.log"
REPO_FILE = CFG / "repo_dir"
LAST_UPDATE_CHECK = CFG / "last_update_check"
AUTOCONNECT_FILE = CFG / "autoconnect"
NO_WINDOW = 0x08000000

DEFAULTS = {"MODE": "blacklist", "HTTP": "1", "HTTP2": "1", "HTTP3": "bypass"}
LBL = {
    "MODE": ("Mod", {"blacklist": "Blacklist", "full": "Full"}),
    "HTTP": ("HTTP (80)", {"1": "acik", "0": "kapali"}),
    "HTTP2": ("HTTP/2 (443)", {"1": "acik", "0": "kapali"}),
    "HTTP3": ("HTTP/3-QUIC", {"bypass": "Bypass", "off": "Kapali", "block": "Engelle"}),
}
ACCENT = "#26A69A"
_TRAY = None


# ----------------------------------------------------------------- yardimcilar
def run_hidden(args, **kw):
    return subprocess.run(args, creationflags=NO_WINDOW, capture_output=True, text=True, **kw)


def ps(cmd):
    return run_hidden(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd])


def notify(title, body):
    try:
        if _TRAY is not None:
            _TRAY.showMessage(title, body, QSystemTrayIcon.Information, 5000)
    except Exception:
        pass


def to_cygpath(p):
    p = str(p)
    return "/cygdrive/" + p[0].lower() + p[2:].replace("\\", "/")


def parse_best_strategy(text):
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
        idx = c.find("--dpi-desync")
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
    # VARSAYILAN YOK: bos ise "" (temiz kurulum -> 'En iyi ayar' bulana kadar 443 desync yok).
    try:
        for line in STRAT_FILE.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    except FileNotFoundError:
        pass
    return ""


def save_strategy(s: str):
    CFG.mkdir(parents=True, exist_ok=True)
    STRAT_FILE.write_text("# AsenaDPI TCP443 stratejisi\n" + s.strip() + "\n", encoding="utf-8")


def autostart_enabled() -> bool:
    return run_hidden(["schtasks", "/query", "/tn", "AsenaDPI-Tray"]).returncode == 0


def set_autostart(on: bool):
    if on:
        tr = str(INSTALL_DIR / "asena-dpi-tray.pyw")
        run_hidden(["schtasks", "/create", "/tn", "AsenaDPI-Tray",
                    "/tr", f'"{sys.executable}" "{tr}"', "/sc", "onlogon", "/rl", "highest", "/f"])
    else:
        run_hidden(["schtasks", "/delete", "/tn", "AsenaDPI-Tray", "/f"])


def autoconnect_on() -> bool:
    return AUTOCONNECT_FILE.exists()


def set_autoconnect(on: bool):
    if on:
        CFG.mkdir(parents=True, exist_ok=True); AUTOCONNECT_FILE.write_text("1", encoding="utf-8")
    else:
        try:
            AUTOCONNECT_FILE.unlink()
        except FileNotFoundError:
            pass


def clean_hostlist():
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
    strat = tcp443_strategy()
    do_80  = s["HTTP"] == "1"
    # 443 sadece GECERLI strateji varsa islenir (bos/gecersiz -> hic yakalama; temiz kurulum/kalkan)
    do_443 = s["HTTP2"] == "1" and "--dpi-desync" in strat
    # WinDivert filtresi (--wf-*): SADECE gercekten islenecek portlari yakala (bos -> 'error opening filter')
    tcp_ports = ([ "80"] if do_80 else []) + (["443"] if do_443 else [])
    if tcp_ports:
        a.append("--wf-tcp=" + ",".join(tcp_ports))
    if s["HTTP3"] == "bypass":
        a.append("--wf-udp=443")
    if do_80:
        a += ["--filter-tcp=80", "--dpi-desync=fake,multisplit", "--dpi-desync-split-pos=method+2",
              "--dpi-desync-fooling=md5sig"] + hl + ["--new"]
    if do_443:
        a += ["--filter-tcp=443"] + strat.split() + hl + ["--new"]
    if s["HTTP3"] == "bypass":
        a += ["--filter-udp=443", "--dpi-desync=fake", "--dpi-desync-repeats=6"] + hl + ["--new"]
    if a and a[-1] == "--new":
        a.pop()
    return a


def _windivert_release():
    # winws oldurulunce WinDivert64.sys surucusu hemen unload OLMAYABILIR -> yeni winws
    # 'windivert: error opening filter: (null)' verip ANINDA cikar (baglandi-sonra-kapandi).
    # Surucu servisini durdurup serbest birak (servis adi surume gore degisir; hepsini dene).
    for svc in ("WinDivert", "WinDivert1.4", "windivert"):
        subprocess.run(["sc", "stop", svc], creationflags=NO_WINDOW, capture_output=True)

def _launch_winws(s):
    lf = open(LOG, "w", encoding="utf-8", errors="replace")
    return subprocess.Popen(winws_args(s), cwd=str(WINWS_DIR), stdout=lf, stderr=lf, creationflags=NO_WINDOW)

def start_on():
    s = load_settings()
    subprocess.run(["taskkill", "/f", "/im", "winws.exe"], creationflags=NO_WINDOW, capture_output=True)
    _windivert_release()
    time.sleep(1.5)                       # surucu tam bosalsin
    quic_block(s["HTTP3"] == "block")
    if len(winws_args(s)) > 1:            # islenecek filtre var mi? (yoksa winws bos filtreyle coker)
        p = _launch_winws(s)
        time.sleep(1.3)
        if p.poll() is not None:          # hemen oldu -> WinDivert hala kilitli, bir kez daha dene
            _windivert_release(); time.sleep(2.5); _launch_winws(s)
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


def app_qicon() -> QIcon:
    try:
        if ICO_PATH.exists():
            ic = QIcon(str(ICO_PATH))
            if not ic.isNull():
                return ic
    except Exception:
        pass
    return make_icon(True)


def dim_icon(icon: QIcon) -> QIcon:
    """Kapali durum icon'u: GRI (tam opak) -> gorev cubugunda gorunur kalir, acik-renkli
    halden ayirt edilir (saydamlik gostermez, hayalet olmaz)."""
    try:
        pm = icon.pixmap(64, 64)
        img = pm.toImage().convertToFormat(QImage.Format_ARGB32)
        for y in range(img.height()):
            for x in range(img.width()):
                c = img.pixelColor(x, y)
                if c.alpha() == 0:
                    continue
                g = int(0.30 * c.red() + 0.59 * c.green() + 0.11 * c.blue())
                c.setRgb(g, g, g, c.alpha())
                img.setPixelColor(x, y, c)
        return QIcon(QPixmap.fromImage(img))
    except Exception:
        return icon


def tray_mark(on: bool) -> QIcon:
    """Tray icon'u: keskin, OKUNAKLI 'DPI' karo (16px'te bile ayirt edilir). Kurt+DPI logosu
    detayli oldugundan kucukte bulaniklasiyor; tepside bunun yerine sade karo. Acik=teal, kapali=gri."""
    pm = QPixmap(64, 64); pm.fill(Qt.transparent)
    p = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
    bg = QColor(38, 166, 154) if on else QColor(96, 102, 110)
    p.setPen(QPen(QColor(255, 255, 255), 3)); p.setBrush(QBrush(bg))
    p.drawRoundedRect(3, 8, 58, 48, 12, 12)              # beyaz kenarli karo (koyu taskbar'da belirgin)
    f = QFont("Arial", 1); f.setBold(True); f.setPixelSize(30)
    p.setFont(f); p.setPen(QColor(255, 255, 255))
    p.drawText(QRect(0, 8, 64, 48), Qt.AlignCenter, "DPI")
    p.end()
    return QIcon(pm)


def tray_icons():
    """(on, off) tray ikonlari: kurt+DPI LOGOsu (acik renkli / kapali gri). Logo yoksa DPI karosu."""
    base = app_qicon()
    if ICO_PATH.exists() and not base.isNull():
        return base, dim_icon(base)
    return tray_mark(True), tray_mark(False)


def _sec(t):
    l = QLabel(t); f = QFont(); f.setBold(True); f.setPointSize(10); l.setFont(f)
    l.setStyleSheet(f"color:{ACCENT}; margin-top:2px;"); return l


def _hl():
    f = QFrame(); f.setFrameShape(QFrame.HLine); f.setStyleSheet("color:#2a2f37;"); return f


# ----------------------------------------------------------------- TEK PENCERE
class AppWindow(QWidget):
    def __init__(self, tray):
        super().__init__()
        self.tray = tray; self._busy = False; self.proc = None; self._on_done = None
        self.saved = load_settings(); self.pending = dict(self.saved)
        self.setWindowTitle("AsenaDPI"); self.setWindowIcon(app_qicon())
        self.setMinimumWidth(500)
        self.setStyleSheet(f"""
            QWidget {{ background:#1b1f27; color:#e6e9ee; font-size:12px; }}
            QLabel#brand {{ font-size:15px; font-weight:800; }}
            QTabWidget::pane {{ border:1px solid #2a303a; border-radius:8px; top:-1px; }}
            QTabBar::tab {{ background:#20252f; padding:7px 16px; margin-right:3px;
                            border-top-left-radius:7px; border-top-right-radius:7px; color:#a6adc8; }}
            QTabBar::tab:selected {{ background:#2a303a; color:#e6e9ee; }}
            QRadioButton, QCheckBox {{ padding:3px 0; }}
            QLineEdit {{ background:#0e1116; border:1px solid #333a44; border-radius:6px; padding:6px; }}
            QProgressBar {{ background:#2a2f37; border:none; border-radius:6px; height:9px; }}
            QProgressBar::chunk {{ background:{ACCENT}; border-radius:6px; }}
            QPushButton {{ background:#2a2f37; border:1px solid #3a414c; border-radius:6px; padding:7px 14px; }}
            QPushButton:hover {{ background:#333a44; }}
            QPushButton#primary {{ background:{ACCENT}; border:none; color:#04201c; font-weight:bold; }}
            QPushButton#primary:disabled {{ background:#2a2f37; color:#5b636e; }}
            QPlainTextEdit {{ background:#0e1116; color:#8fb8ab; border:1px solid #262c36;
                              border-radius:6px; font-family:Consolas,monospace; font-size:10px; }}
        """)
        root = QVBoxLayout(self); root.setContentsMargins(16, 14, 16, 14); root.setSpacing(10)

        # --- baslik: logo + isim + durum + guc ---
        hb = QHBoxLayout()
        logo = QLabel(); logo.setPixmap(app_qicon().pixmap(30, 30)); hb.addWidget(logo)
        hb.addWidget(QLabel("AsenaDPI", objectName="brand"))
        hb.addStretch(1)
        self.status = QLabel(); self.status.setStyleSheet("font-weight:bold;")
        self.btn_power = QPushButton("Baglan"); self.btn_power.clicked.connect(self.toggle_power)
        btn_x = QPushButton("✕"); btn_x.setFixedWidth(34); btn_x.setToolTip("Kapat (Esc)"); btn_x.clicked.connect(self.close)
        hb.addWidget(self.status); hb.addWidget(self.btn_power); hb.addWidget(btn_x)
        root.addLayout(hb)

        # --- sekmeler ---
        self.tabs = QTabWidget()
        self.tabs.addTab(self._tab_settings(), "Ayarlar")
        self.tabs.addTab(self._tab_optimize(), "En iyi ayar")
        self.tabs.addTab(self._tab_other(), "Diger")
        root.addWidget(self.tabs)

        # --- ORTAK aktivite alani (blockcheck/guncelle ciktisi hepsi burada) ---
        root.addWidget(_hl())
        self.act = QLabel("Hazir."); self.act.setWordWrap(True); self.act.setStyleSheet("color:#a6adc8;")
        root.addWidget(self.act)
        self.bar = QProgressBar(); self.bar.setTextVisible(False); self.bar.hide()
        root.addWidget(self.bar)
        drow = QHBoxLayout()
        self.detail_btn = QPushButton("Detaylar"); self.detail_btn.setCheckable(True)
        self.detail_btn.toggled.connect(self._toggle_detail); self.detail_btn.hide()
        drow.addWidget(self.detail_btn); drow.addStretch(1)
        root.addLayout(drow)
        self.out = QPlainTextEdit(); self.out.setReadOnly(True); self.out.setFixedHeight(160); self.out.hide()
        root.addWidget(self.out)

        self._sync(); self.refresh()
        self.t = QTimer(self); self.t.timeout.connect(self.refresh); self.t.start(2500)

    # ---------- sekme: Ayarlar ----------
    def _tab_settings(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(7)
        v.addWidget(_sec("Mod"))
        self.g_mode = QButtonGroup(self)
        self.rb_bl = QRadioButton("Blacklist  -  yalniz listedeki siteler")
        self.rb_full = QRadioButton("Full  -  tum trafik")
        for rb, val in ((self.rb_bl, "blacklist"), (self.rb_full, "full")):
            self.g_mode.addButton(rb); rb.toggled.connect(lambda c, x=val: c and self._setp("MODE", x)); v.addWidget(rb)
        v.addWidget(_sec("HTTP/3 - QUIC"))
        self.g_h3 = QButtonGroup(self)
        self.rb_bypass = QRadioButton("Bypass  -  DPI'dan gecirmeye calis")
        self.rb_h3off = QRadioButton("Kapali  -  dokunma")
        self.rb_block = QRadioButton("Engelle  -  QUIC kes -> TCP'ye dus (oyun)")
        for rb, val in ((self.rb_bypass, "bypass"), (self.rb_h3off, "off"), (self.rb_block, "block")):
            self.g_h3.addButton(rb); rb.toggled.connect(lambda c, x=val: c and self._setp("HTTP3", x)); v.addWidget(rb)
        v.addWidget(_sec("Gelismis"))
        self.cb_http = QCheckBox("HTTP (80)"); self.cb_http.toggled.connect(lambda c: self._setp("HTTP", "1" if c else "0"))
        self.cb_http2 = QCheckBox("HTTP/2 (443) - kapatma"); self.cb_http2.toggled.connect(lambda c: self._setp("HTTP2", "1" if c else "0"))
        v.addWidget(self.cb_http); v.addWidget(self.cb_http2)
        # DPI stratejisi - metin olarak duzenlenebilir; degisince sagda ✓ (uygula) + ↩ (geri al)
        v.addWidget(_sec("DPI stratejisi (gelismis)"))
        srow = QHBoxLayout()
        self.strat = QLineEdit(tcp443_strategy()); self.strat.textEdited.connect(self._strat_edited)
        self.btn_sok = QPushButton("✓"); self.btn_sok.setFixedWidth(36); self.btn_sok.setObjectName("primary")
        self.btn_sok.clicked.connect(self._strat_apply)
        self.btn_sundo = QPushButton("↩"); self.btn_sundo.setFixedWidth(36); self.btn_sundo.clicked.connect(self._strat_revert)
        srow.addWidget(self.strat); srow.addWidget(self.btn_sok); srow.addWidget(self.btn_sundo)
        v.addLayout(srow)
        self._strat_saved = self.strat.text(); self.btn_sok.hide(); self.btn_sundo.hide()
        v.addWidget(_sec("Baslangic"))
        self.cb_autostart = QCheckBox("Acilista baslat"); self.cb_autostart.toggled.connect(self._on_autostart)
        self.cb_autoconn = QCheckBox("Otomatik baglan (acilista DPI'i ac)"); self.cb_autoconn.toggled.connect(self._on_autoconnect)
        v.addWidget(self.cb_autostart); v.addWidget(self.cb_autoconn)
        self.diff = QLabel("Degisiklik yok"); self.diff.setWordWrap(True)
        self.diff.setStyleSheet("color:#c7ccd4; background:#181c23; border:1px solid #262c36; border-radius:8px; padding:8px;")
        v.addWidget(self.diff)
        self.btn_apply = QPushButton("Degisiklikleri uygula"); self.btn_apply.setObjectName("primary")
        self.btn_apply.clicked.connect(self.apply_settings)
        v.addWidget(self.btn_apply); v.addStretch(1)
        return w

    # ---------- sekme: En iyi ayar (blockcheck) ----------
    def _tab_optimize(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(8)
        v.addWidget(_sec("En iyi ayari bul"))
        v.addWidget(QLabel("Acilmayan siteyi yaz (birden coksa boslukla ayir); AsenaDPI agini\n"
                           "tarayip en iyi ayari bulur ve otomatik uygular."))
        self.dom = QLineEdit(OPTIMIZE_DOMAINS)
        v.addWidget(self.dom)
        self.btn_opt = QPushButton("Taramayi baslat"); self.btn_opt.setObjectName("primary")
        self.btn_opt.clicked.connect(self.start_optimize)
        v.addWidget(self.btn_opt); v.addStretch(1)
        return w

    # ---------- sekme: Diger ----------
    def _tab_other(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(8)
        v.addWidget(_sec("Bakim"))
        b1 = QPushButton("Guncelle (GitHub)"); b1.clicked.connect(self.start_update); v.addWidget(b1)
        b2 = QPushButton("DNS'i onar"); b2.clicked.connect(self.repair_dns); v.addWidget(b2)
        b3 = QPushButton("Blacklist duzenle"); b3.clicked.connect(lambda: os.startfile(str(BLACKLIST))); v.addWidget(b3)
        b4 = QPushButton("winws logu"); b4.clicked.connect(lambda: os.startfile(str(LOG)) if LOG.exists() else None); v.addWidget(b4)
        v.addStretch(1)
        return w

    # ---------- ortak aktivite ----------
    def _toggle_detail(self, on):
        self.out.setVisible(on)
        self.detail_btn.setText("Detaylari gizle" if on else "Detaylar")
        self.adjustSize()

    def _run(self, program, args, workdir, msg, on_done):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            return
        self._on_done = on_done
        self.act.setText(msg); self.out.clear()
        self.bar.show(); self.bar.setRange(0, 0)
        self.detail_btn.show(); self._busy = True; self.adjustSize()
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
        self._busy = False
        cb = self._on_done; self._on_done = None
        if cb:
            cb(code)
        else:
            self.bar.hide(); self.adjustSize()   # islem bitti -> cubugu gizle
        self.refresh()

    def set_result(self, msg):
        self.act.setText(msg); self.bar.hide(); self.adjustSize()

    # ---------- guc / durum ----------
    def refresh(self):
        on = is_on()
        self.status.setText("ACIK" if on else "kapali")
        self.status.setStyleSheet(f"font-weight:bold; color:{'#3ddc97' if on else '#8a929c'};")
        self.btn_power.setText("Kapat" if on else "Baglan")

    def _async(self, fn, done_msg):
        """Bloklayan islemi (start_on/stop_off - PowerShell cagrilari) THREAD'de calistir -> UI donmaz.
        Qt cagrilari sadece ana-thread timer'inda (worker Qt'ye dokunmaz)."""
        if self._busy:
            return
        self._busy = True; self._pending_msg = None
        def work():
            try: fn()
            except Exception: pass
            self._pending_msg = done_msg
        threading.Thread(target=work, daemon=True).start()
        self._poll = QTimer(self); self._poll.setInterval(200)
        def check():
            if self._pending_msg is not None:
                self._poll.stop(); self._busy = False
                self.act.setText(self._pending_msg); self._pending_msg = None
                self.refresh(); self.tray.refresh(); self._update_diff()
        self._poll.timeout.connect(check); self._poll.start()

    def toggle_power(self):
        if self._busy: return
        if is_on():
            self.act.setText("Kapatiliyor..."); self._async(stop_off, "Kapatildi.")
        else:
            save_settings(self.pending); self.saved = dict(self.pending)
            self.act.setText("Baglaniyor..."); self._async(start_on, "Baglandi.")
        self._update_diff()

    def _strat_edited(self, _=None):
        dirty = self.strat.text().strip() != self._strat_saved.strip()
        self.btn_sok.setVisible(dirty); self.btn_sundo.setVisible(dirty)

    def _strat_apply(self):
        if self._busy: return
        s = self.strat.text().strip()          # bos olabilir: 443 desync'siz (sadece DNS/HTTP/QUIC)
        save_strategy(s); self._strat_saved = s; self.btn_sok.hide(); self.btn_sundo.hide()
        done_msg = "Strateji temizlendi (443 desync kapali)." if not s else "Strateji uygulandi."
        save_msg = "Temizlendi ve kaydedildi (443 desync kapali)." if not s else "Strateji kaydedildi."
        if is_on():
            self.act.setText("Uygulaniyor..."); self._async(lambda: (stop_off(), start_on()), done_msg)
        else:
            self.act.setText(save_msg)

    def _strat_revert(self):
        self.strat.setText(self._strat_saved); self.btn_sok.hide(); self.btn_sundo.hide()

    def _on_autostart(self, c):
        set_autostart(c)
        self.cb_autoconn.setEnabled(c)
        if not c and self.cb_autoconn.isChecked():
            self.cb_autoconn.setChecked(False)
        self.act.setText("Acilista baslat: " + ("acik" if c else "kapali"))

    def _on_autoconnect(self, c):
        set_autoconnect(c and self.cb_autostart.isChecked())
        self.act.setText("Otomatik baglan: " + ("acik" if c and self.cb_autostart.isChecked() else "kapali"))

    # ---------- ayarlar ----------
    def _setp(self, k, v): self.pending[k] = v; self._update_diff()

    def _sync(self):
        p = self.pending
        self.rb_bl.setChecked(p["MODE"] != "full"); self.rb_full.setChecked(p["MODE"] == "full")
        self.rb_bypass.setChecked(p["HTTP3"] == "bypass"); self.rb_h3off.setChecked(p["HTTP3"] == "off")
        self.rb_block.setChecked(p["HTTP3"] == "block")
        self.cb_http.setChecked(p["HTTP"] == "1"); self.cb_http2.setChecked(p["HTTP2"] == "1")
        self._update_diff()

    def _update_diff(self):
        rows = []
        for k in ("MODE", "HTTP3", "HTTP", "HTTP2"):
            if self.pending[k] != self.saved[k]:
                name, vmap = LBL[k]
                rows.append(f"- {name}:  {vmap[self.saved[k]]}  ->  {vmap[self.pending[k]]}")
        self.diff.setText("\n".join(rows) if rows else "Degisiklik yok")
        self.btn_apply.setEnabled(bool(rows))

    def apply_settings(self):
        if self._busy or self.pending == self.saved: return
        save_settings(self.pending); self.saved = dict(self.pending); self._update_diff()
        if is_on():
            self.act.setText("Uygulaniyor..."); self._async(lambda: (stop_off(), start_on()), "Ayarlar uygulandi.")
        else:
            self.act.setText("Ayarlar kaydedildi.")

    # ---------- en iyi ayar ----------
    def start_optimize(self):
        if self._busy: return
        if not (CYG_BASH.exists() and BLOCKCHECK_SH.exists()):
            self.set_result("Gerekli dosyalar eksik (blockcheck/cygwin). install.ps1'i tekrar calistir.")
            return
        dom = " ".join(self.dom.text().split()) or OPTIMIZE_DOMAINS
        self.tabs.setCurrentIndex(1)
        dns_doh_on()
        subprocess.run(["taskkill", "/f", "/im", "winws.exe"], creationflags=NO_WINDOW, capture_output=True)
        cyg = to_cygpath(BLOCKCHECK_SH.parent)
        cmd = ("cd '%s' && export DOMAINS='%s' ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 "
               "ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 SCANLEVEL=standard BATCH=1 IPV=4 "
               "REPEATS=1 PARALLEL=0; yes '' | ./blockcheck.sh") % (cyg, dom)
        self._run(str(CYG_BASH), ["--login", "-c", cmd], str(BLOCKCHECK_SH.parent),
                  f"'{dom}' icin en iyi ayar araniyor... birkac dakika surebilir.", self._optimize_done)

    def _optimize_done(self, code):
        out = self.out.toPlainText()
        low = out.lower()
        best = parse_best_strategy(out)
        # blockcheck GERCEKTEN kostu mu? (ozet/curl_test/available isaretleri). Bir kac saniyede
        # cikip hic bu isaretleri uretmediyse test BASARISIZ demektir -> sakin 'DNS yeter' deme.
        ran = ("summary" in low) or ("curl_test" in low) or ("available" in low)
        if best:
            try:
                CFG.mkdir(parents=True, exist_ok=True)
                STRAT_FILE.write_text("# blockcheck otomatik buldu\n" + best + "\n", encoding="utf-8")
                if hasattr(self, "strat"):        # bulunan strateji arayuze de yansisin
                    self.strat.setText(best); self._strat_saved = best
                    self.btn_sok.hide(); self.btn_sundo.hide()
            except Exception:
                pass
            self.set_result("En iyi ayar bulundu ve uygulandi. Simdi siteyi/uygulamayi dene.")
        elif not ran:
            # blockcheck calismadi/hemen cikti -> YANLIS 'DNS yeter' mesaji verme.
            self.set_result("Test tamamlanamadi (blockcheck bir kac saniyede cikti - gerekli dosyalar "
                            "eksik olabilir: mdig/tpws). Detaylar'daki hataya bak ya da install.ps1'i "
                            "tekrar calistir. Su an yalniz DNS korumasi aktif.")
        else:
            # blockcheck kostu ama TCP'de DPI engeli bulamadi. Discord QUIC (UDP443) kullanir ve blockcheck
            # QUIC'i TEST ETMEZ; ag QUIC'i karadelige atiyorsa uygulama TCP'ye dusmeden takilir -> 'acilmiyor'.
            # Guvenli standart cozum: QUIC'i engelle -> uygulama TCP'ye duser (DoH + desync onu tasir).
            s = load_settings(); s["HTTP3"] = "block"; save_settings(s)
            self.set_result("TCP'de DPI engeli bulunamadi; DNS korumasi + QUIC(UDP) engeli uygulandi "
                            "(Discord QUIC yuzunden takilmasin diye). Discord'u simdi dene. "
                            "Gerekirse Ayarlar > HTTP/3'ten geri alabilirsin.")
        threading.Thread(target=start_on, daemon=True).start()   # bloklamadan geri ac

    # ---------- guncelle ----------
    def start_update(self):
        if self._busy: return
        repo = self.tray._repo()
        if not repo:
            self.set_result("Guncelleme kaynagi bulunamadi. install.ps1'i bir kez daha calistir.")
            return

        def done(code):
            if code != 0:
                self.set_result("Guncelleme basarisiz (GitHub'a ulasilamadi mi?). Detaylara bak.")
                return
            # 'zaten guncel' karari git HEAD'e degil, KURULU dosya repo ile ayni mi ona bakar
            # (dev makinede repo zaten HEAD'te olsa bile kurulu kopya eski olabilir).
            import filecmp
            src = os.path.join(repo, "windows", "asena-dpi-tray.pyw")
            dst = str(INSTALL_DIR / "asena-dpi-tray.pyw")
            same = os.path.exists(dst) and filecmp.cmp(src, dst, shallow=False)
            if same:
                self.set_result("Zaten guncel - yeni surum yok.")   # degisiklik yok -> restart YOK
                return
            try:
                shutil.copy2(src, dst)
                # ikon da guncellensin (Guncelle ile yeni logo gelsin)
                ico_src = os.path.join(repo, "windows", "asena-dpi.ico")
                if os.path.exists(ico_src):
                    shutil.copy2(ico_src, str(INSTALL_DIR / "asena-dpi.ico"))
                self.set_result("Guncellendi. Uygulama yeniden baslatiliyor...")
                QTimer.singleShot(1400, self.tray._restart)
            except Exception as e:
                self.set_result(f"Kopyalama hatasi: {e}")
        self.tabs.setCurrentIndex(2)
        self._run("git", ["-C", repo, "pull", "--ff-only"], repo,
                  "GitHub'dan en son surum kontrol ediliyor...", done)

    def repair_dns(self):
        if self._busy: return
        self.act.setText("DNS + DPI yeniden uygulaniyor..."); self._async(start_on, "DNS + DPI yeniden uygulandi.")

    def open_fresh(self, tab=0):
        self.saved = load_settings(); self.pending = dict(self.saved); self._sync()
        self.strat.setText(tcp443_strategy()); self._strat_saved = self.strat.text()
        self.btn_sok.hide(); self.btn_sundo.hide()
        for cb, val in ((self.cb_autostart, autostart_enabled()), (self.cb_autoconn, autoconnect_on())):
            cb.blockSignals(True); cb.setChecked(val); cb.blockSignals(False)
        self.cb_autoconn.setEnabled(self.cb_autostart.isChecked())
        self.refresh(); self.tabs.setCurrentIndex(tab)
        self.show(); self.raise_(); self.activateWindow()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.close()
        else:
            super().keyPressEvent(e)

    def closeEvent(self, e):
        if self.proc and self.proc.state() != QProcess.NotRunning:
            self.proc.kill()
        e.accept()


# ----------------------------------------------------------------- tray
class AsenaTray:
    def __init__(self, app):
        self.app = app; self.win = None
        self.icon_on, self.icon_off = tray_icons()   # kurt+DPI (acik renkli / kapali soluk)
        self.tray = QSystemTrayIcon(); self.menu = QMenu()
        global _TRAY; _TRAY = self.tray
        self.act_toggle = QAction("Baglan", self.menu); self.act_toggle.triggered.connect(self.toggle)
        self.menu.addAction(self.act_toggle)
        a_panel = QAction("Kontrol paneli...", self.menu); a_panel.triggered.connect(lambda: self.open(0)); self.menu.addAction(a_panel)
        a_opt = QAction("En iyi ayari bul", self.menu); a_opt.triggered.connect(lambda: self.open(1)); self.menu.addAction(a_opt)
        a_upd = QAction("Guncelle", self.menu); a_upd.triggered.connect(lambda: self.open(2)); self.menu.addAction(a_upd)
        self.menu.addSeparator()
        a_q = QAction("Cikis (DPI'i durdur)", self.menu); a_q.triggered.connect(self.quit_app); self.menu.addAction(a_q)
        self.tray.setContextMenu(self.menu); self.tray.activated.connect(self.on_act); self.tray.show()
        self.t = QTimer(); self.t.timeout.connect(self.refresh); self.t.start(3000); self.refresh()
        QTimer.singleShot(8000, self._autocheck)
        if autoconnect_on() and not is_on():
            QTimer.singleShot(1500, self._autoconnect)
        if not tcp443_strategy():                     # temiz kurulum: strateji yok -> yonlendir
            QTimer.singleShot(1800, self._first_setup_prompt)

    def _first_setup_prompt(self):
        if tcp443_strategy():
            return
        m = QMessageBox()
        m.setWindowTitle("AsenaDPI - kurulum")
        m.setWindowIcon(self.icon_on)
        m.setIcon(QMessageBox.Information)
        m.setText("Temiz kurulum: henuz DPI stratejisi yok.")
        m.setInformativeText("Agina en uygun ayari otomatik bulmak icin asagidaki dugmeye bas.\n"
                             "(Bulunana kadar yalniz DNS korumasi aktif; bazi siteler acilmayabilir.)")
        btn = m.addButton("En iyi ayari bul", QMessageBox.AcceptRole)
        m.addButton("Sonra", QMessageBox.RejectRole)
        m.exec()
        if m.clickedButton() is btn:
            self.open(1)

    def _autoconnect(self):
        if autoconnect_on() and not is_on():
            notify("AsenaDPI", "Otomatik baglaniyor...")
            threading.Thread(target=start_on, daemon=True).start()
            QTimer.singleShot(2500, self.refresh)

    def open(self, tab=0):
        if self.win is None: self.win = AppWindow(self)
        self.win.open_fresh(tab)

    def on_act(self, reason):
        if reason == QSystemTrayIcon.Trigger: self.toggle()

    def toggle(self):
        # ASYNC: start_on/stop_off (PowerShell) bloklamasin -> thread + zamanlanmis refresh
        if is_on():
            notify("AsenaDPI", "Kapatiliyor...")
            threading.Thread(target=stop_off, daemon=True).start()
        else:
            notify("AsenaDPI", "Baglaniyor...")
            threading.Thread(target=start_on, daemon=True).start()
        QTimer.singleShot(1500, self.refresh); QTimer.singleShot(3000, self.refresh)

    def refresh(self):
        on = is_on()
        self.tray.setIcon(self.icon_on if on else self.icon_off)
        self.act_toggle.setText("Baglantiyi kes" if on else "Baglan")
        self.tray.setToolTip(f"AsenaDPI: {'ACIK' if on else 'kapali'}  (sol tik: ac/kapat)")

    def _repo(self):
        try:
            r = REPO_FILE.read_text(encoding="utf-8-sig").strip()
            return r if r and os.path.isdir(os.path.join(r, ".git")) else None
        except OSError:
            return None

    def quit_app(self):
        try: stop_off()
        except Exception: pass
        self.app.quit()

    def _restart(self):
        try:
            DETACHED = 0x00000008 | 0x00000200
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
                notify("AsenaDPI guncelleme", f"{n} yeni surum var - sag tik > Guncelle")
        except Exception:
            pass


def main():
    app = QApplication(sys.argv); app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("AsenaDPI"); app.setWindowIcon(app_qicon())
    _t = AsenaTray(app)
    sys.exit(app.exec())


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
