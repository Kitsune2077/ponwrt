#requires -Version 5.1
<#
.SYNOPSIS
    Send non-IP Ethernet frames through an HG5382A/AN7581 bridge and count
    how many arrive on the far-side NIC.

.DESCRIPTION
    The bridge L2B offload path is only exercised by non-IP frames. IPv4 and
    ICMP frames are classified by the PPE as IPv4 flows (type 4/5), so a
    ping/ICMP test will never produce a "BND L2B" PPE entry. This script
    sends Ether(type=0x88b5)/Raw(...) frames from TxIf to RxIf; both NICs
    must be connected to two LAN ports of the ONU that are members of the
    same bridge (for example lan3 -> lan1).

    It needs Python 3 with Scapy and Npcap (WinPcap API-compatible mode) on
    Windows. If -OnuHost is supplied (or -ReadCounters is used with it), the
    script also tries to read the read-only PPE counters over SSH with
    paramiko. If paramiko is not installed it prints the commands instead
    and the frame test still runs.

    Nothing on the ONU is modified: the SSH commands are `cat`/`sed`/`grep`
    only. The script does not flush the FDB, reload the driver or change
    module parameters.

.PARAMETER TxIf
    Scapy/Npcap interface name of the sending NIC (the lan3 side).

.PARAMETER RxIf
    Scapy/Npcap interface name of the receiving NIC (the lan1 side).

.PARAMETER Count
    Number of frames to send. Default 300.

.PARAMETER EtherType
    Non-IP EtherType as a 0x.... string. Default 0x88b5.

.PARAMETER SrcMac
    Source MAC. Default: the TxIf adapter MAC (Get-NetAdapter, then Scapy).

.PARAMETER DstMac
    Destination MAC. Default: the RxIf adapter MAC.

.PARAMETER InterMs
    Milliseconds between frames. Default 10 (about 100 pps).

.PARAMETER OnuHost
    ONU management address. Implies counter reading over SSH.

.PARAMETER OnuPort
    SSH port, default 22.

.PARAMETER OnuUser
    SSH user, default root.

.PARAMETER OnuPassword
    SSH password. Prefer the PONWRT_ONU_PASSWORD environment variable; a
    password on the command line can show up in process listings.

.PARAMETER ReadCounters
    Read the ONU counters over SSH. Requires -OnuHost.

.PARAMETER Python
    Python executable, default "python".

.EXAMPLE
    .\pppoe-l2b-test.ps1 -TxIf '以太网 2' -RxIf '以太网' -Count 300

.EXAMPLE
    $env:PONWRT_ONU_PASSWORD = 'secret'
    .\pppoe-l2b-test.ps1 -TxIf '以太网 2' -RxIf '以太网' `
        -SrcMac 0c:9d:92:cb:8b:c5 -DstMac 80:86:f2:01:cc:f0 `
        -OnuHost 192.168.1.1 -OnuUser root

.NOTES
    First run (measured on HG5382A with the 940 image):
      fdb_promoted 0 -> 1, l2b_reject ACCEPTED=1, one BND L2B entry.
    Second run, without flushing the FDB:
      all frames delivered, fdb_promoted stays 1, fdb_rx_no_flow grows only
      with ambient traffic. Staying at 1 is success, not a failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TxIf,

    [Parameter(Mandatory = $true)]
    [string]$RxIf,

    [ValidateRange(1, 100000)]
    [int]$Count = 300,

    [ValidatePattern('^0[xX][0-9a-fA-F]{4}$')]
    [string]$EtherType = '0x88b5',

    [string]$SrcMac = '',

    [string]$DstMac = '',

    [ValidateRange(0, 1000)]
    [int]$InterMs = 10,

    [string]$OnuHost = '',

    [ValidateRange(1, 65535)]
    [int]$OnuPort = 22,

    [string]$OnuUser = 'root',

    [string]$OnuPassword = '',

    [switch]$ReadCounters,

    [string]$Python = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is for Windows (Npcap + Scapy).'
}

function Test-MacAddress {
    param([string]$Mac)
    return [bool]($Mac -match '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
}

function Resolve-NicMac {
    param([string]$Name)
    try {
        $adapter = Get-NetAdapter -Name $Name -ErrorAction Stop
        return ($adapter.MacAddress -replace '-', ':').ToLowerInvariant()
    }
    catch {
        return ''
    }
}

# Npcap needs an elevated process to open the capture/send handles on most
# Windows installations. Warn early instead of failing inside Scapy.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Not running elevated; Npcap may refuse to open the adapters.'
}

$wantSsh = [bool]$ReadCounters -or ($OnuHost -ne '')
if ($wantSsh -and ($OnuHost -eq '')) {
    throw '-ReadCounters requires -OnuHost.'
}

if ($OnuPassword -ne '') {
    $env:PONWRT_ONU_PASSWORD = $OnuPassword
    Write-Warning 'Prefer the PONWRT_ONU_PASSWORD environment variable; command-line passwords can be visible to other processes.'
}

$pythonCmd = Get-Command $Python -ErrorAction SilentlyContinue
if ($null -eq $pythonCmd) {
    throw "Python executable '$Python' not found. Install Python 3 and Scapy, or pass -Python <path>."
}
$pythonPath = $pythonCmd.Source

if ($SrcMac -eq '') {
    $SrcMac = Resolve-NicMac $TxIf
}
if ($DstMac -eq '') {
    $DstMac = Resolve-NicMac $RxIf
}
if ($SrcMac -ne '' -and -not (Test-MacAddress $SrcMac)) {
    throw "Invalid -SrcMac '$SrcMac' (expected aa:bb:cc:dd:ee:ff)."
}
if ($DstMac -ne '' -and -not (Test-MacAddress $DstMac)) {
    throw "Invalid -DstMac '$DstMac' (expected aa:bb:cc:dd:ee:ff)."
}

$etypeInt = [Convert]::ToInt32($EtherType.Substring(2), 16)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pppoe-l2b-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null

$sshConfig = $null
if ($wantSsh) {
    $sshConfig = [ordered]@{
        host         = $OnuHost
        port         = $OnuPort
        user         = $OnuUser
        password_env = 'PONWRT_ONU_PASSWORD'
    }
}

$config = [ordered]@{
    tx_if     = $TxIf
    rx_if     = $RxIf
    src_mac   = $SrcMac
    dst_mac   = $DstMac
    count     = $Count
    ethertype = $etypeInt
    inter_ms  = $InterMs
    ssh       = $sshConfig
}

$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
$json = $config | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $tempDir 'config.json'), $json, $utf8)

$py = @'
import json
import os
import re
import sys
import threading
import time

CONFIG_PATH = sys.argv[1]
with open(CONFIG_PATH, "r", encoding="utf-8-sig") as fh:
    cfg = json.load(fh)

try:
    from scapy.all import Ether, Raw, sendp, sniff, get_if_hwaddr
except Exception as exc:
    print("ERROR: Scapy is required: {}".format(exc))
    print("Install: python -m pip install scapy")
    print("Also install Npcap (WinPcap API-compatible mode) on Windows.")
    sys.exit(2)

MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")
MAGIC = b"PONWRT-L2B"
CMD_CONFIG = "cat /sys/kernel/debug/ppe/config | grep -E 'npu_attached|fdb_'"
CMD_L2B = "sed -n '1,4p' /sys/kernel/debug/ppe/l2b_dbg"
CMD_ENTRIES = "grep -E 'BND[[:space:]]+L2B' /sys/kernel/debug/ppe/entries || true"


def iface_mac(name):
    try:
        return get_if_hwaddr(name).lower()
    except Exception:
        return ""


def parse_config(text):
    vals = {}
    for line in text.splitlines():
        match = re.match(
            r"^(npu_attached|fdb_promoted|fdb_no_entry|fdb_no_npu|"
            r"fdb_rx_no_flow|fdb_rx_no_slot):\s*(\d+)", line)
        if match:
            vals[match.group(1)] = int(match.group(2))
    return vals


def parse_l2b(text):
    vals = {}
    for line in text.splitlines():
        if line.startswith("l2b_reject:"):
            for key, value in re.findall(r"([A-Z_]+)=(\d+)", line):
                vals[key] = int(value)
    return vals


def ssh_connect(scfg):
    try:
        import paramiko
    except Exception as exc:
        print("NOTE: paramiko is not available ({}); not reading counters.".format(exc))
        return None

    host = scfg.get("host")
    port = int(scfg.get("port") or 22)
    user = scfg.get("user") or "root"
    password = os.environ.get(scfg.get("password_env") or "PONWRT_ONU_PASSWORD") or None

    client = paramiko.SSHClient()
    # Lab convenience only. For production, pin the ONU host key in
    # ~/.ssh/known_hosts and use RejectPolicy.
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(host, port=port, username=user, password=password,
                       timeout=10, allow_agent=True, look_for_keys=True)
    except Exception as exc:
        print("WARNING: SSH to {}@{}:{} failed: {}".format(user, host, port, exc))
        print("         Continuing with the frame test only.")
        return None
    return client


def ssh_read(client):
    out = {}
    for key, cmd in (("config", CMD_CONFIG), ("l2b", CMD_L2B),
                     ("entries", CMD_ENTRIES)):
        _stdin, stdout, stderr = client.exec_command(cmd, timeout=15)
        text = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        out[key] = text + (("\n[stderr] " + err) if err.strip() else "")
    return out


src = (cfg.get("src_mac") or iface_mac(cfg["tx_if"])).lower()
dst = (cfg.get("dst_mac") or iface_mac(cfg["rx_if"])).lower()
if not MAC_RE.match(src) or not MAC_RE.match(dst):
    print("ERROR: could not resolve a usable MAC pair (src={!r}, dst={!r}).".format(src, dst))
    print("       Pass -SrcMac and -DstMac explicitly.")
    sys.exit(2)
if src == dst:
    print("ERROR: source and destination MAC are identical ({}).".format(src))
    sys.exit(2)

count = int(cfg["count"])
inter = float(cfg["inter_ms"]) / 1000.0
etype = int(cfg["ethertype"])
timeout = max(6.0, count * inter + 5.0)

print("TX iface : {} ({})".format(cfg["tx_if"], src))
print("RX iface : {} ({})".format(cfg["rx_if"], dst))
print("EtherType: 0x{:04x}, frames: {}, inter: {} ms".format(etype, count, cfg["inter_ms"]))

ssh_client = None
pre = None
post = None
if cfg.get("ssh"):
    ssh_client = ssh_connect(cfg["ssh"])
    if ssh_client is not None:
        pre = ssh_read(ssh_client)

seen = set()
seen_lock = threading.Lock()
sniff_errors = []


def on_rx(pkt):
    try:
        if not pkt.haslayer(Ether) or pkt[Ether].type != etype:
            return
        if pkt[Ether].dst.lower() != dst:
            return
        payload = bytes(pkt[Raw].load) if pkt.haslayer(Raw) else b""
        if payload.startswith(MAGIC) and len(payload) >= len(MAGIC) + 4:
            seq = int.from_bytes(payload[len(MAGIC):len(MAGIC) + 4], "big")
            with seen_lock:
                seen.add(seq)
    except Exception as exc:
        sniff_errors.append(str(exc))


def sniff_thread():
    try:
        sniff(iface=cfg["rx_if"], timeout=timeout, prn=on_rx, store=False)
    except Exception as exc:
        sniff_errors.append(str(exc))


sniffer = threading.Thread(target=sniff_thread)
sniffer.start()
time.sleep(1.0)

frames = []
for i in range(count):
    payload = MAGIC + i.to_bytes(4, "big") + b"." * 52
    frames.append(Ether(src=src, dst=dst, type=etype) / Raw(payload))

send_ok = True
try:
    print("Sending {} frames on {} ...".format(count, cfg["tx_if"]))
    sendp(frames, iface=cfg["tx_if"], inter=inter, verbose=False)
except Exception as exc:
    send_ok = False
    print("ERROR: sendp failed: {}".format(exc))
    print("       Install Npcap (WinPcap API-compatible mode) and run elevated.")
finally:
    sniffer.join(timeout + 5.0)

for err in sniff_errors:
    print("WARNING: receive error: {}".format(err))

delivered = len(seen & set(range(count)))
missing = sorted(set(range(count)) - seen)
print("")
print("sent      : {}".format(count))
print("delivered : {}".format(delivered))
print("missing   : {}".format(count - delivered))
if missing:
    print("missing seq (first 10): {}".format(missing[:10]))

if ssh_client is not None:
    post = ssh_read(ssh_client)
    ssh_client.close()

pre_cfg = parse_config(pre["config"]) if pre else {}
pre_l2b = parse_l2b(pre["l2b"]) if pre else {}
post_cfg = parse_config(post["config"]) if post else {}
post_l2b = parse_l2b(post["l2b"]) if post else {}
entry_rows = [line for line in (post["entries"] if post else "").splitlines() if line.strip()]

if pre:
    print("")
    print("=== ONU counters BEFORE the run ===")
    print(pre["config"].rstrip())
    print(pre["l2b"].rstrip())
    print("BND L2B entries: {}".format(len([x for x in pre["entries"].splitlines() if x.strip()])))
if post:
    print("")
    print("=== ONU counters AFTER the run ===")
    print(post["config"].rstrip())
    print(post["l2b"].rstrip())
    if entry_rows:
        print("BND L2B entries:")
        for row in entry_rows:
            print("  " + row)
    else:
        print("BND L2B entries: (none)")

if post:
    d_promoted = post_cfg.get("fdb_promoted", 0) - pre_cfg.get("fdb_promoted", 0)
    d_accepted = post_l2b.get("ACCEPTED", 0) - pre_l2b.get("ACCEPTED", 0)
    print("")
    print("fdb_promoted delta : {:+d}".format(d_promoted))
    print("ACCEPTED delta     : {:+d}".format(d_accepted))
    if delivered == count and d_promoted == 1 and d_accepted >= 1 and entry_rows:
        print("RESULT: first-run PASS signature: all frames delivered, one new")
        print("        promotion, ACCEPTED advanced, and a BND L2B entry exists.")
    elif delivered == count and d_promoted == 0 and entry_rows:
        print("RESULT: steady-state signature: all frames delivered, the flow is")
        print("        already bound (fdb_promoted stayed flat). This is success")
        print("        for a second run; it is not a missing promotion.")
    elif delivered == count and d_promoted == 0 and not entry_rows:
        print("RESULT: frames arrived but no BND L2B entry was found. Check that")
        print("        the frames are non-IP, that the destination MAC is on lan1")
        print("        and that the bridge/FDB entry exists.")
    elif delivered < count:
        print("RESULT: incomplete delivery; check the NIC names, the bridge")
        print("        membership and that Npcap is capturing on RxIf.")
    else:
        print("RESULT: unexpected combination; see the counters above.")
else:
    print("")
    print("ONU counters to read (read-only), before and after the run:")
    print("  " + CMD_CONFIG)
    print("  " + CMD_L2B)
    print("  " + CMD_ENTRIES)
    print("")
    print("First run : fdb_promoted +1, l2b_reject ACCEPTED +1, one BND L2B row,")
    print("            all frames delivered.")
    print("Second run: all frames delivered, fdb_promoted unchanged (usually 1),")
    print("            fdb_rx_no_flow grows only with ambient traffic.")
    print("Do NOT flush the FDB or reboot between the two runs.")
    print("The etype= column is FOE L2B metadata, not the frame EtherType; the")
    print("measured 0x88b5 entry printed etype=0000. Do not grep for etype=88b5.")

if not send_ok:
    sys.exit(2)
if delivered != count:
    sys.exit(1)
'@

[System.IO.File]::WriteAllText((Join-Path $tempDir 'pppoe_l2b_test.py'), $py, $utf8)

$rc = 1
try {
    Push-Location $tempDir
    & $pythonPath (Join-Path $tempDir 'pppoe_l2b_test.py') (Join-Path $tempDir 'config.json')
    $rc = $LASTEXITCODE
}
finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $tempDir -ErrorAction SilentlyContinue
}

if ($rc -ne 0) {
    Write-Host "Frame test failed (exit $rc). See the output above." -ForegroundColor Red
    exit $rc
}

Write-Host ''
Write-Host 'Frame test complete. For the full judgement, compare the two runs:'
Write-Host '  first run : fdb_promoted +1, ACCEPTED +1, one BND L2B entry, 300/300.'
Write-Host '  second run: 300/300, fdb_promoted unchanged, fdb_rx_no_flow only ambient.'
Write-Host 'Do not flush the FDB or reboot between the runs.'
