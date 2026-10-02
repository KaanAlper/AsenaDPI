#!/usr/bin/env python3
"""
AsenaDPI - Windows tray + TEK kontrol penceresi (winws/WinDivert + DoH DNS + blockcheck).
Paketlenmis halde AsenaDPI.exe (PyInstaller) olarak gelir; Setup.exe (Inno) kurar.
Logon'da YONETICI olarak baslar (scheduled task, highest) -> winws + DNS'i dogrudan yonetir.
SOL TIK: ac/kapat.  SAG TIK: menu -> Kontrol Paneli.

Mimari: butun yavas isler (winws, PowerShell, schtasks, ag) Engine uzerinden WORKER THREAD'de
calisir; Engine tek kilittir (ayni anda tek islem) -> tray ile pencere birbirini bozamaz.
UI thread'i hicbir zaman alt-surec beklemez.

CLI (Setup/uninstaller kullanir):  --install-task | --uninstall | --selftest <dosya>
"""
import codecs, ctypes, json, os, re, shutil, subprocess, sys, threading, time, traceback
import urllib.request
from ctypes import wintypes
from pathlib import Path

APP_VERSION = "dev"                       # CI, tag'den damgalar (ornek: "1.2.0")
GITHUB_REPO = "KaanAlper/AsenaDPI"
SETUP_ASSET = "AsenaDPI-Setup.exe"
TASK_NAME = "AsenaDPI-Tray"
INSTANCE_KEY = "AsenaDPI-tray-instance"
FROZEN = getattr(sys, "frozen", False)

INSTALL_DIR = (Path(sys.executable).parent if FROZEN
               else Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "AsenaDPI")
WINWS_DIR = INSTALL_DIR / "zapret-winws"
WINWS = WINWS_DIR / "winws.exe"
CYG_BASH = INSTALL_DIR / "cygwin" / "bin" / "bash.exe"
BLOCKCHECK_SH = INSTALL_DIR / "blockcheck" / "zapret" / "blockcheck.sh"
ICO_PATH = INSTALL_DIR / "asena-dpi.ico"
DEFAULT_BLACKLIST = INSTALL_DIR / "defaults" / "blacklist.txt"
OPTIMIZE_DOMAINS = "discord.com gateway.discord.gg"

CFG = Path(os.environ.get("APPDATA", str(Path.home()))) / "AsenaDPI"
BLACKLIST = CFG / "blacklist.txt"
CLEAN = CFG / "hostlist_clean.txt"
SETTINGS = CFG / "settings.conf"
STRAT_FILE = CFG / "tcp443.conf"
LOG = CFG / "winws.log"
APP_LOG = CFG / "tray.log"
BLOCKCHECK_LOG = CFG / "last-blockcheck.log"
DNS_IFACE = CFG / "dnsiface.txt"
LAST_UPDATE_CHECK = CFG / "last_update_check"
AUTOCONNECT_FILE = CFG / "autoconnect"
RESUME_FILE = CFG / "resume_after_update"   # guncelleme oncesi bagliysa -> sonra yeniden baglan
NO_WINDOW = 0x08000000
UPDATE_CHECK_EVERY = 6 * 3600
STATUS_POLL_MS = 2000

DEFAULTS = {"MODE": "blacklist", "HTTP": "1", "HTTP2": "1", "HTTP3": "bypass"}
LBL = {
    "MODE": ("Mod", {"blacklist": "Blacklist", "full": "Full"}),
    "HTTP": ("HTTP (80)", {"1": "açık", "0": "kapalı"}),
    "HTTP2": ("HTTP/2 (443)", {"1": "açık", "0": "kapalı"}),
    "HTTP3": ("HTTP/3-QUIC", {"bypass": "Bypass", "off": "Kapalı", "block": "Engelle"}),
}
ACCENT = "#26A69A"


# ----------------------------------------------------------------- log
def log(msg: str):
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        if APP_LOG.exists() and APP_LOG.stat().st_size > 512_000:
            APP_LOG.replace(APP_LOG.with_suffix(".log.old"))
        with open(APP_LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg.rstrip() + "\n")
    except OSError:
        pass


# ----------------------------------------------------------------- alt surec yardimcilari
def run_hidden(args, timeout=60, **kw):
    try:
        return subprocess.run(args, creationflags=NO_WINDOW, capture_output=True, text=True,
                              timeout=timeout, **kw)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"run_hidden {args[0]}: {e}")
        return subprocess.CompletedProcess(args, 1, "", str(e))


def ps(script: str, timeout=60):
    return run_hidden(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                       "-Command", script], timeout=timeout)


def ps_quote(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


# --- surec listesi: ctypes Toolhelp32 (~1 ms). tasklist.exe her cagrida 100-500 ms + UI donmasi.
class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


_k32 = None


def _kernel32():
    global _k32
    if _k32 is None:
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        k.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        k.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
        k.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        _k32 = k
    return _k32


def process_pids(name: str) -> list:
    name = name.lower()
    try:
        k = _kernel32()
        snap = k.CreateToolhelp32Snapshot(0x2, 0)            # TH32CS_SNAPPROCESS
        if not snap or snap == ctypes.c_void_p(-1).value:
            raise OSError("snapshot")
        try:
            e = _PROCESSENTRY32W(); e.dwSize = ctypes.sizeof(e)
            pids, ok = [], k.Process32FirstW(snap, ctypes.byref(e))
            while ok:
                if e.szExeFile.lower() == name:
                    pids.append(e.th32ProcessID)
                ok = k.Process32NextW(snap, ctypes.byref(e))
            return pids
        finally:
            k.CloseHandle(snap)
    except (OSError, AttributeError):
        r = run_hidden(["tasklist", "/fi", f"imagename eq {name}", "/nh", "/fo", "csv"])
        return [int(m) for m in re.findall(r'"[^"]+","(\d+)"', r.stdout or "")]


def is_on() -> bool:
    return bool(process_pids("winws.exe"))


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (OSError, AttributeError):
        return False


# ----------------------------------------------------------------- config
def ensure_config():
    """Ilk calistirmada kullanici config'i (Setup yonetici olarak calisir; APPDATA'yi tray kurar).
    NOT: tcp443.conf BILEREK olusturulmaz - varsayilan strateji yok, 'En iyi ayar' bulur."""
    CFG.mkdir(parents=True, exist_ok=True)
    if not BLACKLIST.exists():
        if DEFAULT_BLACKLIST.exists():
            shutil.copyfile(DEFAULT_BLACKLIST, BLACKLIST)
        else:
            BLACKLIST.write_text("discord.com\ndiscord.gg\ndiscordapp.com\ndiscord.media\n"
                                 "discordapp.net\n", encoding="utf-8")
    if not SETTINGS.exists():
        save_settings(DEFAULTS)


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


def save_strategy(s: str, note="AsenaDPI TCP443 stratejisi"):
    CFG.mkdir(parents=True, exist_ok=True)
    STRAT_FILE.write_text(f"# {note}\n" + s.strip() + "\n", encoding="utf-8")


def autoconnect_on() -> bool:
    return AUTOCONNECT_FILE.exists()


def set_autoconnect(on: bool):
    if on:
        CFG.mkdir(parents=True, exist_ok=True); AUTOCONNECT_FILE.write_text("1", encoding="utf-8")
    else:
        AUTOCONNECT_FILE.unlink(missing_ok=True)


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


# ----------------------------------------------------------------- autostart (scheduled task)
def _task_action():
    if FROZEN:
        return sys.executable, ""
    pyw = Path(sys.executable).with_name("pythonw.exe")
    return str(pyw if pyw.exists() else sys.executable), f'"{Path(__file__).resolve()}"'


def install_task() -> bool:
    """Logon'da, bu kullanici icin, EN YUKSEK yetkiyle (UAC'siz) tray'i baslatan gorev.
    ExecutionTimeLimit=0: varsayilan 72 saat -> Windows tray'i 3 gun sonra oldururdu."""
    exe, args = _task_action()
    arg_part = f" -Argument {ps_quote(args)}" if args else ""
    r = ps(
        "$ErrorActionPreference='Stop';"
        "$u=\"$env:USERDOMAIN\\$env:USERNAME\";"
        f"$a=New-ScheduledTaskAction -Execute {ps_quote(exe)}{arg_part};"
        "$t=New-ScheduledTaskTrigger -AtLogOn -User $u;"
        "$p=New-ScheduledTaskPrincipal -UserId $u -RunLevel Highest -LogonType Interactive;"
        "$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries "
        "-ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew;"
        f"Register-ScheduledTask -TaskName {ps_quote(TASK_NAME)} -Action $a -Trigger $t "
        "-Principal $p -Settings $s -Force | Out-Null")
    if r.returncode != 0:
        log(f"install_task: {r.stderr or r.stdout}")
    return r.returncode == 0


def autostart_enabled() -> bool:
    return run_hidden(["schtasks", "/query", "/tn", TASK_NAME]).returncode == 0


def set_autostart(on: bool) -> bool:
    if on:
        return install_task()
    return run_hidden(["schtasks", "/delete", "/tn", TASK_NAME, "/f"]).returncode == 0


# ----------------------------------------------------------------- ag (DNS/QUIC) - TEK PowerShell
def _iface_from_file() -> str:
    try:
        return DNS_IFACE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


_DEFAULT_IFACE_PS = ("(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | "
                     "Select-Object -First 1).InterfaceIndex")


def net_on(quic_block):
    """DoH (1.1.1.1) + aktif arayuz DNS'i + (istenirse) QUIC engeli -> tek powershell cagrisi.
    quic_block=None: firewall kuralina dokunma."""
    fw = ""
    if quic_block is not None:
        fw = "Remove-NetFirewallRule -DisplayName AsenaDPI-QUIC;"
        if quic_block:
            fw += ("New-NetFirewallRule -DisplayName AsenaDPI-QUIC -Direction Outbound -Action Block "
                   "-Protocol UDP -RemotePort 443 | Out-Null;")
    r = ps("$ErrorActionPreference='SilentlyContinue';" + fw +
           "Add-DnsClientDohServerAddress -ServerAddress 1.1.1.1 "
           "-DohTemplate 'https://cloudflare-dns.com/dns-query' -AllowFallbackToUdp $false "
           "-AutoUpgrade $true | Out-Null;"
           f"$i={_DEFAULT_IFACE_PS};"
           "if ($i) { Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses 1.1.1.1;"
           "Clear-DnsClientCache; Write-Output $i }")
    idx = (r.stdout or "").strip().splitlines()
    if idx and idx[-1].isdigit():
        DNS_IFACE.write_text(idx[-1], encoding="utf-8")


def net_off():
    idx = _iface_from_file()
    target = idx if idx.isdigit() else _DEFAULT_IFACE_PS
    ps("$ErrorActionPreference='SilentlyContinue';"
       "Remove-NetFirewallRule -DisplayName AsenaDPI-QUIC;"
       f"$i={target};"
       "if ($i) { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses }"
       ";Clear-DnsClientCache")


# ----------------------------------------------------------------- winws
def winws_args(s):
    clean_hostlist()
    hl = [] if s["MODE"] == "full" else [f"--hostlist={CLEAN}"]
    a = [str(WINWS)]
    strat = tcp443_strategy()
    do_80 = s["HTTP"] == "1"
    # 443 sadece GECERLI strateji varsa islenir (bos/gecersiz -> hic yakalama; temiz kurulum/kalkan)
    do_443 = s["HTTP2"] == "1" and "--dpi-desync" in strat
    # WinDivert filtresi (--wf-*): SADECE gercekten islenecek portlari yakala (bos -> 'error opening filter')
    tcp_ports = (["80"] if do_80 else []) + (["443"] if do_443 else [])
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
    if a[-1] == "--new":
        a.pop()
    return a


def _windivert_release():
    # winws oldurulunce WinDivert64.sys hemen unload OLMAYABILIR -> yeni winws
    # 'windivert: error opening filter: (null)' verip ANINDA cikar. Servis adi surume gore degisir.
    for svc in ("WinDivert", "WinDivert1.4", "windivert"):
        run_hidden(["sc", "stop", svc], timeout=10)


def kill_winws():
    if is_on():
        run_hidden(["taskkill", "/f", "/im", "winws.exe"], timeout=15)
        _windivert_release()
        time.sleep(1.5)                       # surucu tam bosalsin
    else:
        _windivert_release()


def _launch_winws(args):
    with open(LOG, "w", encoding="utf-8", errors="replace") as lf:
        return subprocess.Popen(args, cwd=str(WINWS_DIR), stdout=lf, stderr=lf, creationflags=NO_WINDOW)


def winws_log_tail(n=3) -> str:
    try:
        lines = [l for l in LOG.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()]
        return " | ".join(lines[-n:])
    except OSError:
        return ""


def start_on() -> bool:
    """True: winws calisiyor (ya da islenecek filtre yok, yalniz DNS). False: winws basladi-oldu."""
    if not WINWS.exists():
        raise FileNotFoundError(f"winws.exe yok: {WINWS} (Setup'i tekrar calistir)")
    s = load_settings()
    kill_winws()
    args = winws_args(s)
    ok = True
    if len(args) > 1:                     # islenecek filtre var mi? (yoksa winws bos filtreyle coker)
        p = _launch_winws(args)
        time.sleep(1.3)
        if p.poll() is not None:          # hemen oldu -> WinDivert hala kilitli, bir kez daha dene
            _windivert_release(); time.sleep(2.5)
            p = _launch_winws(args); time.sleep(1.3)
            ok = p.poll() is None
            if not ok:
                log("winws baslamadi: " + winws_log_tail(5))
    net_on(quic_block=s["HTTP3"] == "block")
    return ok


def stop_off():
    run_hidden(["taskkill", "/f", "/im", "winws.exe"], timeout=15)
    net_off()


def restart_on() -> bool:
    stop_off()
    return start_on()


# ----------------------------------------------------------------- blockcheck
def to_cygpath(p):
    p = str(p)
    return "/cygdrive/" + p[0].lower() + p[2:].replace("\\", "/")


def parse_best_strategy(text):
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


# ----------------------------------------------------------------- guncelleme (GitHub Releases)
def _ver_tuple(v: str):
    nums = re.findall(r"\d+", v.split("-")[0])
    return tuple(int(n) for n in nums[:3]) if nums else None


def is_newer(remote: str, local: str) -> bool:
    """remote > local mi? 'dev' (kaynaktan/eski Python kurulumu) her zaman guncellenebilir sayilir."""
    lt, rt = _ver_tuple(local), _ver_tuple(remote)
    if rt is None:
        return False
    return lt is None or rt > lt


def _get(url: str, timeout=20):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "AsenaDPI"}),
                                  timeout=timeout)


def latest_release():
    """-> (tag, setup_url, sha256_url) ya da hata firlatir."""
    with _get(f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest") as r:
        data = json.load(r)
    assets = {a.get("name"): a["browser_download_url"] for a in data.get("assets", [])}
    url, sha = assets.get(SETUP_ASSET), assets.get(SETUP_ASSET + ".sha256")
    if not url or not sha:
        raise RuntimeError(f"Release {data.get('tag_name')} içinde {SETUP_ASSET}(.sha256) yok")
    return data["tag_name"], url, sha


def download(url: str, sha_url: str, dest: Path):
    """Indir + SHA256 dogrula. Yonetici olarak calistirilacak -> butunluk sart."""
    import hashlib
    with _get(sha_url) as r:
        want = r.read().decode("ascii", "replace").split()[0].strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", want):
        raise RuntimeError("geçersiz .sha256 dosyası")
    tmp = dest.with_suffix(".part")
    h = hashlib.sha256()
    with _get(url, timeout=60) as r, open(tmp, "wb") as f:
        while chunk := r.read(256 * 1024):
            h.update(chunk); f.write(chunk)
    if h.hexdigest() != want:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("SHA256 uyuşmuyor (bozuk/değiştirilmiş indirme) - kurulmadı")
    tmp.replace(dest)


# ----------------------------------------------------------------- CLI (Qt'siz)
def cli(argv) -> int:
    if "--selftest" in argv:                 # CI: exe gercekten aciliyor + Qt yukleniyor mu?
        from PySide6.QtWidgets import QApplication  # noqa: F401
        from PySide6.QtNetwork import QLocalServer  # noqa: F401
        out = argv[argv.index("--selftest") + 1]
        Path(out).write_text(f"ok {APP_VERSION}", encoding="utf-8")
        return 0
    if "--install-task" in argv:
        return 0 if install_task() else 1
    if "--uninstall" in argv:
        me = os.getpid()
        for pid in process_pids(Path(sys.executable).name):
            if pid != me:
                run_hidden(["taskkill", "/f", "/pid", str(pid)], timeout=15)
        try: stop_off()
        except Exception as e: log(f"uninstall stop_off: {e}")
        _windivert_release()
        set_autostart(False)
        return 0
    return -1


# =================================================================== Qt
from PySide6.QtWidgets import (                                           # noqa: E402
    QApplication, QSystemTrayIcon, QMenu, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QRadioButton, QCheckBox, QPushButton, QButtonGroup, QFrame, QPlainTextEdit,
    QProgressBar, QTabWidget, QLineEdit, QMessageBox,
)
from PySide6.QtGui import (                                               # noqa: E402
    QIcon, QAction, QPainter, QColor, QBrush, QPen, QPixmap, QPainterPath, QFont, QTextCursor, QImage,
)
from PySide6.QtCore import QTimer, Qt, QPointF, QProcess, QObject, Signal, Slot  # noqa: E402
from PySide6.QtNetwork import QLocalServer, QLocalSocket                  # noqa: E402


class Engine(QObject):
    """Tek kilit + worker thread'leri. Tum yavas isler buradan; sonuc ana thread'e sinyalle doner."""
    stateChanged = Signal(bool)          # winws acik/kapali
    busyChanged = Signal(bool, str)      # mesgul mu, mesaj
    _deliver = Signal(object, object, object)   # (callback, deger, hata) - thread -> ana thread

    def __init__(self):
        super().__init__()
        self.on = is_on(); self.busy = False; self.label = ""
        # bound Slot + QueuedConnection: callback GARANTILI ana thread'de (lambda'da baglam yok)
        self._deliver.connect(self._run_cb, Qt.QueuedConnection)
        self._t = QTimer(self); self._t.timeout.connect(self.poll); self._t.start(STATUS_POLL_MS)

    @Slot(object, object, object)
    def _run_cb(self, cb, v, e):
        cb(v, e)

    def poll(self):
        if self.busy:                   # islem surerken ara durumlari yayinlama (titreme olmasin)
            return
        on = is_on()
        if on != self.on:
            self.on = on; self.stateChanged.emit(on)

    def begin(self, label) -> bool:
        if self.busy:
            return False
        self.busy = True; self.label = label; self.busyChanged.emit(True, label)
        return True

    def relabel(self, label):
        """Suren islemin mesajini degistir (kilit elde kalir)."""
        self.label = label; self.busyChanged.emit(True, label)

    def end(self, msg):
        self.busy = False; self.label = ""
        self.on = is_on(); self.stateChanged.emit(self.on)
        self.busyChanged.emit(False, msg)

    def thread(self, fn, cb=None):
        """fn'i worker'da calistir; cb(deger, hata) ana thread'de."""
        def work():
            try:
                v, e = fn(), None
            except Exception as ex:                    # noqa: BLE001 - kullaniciya mesaj + log
                v, e = None, ex
                log(f"{getattr(fn, '__name__', 'islem')}: {traceback.format_exc()}")
            if cb is not None:
                self._deliver.emit(cb, v, e)
        threading.Thread(target=work, daemon=True).start()

    def run(self, label, fn, done) -> bool:
        """begin + thread + end(done(deger, hata))."""
        if not self.begin(label):
            return False
        self.thread(fn, lambda v, e: self.end(done(v, e)))
        return True

    # --- ortak islemler (tray + pencere ayni yolu kullanir) ---
    def connect_(self):
        return self.run("Bağlanıyor...", start_on, _connect_msg)

    def disconnect_(self):
        return self.run("Kapatılıyor...", stop_off,
                        lambda v, e: f"Kapatma hatası: {e}" if e else "Kapatıldı.")

    def toggle(self):
        return self.disconnect_() if self.on else self.connect_()

    def reapply(self, label="Uygulanıyor...", ok_msg="Uygulandı."):
        if self.on:
            return self.run(label, restart_on, lambda v, e: _connect_msg(v, e, ok_msg))
        return False


def _connect_msg(ok, err, ok_msg="Bağlandı."):
    if err:
        return f"Bağlanamadı: {err}"
    if not ok:
        tail = winws_log_tail(2)
        return "winws başlayıp hemen kapandı" + (f" ({tail})" if tail else "") + \
               ". Diğer › winws logu'na bak; antivirüs WinDivert'i engelliyor olabilir."
    return ok_msg


# ----------------------------------------------------------------- ikonlar
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
    if ICO_PATH.exists():
        ic = QIcon(str(ICO_PATH))
        if not ic.isNull():
            return ic
    return make_icon(True)


def dim_icon(icon: QIcon) -> QIcon:
    """Kapali durum: GRI (tam opak) -> gorev cubugunda gorunur kalir, acik halden ayirt edilir."""
    img = icon.pixmap(64, 64).toImage().convertToFormat(QImage.Format_ARGB32)
    for y in range(img.height()):
        for x in range(img.width()):
            c = img.pixelColor(x, y)
            if c.alpha():
                g = int(0.30 * c.red() + 0.59 * c.green() + 0.11 * c.blue())
                c.setRgb(g, g, g, c.alpha()); img.setPixelColor(x, y, c)
    return QIcon(QPixmap.fromImage(img))


def tray_icons():
    """(on, off) tray ikonlari: kurt+DPI LOGOsu (acik renkli / kapali gri). Logo yoksa kalkan."""
    if ICO_PATH.exists():
        base = app_qicon()
        return base, dim_icon(base)
    return make_icon(True), make_icon(False)


def _sec(t):
    l = QLabel(t); f = QFont(); f.setBold(True); f.setPointSize(10); l.setFont(f)
    l.setStyleSheet(f"color:{ACCENT}; margin-top:2px;"); return l


def _hl():
    f = QFrame(); f.setFrameShape(QFrame.HLine); f.setStyleSheet("color:#2a2f37;"); return f


def _keep_space(w):
    """Gizlenince yer tutmaya devam et -> pencere boyu ziplamasin."""
    sp = w.sizePolicy(); sp.setRetainSizeWhenHidden(True); w.setSizePolicy(sp)


# ----------------------------------------------------------------- TEK PENCERE
class AppWindow(QWidget):
    def __init__(self, tray, engine: Engine):
        super().__init__()
        self.tray = tray; self.eng = engine
        self.proc = None; self._bc_buf = []; self._bc_cancel = False; self._quitting = False
        QApplication.instance().aboutToQuit.connect(lambda: setattr(self, "_quitting", True))
        self._dec = codecs.getincrementaldecoder("utf-8")("replace")
        self.saved = load_settings(); self.pending = dict(self.saved)
        self.setWindowTitle("AsenaDPI"); self.setWindowIcon(app_qicon())
        self.setMinimumWidth(520)
        self.setStyleSheet(f"""
            QWidget {{ background:#1b1f27; color:#e6e9ee; font-size:12px; }}
            QLabel#brand {{ font-size:15px; font-weight:800; }}
            QLabel#ver {{ color:#5b636e; font-size:10px; }}
            QTabWidget::pane {{ border:1px solid #2a303a; border-radius:8px; top:-1px; }}
            QTabBar::tab {{ background:#20252f; padding:7px 16px; margin-right:3px;
                            border-top-left-radius:7px; border-top-right-radius:7px; color:#a6adc8; }}
            QTabBar::tab:selected {{ background:#2a303a; color:#e6e9ee; }}
            QRadioButton, QCheckBox {{ padding:3px 0; }}
            QLineEdit {{ background:#0e1116; border:1px solid #333a44; border-radius:6px; padding:6px; }}
            QProgressBar {{ background:#2a2f37; border:none; border-radius:4px; max-height:8px; }}
            QProgressBar::chunk {{ background:{ACCENT}; border-radius:4px; }}
            QPushButton {{ background:#2a2f37; border:1px solid #3a414c; border-radius:6px; padding:7px 14px; }}
            QPushButton:hover {{ background:#333a44; }}
            QPushButton:disabled {{ color:#5b636e; }}
            QPushButton#primary {{ background:{ACCENT}; border:none; color:#04201c; font-weight:bold; }}
            QPushButton#primary:disabled {{ background:#2a2f37; color:#5b636e; }}
            QPushButton#danger {{ background:#5c2b2b; border:1px solid #7a3a3a; }}
            QPlainTextEdit {{ background:#0e1116; color:#8fb8ab; border:1px solid #262c36;
                              border-radius:6px; font-family:Consolas,monospace; font-size:10px; }}
        """)
        root = QVBoxLayout(self); root.setContentsMargins(16, 14, 16, 14); root.setSpacing(10)

        # --- baslik: logo + isim + durum + guc ---
        hb = QHBoxLayout()
        logo = QLabel(); logo.setPixmap(app_qicon().pixmap(30, 30)); hb.addWidget(logo)
        hb.addWidget(QLabel("AsenaDPI", objectName="brand"))
        hb.addWidget(QLabel(APP_VERSION, objectName="ver"))
        hb.addStretch(1)
        self.status = QLabel(); self.status.setStyleSheet("font-weight:bold;")
        self.btn_power = QPushButton("Bağlan"); self.btn_power.setMinimumWidth(90)
        self.btn_power.clicked.connect(self.eng.toggle)
        btn_x = QPushButton("✕"); btn_x.setFixedWidth(34); btn_x.setToolTip("Kapat (Esc)"); btn_x.clicked.connect(self.close)
        hb.addWidget(self.status); hb.addWidget(self.btn_power); hb.addWidget(btn_x)
        root.addLayout(hb)

        self.tabs = QTabWidget()
        self.tabs.addTab(self._tab_settings(), "Ayarlar")
        self.tabs.addTab(self._tab_optimize(), "En iyi ayar")
        self.tabs.addTab(self._tab_other(), "Diğer")
        root.addWidget(self.tabs)

        # --- ORTAK aktivite alani ---
        root.addWidget(_hl())
        self.act = QLabel("Hazır."); self.act.setWordWrap(True); self.act.setStyleSheet("color:#a6adc8;")
        root.addWidget(self.act)
        self.bar = QProgressBar(); self.bar.setTextVisible(False); self.bar.setRange(0, 0)
        _keep_space(self.bar); self.bar.hide()
        root.addWidget(self.bar)
        drow = QHBoxLayout()
        self.detail_btn = QPushButton("Detaylar"); self.detail_btn.setCheckable(True)
        self.detail_btn.toggled.connect(self._toggle_detail); self.detail_btn.setEnabled(False)
        drow.addWidget(self.detail_btn); drow.addStretch(1)
        root.addLayout(drow)
        self.out = QPlainTextEdit(); self.out.setReadOnly(True); self.out.setFixedHeight(170)
        self.out.setMaximumBlockCount(4000); self.out.hide()
        root.addWidget(self.out)

        self.eng.stateChanged.connect(lambda _: self._render_state())
        self.eng.busyChanged.connect(self._on_busy)
        self._sync(); self._render_state()

    # ---------- sekme: Ayarlar ----------
    def _tab_settings(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(7)
        v.addWidget(_sec("Mod"))
        self.g_mode = QButtonGroup(self)
        self.rb_bl = QRadioButton("Blacklist  -  yalnız listedeki siteler")
        self.rb_full = QRadioButton("Full  -  tüm trafik")
        for rb, val in ((self.rb_bl, "blacklist"), (self.rb_full, "full")):
            self.g_mode.addButton(rb); rb.toggled.connect(lambda c, x=val: c and self._setp("MODE", x)); v.addWidget(rb)
        v.addWidget(_sec("HTTP/3 - QUIC"))
        self.g_h3 = QButtonGroup(self)
        self.rb_bypass = QRadioButton("Bypass  -  DPI'dan geçirmeye çalış")
        self.rb_h3off = QRadioButton("Kapalı  -  dokunma")
        self.rb_block = QRadioButton("Engelle  -  QUIC kes -> TCP'ye düş (oyun)")
        for rb, val in ((self.rb_bypass, "bypass"), (self.rb_h3off, "off"), (self.rb_block, "block")):
            self.g_h3.addButton(rb); rb.toggled.connect(lambda c, x=val: c and self._setp("HTTP3", x)); v.addWidget(rb)
        v.addWidget(_sec("Gelişmiş"))
        self.cb_http = QCheckBox("HTTP (80)"); self.cb_http.toggled.connect(lambda c: self._setp("HTTP", "1" if c else "0"))
        self.cb_http2 = QCheckBox("HTTP/2 (443)"); self.cb_http2.toggled.connect(lambda c: self._setp("HTTP2", "1" if c else "0"))
        v.addWidget(self.cb_http); v.addWidget(self.cb_http2)
        v.addWidget(_sec("DPI stratejisi (gelişmiş)"))
        srow = QHBoxLayout()
        self.strat = QLineEdit(); self.strat.setPlaceholderText("boş = 443 desync yok (En iyi ayar ile bul)")
        self.strat.textEdited.connect(self._strat_edited)
        self.btn_sok = QPushButton("✓"); self.btn_sok.setFixedWidth(36); self.btn_sok.setObjectName("primary")
        self.btn_sok.clicked.connect(self._strat_apply)
        self.btn_sundo = QPushButton("↩"); self.btn_sundo.setFixedWidth(36); self.btn_sundo.clicked.connect(self._strat_revert)
        for b in (self.btn_sok, self.btn_sundo):
            _keep_space(b); b.hide()
        srow.addWidget(self.strat); srow.addWidget(self.btn_sok); srow.addWidget(self.btn_sundo)
        v.addLayout(srow)
        self._strat_saved = ""
        v.addWidget(_sec("Başlangıç"))
        self.cb_autostart = QCheckBox("Açılışta başlat"); self.cb_autostart.toggled.connect(self._on_autostart)
        self.cb_autoconn = QCheckBox("Otomatik bağlan (açılışta DPI'ı aç)"); self.cb_autoconn.toggled.connect(self._on_autoconnect)
        v.addWidget(self.cb_autostart); v.addWidget(self.cb_autoconn)
        self.diff = QLabel("Değişiklik yok"); self.diff.setWordWrap(True)
        self.diff.setStyleSheet("color:#c7ccd4; background:#181c23; border:1px solid #262c36; border-radius:8px; padding:8px;")
        v.addWidget(self.diff)
        self.btn_apply = QPushButton("Değişiklikleri uygula"); self.btn_apply.setObjectName("primary")
        self.btn_apply.clicked.connect(self.apply_settings)
        v.addWidget(self.btn_apply); v.addStretch(1)
        return w

    # ---------- sekme: En iyi ayar (blockcheck) ----------
    def _tab_optimize(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(8)
        v.addWidget(_sec("En iyi ayarı bul"))
        v.addWidget(QLabel("Açılmayan siteyi yaz (birden çoksa boşlukla ayır); AsenaDPI ağını\n"
                           "tarayıp en iyi ayarı bulur ve otomatik uygular. Pencereyi kapatsan da\n"
                           "tarama arka planda sürer; bitince bildirim gelir."))
        self.dom = QLineEdit(OPTIMIZE_DOMAINS)
        v.addWidget(self.dom)
        self.btn_opt = QPushButton("Taramayı başlat"); self.btn_opt.setObjectName("primary")
        self.btn_opt.clicked.connect(self._opt_clicked)
        v.addWidget(self.btn_opt); v.addStretch(1)
        return w

    # ---------- sekme: Diger ----------
    def _tab_other(self):
        w = QWidget(); v = QVBoxLayout(w); v.setSpacing(8)
        v.addWidget(_sec("Bakım"))
        self.btn_upd = QPushButton("Güncelle"); self.btn_upd.clicked.connect(self.tray.start_update); v.addWidget(self.btn_upd)
        self.btn_dns = QPushButton("DNS + DPI'ı onar"); self.btn_dns.clicked.connect(self.repair); v.addWidget(self.btn_dns)
        b3 = QPushButton("Blacklist düzenle"); b3.clicked.connect(lambda: self._open_file(BLACKLIST)); v.addWidget(b3)
        b4 = QPushButton("winws logu"); b4.clicked.connect(lambda: self._open_file(LOG)); v.addWidget(b4)
        b5 = QPushButton("Uygulama logu"); b5.clicked.connect(lambda: self._open_file(APP_LOG)); v.addWidget(b5)
        v.addStretch(1)
        return w

    def _open_file(self, p: Path):
        if not p.exists():
            self.act.setText(f"Henüz yok: {p.name}"); return
        try:
            os.startfile(str(p))
        except OSError as e:
            self.act.setText(f"Açılamadı: {e}")

    # ---------- mesgul/durum ----------
    def _on_busy(self, busy, msg):
        self.act.setText(msg)
        self.bar.setVisible(busy)
        scanning = self.proc is not None and self.proc.state() != QProcess.NotRunning
        for b in (self.btn_power, self.btn_apply, self.btn_sok, self.btn_upd, self.btn_dns,
                  self.cb_autostart, self.cb_autoconn):
            b.setEnabled(not busy)
        if not busy:
            self.cb_autoconn.setEnabled(self.cb_autostart.isChecked())
            self._update_diff()
        self.btn_opt.setEnabled(not busy or scanning)
        self.btn_opt.setText("İptal" if scanning else "Taramayı başlat")
        self.btn_opt.setObjectName("danger" if scanning else "primary")
        self.btn_opt.style().unpolish(self.btn_opt); self.btn_opt.style().polish(self.btn_opt)
        self._render_state()

    def _render_state(self):
        if self.eng.busy:
            self.status.setText(self.eng.label.rstrip(".")); self.status.setStyleSheet("font-weight:bold; color:#e0b84f;")
            return
        on = self.eng.on
        self.status.setText("AÇIK" if on else "kapalı")
        self.status.setStyleSheet(f"font-weight:bold; color:{'#3ddc97' if on else '#8a929c'};")
        self.btn_power.setText("Kapat" if on else "Bağlan")

    def _toggle_detail(self, on):
        self.out.setVisible(on)
        self.detail_btn.setText("Detayları gizle" if on else "Detaylar")
        QTimer.singleShot(0, self.adjustSize)

    # ---------- strateji ----------
    def _strat_edited(self, _=None):
        dirty = self.strat.text().strip() != self._strat_saved.strip()
        self.btn_sok.setVisible(dirty); self.btn_sundo.setVisible(dirty)

    def _strat_apply(self):
        if self.eng.busy: return
        s = self.strat.text().strip()          # bos olabilir: 443 desync'siz (sadece DNS/HTTP/QUIC)
        save_strategy(s); self._strat_saved = s; self.btn_sok.hide(); self.btn_sundo.hide()
        done = "Strateji temizlendi (443 desync kapalı)." if not s else "Strateji uygulandı."
        if not self.eng.reapply(ok_msg=done):
            self.act.setText("Temizlendi ve kaydedildi (443 desync kapalı)." if not s else "Strateji kaydedildi.")

    def _strat_revert(self):
        self.strat.setText(self._strat_saved); self.btn_sok.hide(); self.btn_sundo.hide()

    # ---------- baslangic ----------
    def _on_autostart(self, c):
        self.cb_autoconn.setEnabled(c)
        if not c and self.cb_autoconn.isChecked():
            self.cb_autoconn.setChecked(False)

        def revert():
            self.cb_autostart.blockSignals(True); self.cb_autostart.setChecked(not c)
            self.cb_autostart.blockSignals(False); self.cb_autoconn.setEnabled(not c)

        def done(ok, err):
            if err or not ok:
                revert()
                return "Açılışta başlat değiştirilemedi (Uygulama logu'na bak)."
            return "Açılışta başlat: " + ("açık" if c else "kapalı")
        if not self.eng.run("Görev ayarlanıyor...", lambda: set_autostart(c), done):
            revert()

    def _on_autoconnect(self, c):
        on = c and self.cb_autostart.isChecked()
        set_autoconnect(on)
        self.act.setText("Otomatik bağlan: " + ("açık" if on else "kapalı"))

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
                rows.append(f"- {name}:  {vmap.get(self.saved[k], self.saved[k])}  ->  {vmap.get(self.pending[k], self.pending[k])}")
        self.diff.setText("\n".join(rows) if rows else "Değişiklik yok")
        self.btn_apply.setEnabled(bool(rows) and not self.eng.busy)

    def apply_settings(self):
        if self.eng.busy or self.pending == self.saved: return
        save_settings(self.pending); self.saved = dict(self.pending); self._update_diff()
        if not self.eng.reapply(ok_msg="Ayarlar uygulandı."):
            self.act.setText("Ayarlar kaydedildi (bağlanınca geçerli).")

    def repair(self):
        self.eng.run("DNS + DPI yeniden uygulanıyor...", start_on,
                     lambda v, e: _connect_msg(v, e, "DNS + DPI yeniden uygulandı."))

    # ---------- en iyi ayar (blockcheck) ----------
    def _opt_clicked(self):
        if self.proc is not None and self.proc.state() != QProcess.NotRunning:
            self._bc_cancel = True; self._kill_tree()
            return
        self.start_optimize()

    def _kill_tree(self):
        """bash'i AGACIYLA oldur: yalniz kill() curl/yes/mdig gibi cygwin cocuklarini yetim birakir."""
        pid = self.proc.processId()
        if pid:
            subprocess.Popen(["taskkill", "/f", "/t", "/pid", str(pid)], creationflags=NO_WINDOW,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            self.proc.kill()

    def start_optimize(self):
        if not (CYG_BASH.exists() and BLOCKCHECK_SH.exists()):
            self.act.setText("Gerekli dosyalar eksik (blockcheck/cygwin). Setup'ı tekrar çalıştır.")
            return
        dom = " ".join(re.findall(r"[A-Za-z0-9.-]+", self.dom.text())) or OPTIMIZE_DOMAINS
        if not self.eng.begin("Hazırlanıyor (DPI kapatılıyor, DNS korunuyor)..."):
            return
        self.tabs.setCurrentIndex(1)
        self._bc_buf = []; self._bc_cancel = False; self.out.clear()
        self._dec = codecs.getincrementaldecoder("utf-8")("replace")
        self.detail_btn.setEnabled(True)
        # blockcheck temiz ortam ister: winws KAPALI, DNS DoH acik (zehirli DNS testi bozmasin)
        self.eng.thread(lambda: (kill_winws(), net_on(None)), lambda v, e: self._launch_blockcheck(dom))

    def _launch_blockcheck(self, dom):
        cyg = to_cygpath(BLOCKCHECK_SH.parent)
        cmd = ("cd '%s' && export DOMAINS='%s' ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 "
               "ENABLE_HTTPS_TLS13=1 ENABLE_HTTP3=0 SCANLEVEL=standard BATCH=1 IPV=4 "
               "REPEATS=1 PARALLEL=0; yes '' | ./blockcheck.sh") % (cyg, dom)
        self.proc = QProcess(self); self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.setWorkingDirectory(str(BLOCKCHECK_SH.parent))
        self.proc.readyRead.connect(self._read)
        self.proc.finished.connect(lambda code, _st: self._optimize_done(code))
        self.proc.errorOccurred.connect(self._proc_error)
        # relabel ONCE: start() FailedToStart'i senkron yayip _optimize_done'u calistirabilir
        self.eng.relabel(f"'{dom}' için en iyi ayar aranıyor... birkaç dakika sürebilir.")
        self.proc.start(str(CYG_BASH), ["--login", "-c", cmd])

    def _proc_error(self, err):
        if err == QProcess.FailedToStart:     # finished hic gelmez -> burada kapat
            self._optimize_done(-1)

    def _read(self):
        if self.proc is None:
            return
        chunk = self._dec.decode(bytes(self.proc.readAll()))
        self._bc_buf.append(chunk)
        self.out.moveCursor(QTextCursor.End); self.out.insertPlainText(chunk); self.out.moveCursor(QTextCursor.End)

    def _optimize_done(self, code):
        if self.proc is None:
            return
        self.proc.deleteLater(); self.proc = None
        out = "".join(self._bc_buf)
        try: BLOCKCHECK_LOG.write_text(out, encoding="utf-8")
        except OSError: pass

        if self._bc_cancel:
            msg = "Tarama iptal edildi; ayarlar değişmedi, koruma yeniden açıldı."
        else:
            msg = self._apply_blockcheck_result(out)
        # sonuc ne olursa olsun koruma geri acilir; kilit ancak o bitince birakilir
        self.eng.thread(start_on, lambda v, e: self._finish_optimize(msg, v, e))

    def _apply_blockcheck_result(self, out):
        low = out.lower()
        best = parse_best_strategy(out)
        # blockcheck GERCEKTEN kostu mu? Birkac saniyede cikip isaret uretmediyse -> 'DNS yeter' deme.
        ran = ("summary" in low) or ("curl_test" in low) or ("available" in low)
        if best:
            save_strategy(best, "blockcheck otomatik buldu")
            self.strat.setText(best); self._strat_saved = best
            self.btn_sok.hide(); self.btn_sundo.hide()
            return "En iyi ayar bulundu ve uygulandı. Şimdi siteyi/uygulamayı dene."
        if not ran:
            return ("Test tamamlanamadı (blockcheck birkaç saniyede çıktı - dosyalar eksik olabilir). "
                    "Detaylar'daki hataya bak ya da Setup'ı tekrar çalıştır.")
        # TCP'de engel yok: Discord QUIC (UDP443) kullanir, blockcheck QUIC'i TEST ETMEZ -> QUIC'i
        # engelle, uygulama TCP'ye duser (DoH + desync tasir).
        s = load_settings(); s["HTTP3"] = "block"; save_settings(s)
        self.saved = dict(s); self.pending = dict(s); self._sync()
        return ("TCP'de DPI engeli bulunamadı; DNS koruması + QUIC(UDP) engeli uygulandı "
                "(Discord QUIC yüzünden takılmasın diye). Gerekirse Ayarlar > HTTP/3'ten geri al.")

    def _finish_optimize(self, msg, ok, err):
        if err or not ok:
            msg += " — " + _connect_msg(ok, err)
        self.eng.end(msg)
        if not self.isVisible():
            self.tray.notify("AsenaDPI - en iyi ayar", msg)

    # ---------- pencere ----------
    def open_fresh(self, tab=0):
        if not self.eng.busy:
            self.saved = load_settings(); self.pending = dict(self.saved); self._sync()
            self.strat.setText(tcp443_strategy()); self._strat_saved = self.strat.text()
            self.btn_sok.hide(); self.btn_sundo.hide()
        for cb, val in ((self.cb_autoconn, autoconnect_on()),):
            cb.blockSignals(True); cb.setChecked(val); cb.blockSignals(False)

        def got_autostart(v, _e):
            self.cb_autostart.blockSignals(True); self.cb_autostart.setChecked(bool(v))
            self.cb_autostart.blockSignals(False)
            self.cb_autoconn.setEnabled(bool(v) and not self.eng.busy)
        self.eng.thread(autostart_enabled, got_autostart)   # schtasks /query UI'yi bekletmesin
        self._render_state(); self.tabs.setCurrentIndex(tab)
        self.show(); self.raise_(); self.activateWindow()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.close()
        else:
            super().keyPressEvent(e)

    def closeEvent(self, e):
        # Pencere sadece GIZLENIR: suren tarama/islem yarim kalip agi bozuk birakmasin.
        # (Cikis/oturum kapanisi sirasinda ise kapanmasina izin ver.)
        if self._quitting:
            e.accept()
        else:
            e.ignore(); self.hide()

    def shutdown(self):
        self._quitting = True
        if self.proc is not None and self.proc.state() != QProcess.NotRunning:
            self._bc_cancel = True; self.proc.finished.disconnect(); self._kill_tree()


# ----------------------------------------------------------------- tray
class AsenaTray:
    def __init__(self, app):
        self.app = app; self.win = None
        self.eng = Engine()
        self.icon_on, self.icon_off = tray_icons()
        self.tray = QSystemTrayIcon(); self.menu = QMenu()
        self.act_toggle = QAction("Bağlan", self.menu); self.act_toggle.triggered.connect(self.eng.toggle)
        self.menu.addAction(self.act_toggle)
        a_panel = QAction("Kontrol paneli...", self.menu); a_panel.triggered.connect(lambda: self.open(0)); self.menu.addAction(a_panel)
        a_opt = QAction("En iyi ayarı bul", self.menu); a_opt.triggered.connect(lambda: self.open(1)); self.menu.addAction(a_opt)
        a_upd = QAction("Güncelle", self.menu); a_upd.triggered.connect(lambda: self.open(2)); self.menu.addAction(a_upd)
        self.menu.addSeparator()
        a_q = QAction("Çıkış (DPI'ı durdur)", self.menu); a_q.triggered.connect(self.quit_app); self.menu.addAction(a_q)
        self.tray.setContextMenu(self.menu); self.tray.activated.connect(self.on_act)

        self.eng.stateChanged.connect(lambda _: self.refresh())
        self.eng.busyChanged.connect(self._on_busy)
        self.refresh(); self.tray.show()

        QTimer.singleShot(8000, self._autocheck)
        self._upd_timer = QTimer(); self._upd_timer.timeout.connect(self._autocheck)
        self._upd_timer.start(UPDATE_CHECK_EVERY * 1000)
        resume = RESUME_FILE.exists()
        RESUME_FILE.unlink(missing_ok=True)
        if (resume or autoconnect_on()) and not self.eng.on:
            QTimer.singleShot(1200, self._autoconnect)
        elif not tcp443_strategy():                   # temiz kurulum: strateji yok -> yonlendir
            QTimer.singleShot(1800, self._first_setup_prompt)

    def notify(self, title, body):
        self.tray.showMessage(title, body, QSystemTrayIcon.Information, 5000)

    def _on_busy(self, busy, msg):
        self.act_toggle.setEnabled(not busy)
        self.refresh()
        # pencere kapaliyken sonucu bildirimle goster (tray'den tetiklenen islemler)
        if not busy and msg and (self.win is None or not self.win.isVisible()):
            self.notify("AsenaDPI", msg)

    def _first_setup_prompt(self):
        if tcp443_strategy():
            return
        m = QMessageBox()
        m.setWindowTitle("AsenaDPI - kurulum"); m.setWindowIcon(self.icon_on)
        m.setIcon(QMessageBox.Information)
        m.setText("Temiz kurulum: henüz DPI stratejisi yok.")
        m.setInformativeText("Ağına en uygun ayarı otomatik bulmak için aşağıdaki düğmeye bas.\n"
                             "(Bulunana kadar yalnız DNS koruması aktif; bazı siteler açılmayabilir.)")
        btn = m.addButton("En iyi ayarı bul", QMessageBox.AcceptRole)
        m.addButton("Sonra", QMessageBox.RejectRole)
        m.exec()
        if m.clickedButton() is btn:
            self.open(1)

    def _autoconnect(self):
        if not self.eng.on:
            self.eng.connect_()

    def open(self, tab=0):
        if self.win is None:
            self.win = AppWindow(self, self.eng)
        self.win.open_fresh(tab)

    def on_act(self, reason):
        if reason == QSystemTrayIcon.Trigger:
            self.eng.toggle()                           # mesgulse sessizce yok sayilir (kilit)

    def refresh(self):
        on = self.eng.on
        self.tray.setIcon(self.icon_on if on else self.icon_off)
        if self.eng.busy:
            self.tray.setToolTip(f"AsenaDPI: {self.eng.label}")
        else:
            self.act_toggle.setText("Bağlantıyı kes" if on else "Bağlan")
            self.tray.setToolTip(f"AsenaDPI {APP_VERSION}: {'AÇIK' if on else 'kapalı'}  (sol tık: aç/kapat)")

    def quit_app(self):
        self.tray.hide()
        if self.win is not None:
            self.win.shutdown(); self.win.hide()
        self.eng.thread(stop_off, lambda *_: self.app.quit())
        QTimer.singleShot(20000, self.app.quit)        # emniyet: stop_off takilirsa yine cik

    # ---------- guncelleme ----------
    def start_update(self):
        """Kontrol -> indir -> Setup'i sessiz calistir. Kilit zincir boyunca elde tutulur."""
        if not self.eng.begin("Güncelleme kontrol ediliyor..."):
            return

        def checked(res, err):
            if err:
                self.eng.end(f"Güncelleme kontrolü başarısız (GitHub'a ulaşılamadı?): {err}")
                return
            tag, url, sha = res
            if not is_newer(tag, APP_VERSION):
                self.eng.end(f"Zaten güncel ({APP_VERSION}).")
                return
            self.eng.relabel(f"{tag} indiriliyor...")
            dest = Path(os.environ.get("TEMP", str(CFG))) / SETUP_ASSET
            self.eng.thread(lambda: download(url, sha, dest), lambda _v, e: downloaded(tag, dest, e))

        def downloaded(tag, dest, err):
            if err:
                self.eng.end(f"İndirme başarısız: {err}")
                return
            try:
                if self.eng.on:
                    RESUME_FILE.write_text("1", encoding="utf-8")
                DETACHED = 0x00000008 | 0x00000200
                subprocess.Popen([str(dest), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"],
                                 creationflags=DETACHED, close_fds=True)
            except OSError as e:
                RESUME_FILE.unlink(missing_ok=True)
                self.eng.end(f"Kurulum başlatılamadı: {e}")
                return
            self.eng.end(f"{tag} kuruluyor; AsenaDPI birazdan kendiliğinden yeniden açılacak.")
            # Setup bizi zaten kapatir; yine de temiz cikalim
            QTimer.singleShot(1500, self.app.quit)

        self.eng.thread(latest_release, checked)

    def _autocheck(self):
        try:
            if time.time() - float(LAST_UPDATE_CHECK.read_text(encoding="utf-8")) < UPDATE_CHECK_EVERY - 60:
                return
        except (OSError, ValueError):
            pass

        def done(res, err):
            try: LAST_UPDATE_CHECK.write_text(str(time.time()), encoding="utf-8")
            except OSError: pass
            if not err and is_newer(res[0], APP_VERSION):
                self.notify("AsenaDPI güncelleme", f"{res[0]} çıktı - sağ tık > Güncelle")
        self.eng.thread(latest_release, done)


# ----------------------------------------------------------------- tek ornek + yetki
def _ping_existing(msg=b"show", wait_ms=300) -> bool:
    s = QLocalSocket(); s.connectToServer(INSTANCE_KEY)
    if not s.waitForConnected(wait_ms):
        return False
    s.write(msg); s.flush(); s.waitForBytesWritten(500); s.disconnectFromServer()
    return True


def _elevate_or_delegate(app) -> int:
    """Yonetici degilsek (kisayoldan acildi): gorevi (UAC'siz, yonetici) baslat, sonra panelini ac.
    Gorev yoksa: UAC ile kendimizi yeniden baslat."""
    if run_hidden(["schtasks", "/run", "/tn", TASK_NAME], timeout=15).returncode == 0:
        for _ in range(40):                              # tray ayaga kalkinca paneli acsin
            if _ping_existing(wait_ms=250):
                return 0
            time.sleep(0.25)
        return 0
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1)
    return 0


def main():
    app = QApplication(sys.argv); app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("AsenaDPI"); app.setWindowIcon(app_qicon())
    if _ping_existing():                                 # zaten calisiyor -> onun panelini ac
        return 0
    if FROZEN and not is_admin():
        return _elevate_or_delegate(app)
    # ONCE dinle, SONRA tray kur: logon gorevi + kisayol ayni anda acilirsa iki tray olmasin
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.WorldAccessOption)   # yonetici-olmayan kisayol da baglanabilsin
    if not server.listen(INSTANCE_KEY):
        if _ping_existing(wait_ms=1000):                       # baska ornek kazandi -> o acsin
            return 0
        QLocalServer.removeServer(INSTANCE_KEY)                # bayat pipe (cokme sonrasi) -> temizle
        if not server.listen(INSTANCE_KEY):
            log(f"QLocalServer: {server.errorString()}")
    ensure_config()
    tray = AsenaTray(app)

    def on_conn():
        c = server.nextPendingConnection()
        if c is None:
            return
        c.readyRead.connect(lambda: (c.readAll(), tray.open(0)))
        c.disconnected.connect(c.deleteLater)
    server.newConnection.connect(on_conn)
    return app.exec()


if __name__ == "__main__":
    rc = cli(sys.argv[1:])
    if rc >= 0:
        sys.exit(rc)
    try:
        sys.exit(main())
    except Exception:
        try:
            CFG.mkdir(parents=True, exist_ok=True)
            (CFG / "tray-error.log").write_text(traceback.format_exc(), encoding="utf-8")
        except OSError:
            pass
        raise
