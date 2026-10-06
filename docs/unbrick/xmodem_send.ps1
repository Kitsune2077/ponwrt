<#
.SYNOPSIS
    XMODEM-1K (1024 byte, CRC16) sender that boots U-Boot on an AN758x board
    whose BL2 cannot read the stored FIP (see docs/UNBRICK.md).

.DESCRIPTION
    The AN758x BL2 prints "Press x to load BL31 + U-Boot FIP via XMODEM" when the
    FIP volume in NAND is unreadable (typically a NAND ECC mismatch).  This script
    drives that prompt over a 3.3V USB-TTL adapter and uploads the FIP into RAM:

        wait for the prompt -> send 'x' -> wait for the 'C' handshake
        -> send 333 x 1024-byte CRC packets -> EOT -> show the U-Boot log

    Robustness built in:
      * standard 10 s per-packet timeout (short timeouts can desynchronise the
        simple XMODEM receiver implemented by BL2),
      * the 'C' handshake is only accepted as a bare byte, never as the letter C
        inside console text such as "NOTICE:",
      * a stalled transfer re-sends 'x' to open a new session and restarts the
        image from packet 1 (up to -MaxRestarts),
      * the repetitive NAND/UBI error flood is collapsed on screen but kept in
        full in the log file,
      * the COM port is always released, including on Ctrl+C.

    Remember: the FIP uploaded this way lives in RAM only.  Once U-Boot's web
    recovery is up, you must rebuild UBI and write BL2 + FIP + sysupgrade, or the
    next reboot returns to the BL2 prompt.

.EXAMPLE
    .\xmodem_send.ps1 -SelfTest
    .\xmodem_send.ps1 -Port COM19 -DryRun
    .\xmodem_send.ps1 -Port COM19
    .\xmodem_send.ps1 -Port COM19 -SendXAfter 3      # board already at the prompt
#>
param(
    [string]$Port,
    [string]$File = "",
    [int]$LogSeconds = 120,
    [string]$LogFile = "",
    [int]$PacketTimeoutSec = 10,
    [int]$MaxRetryPerPacket = 5,
    [int]$MaxRestarts = 3,
    [int]$PollXSeconds = 5,
    [int]$OverallMinutes = 40,
    [int]$SendXAfter = 0,
    [switch]$NoPollX,
    [switch]$Verbose,
    [switch]$SelfTest,
    [switch]$DryRun
)

function Get-Crc16 {
    param([byte[]]$Data)
    $crc = 0
    foreach ($b in $Data) {
        $crc = $crc -bxor ([int]$b -shl 8)
        for ($i = 0; $i -lt 8; $i++) {
            if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF }
            else { $crc = ($crc -shl 1) -band 0xFFFF }
        }
    }
    return $crc
}

function Build-Packet {
    param([byte[]]$Data, [int]$Seq)
    $pkt = New-Object byte[] (1024 + 5)
    $pkt[0] = 0x02                                    # STX = 1024-byte payload
    $pkt[1] = [byte]($Seq -band 0xFF)
    $pkt[2] = [byte]((0xFF - $Seq) -band 0xFF)
    [Array]::Copy($Data, 0, $pkt, 3, 1024)
    $crc = Get-Crc16 -Data $Data
    $pkt[1027] = [byte](($crc -shr 8) -band 0xFF)
    $pkt[1028] = [byte]($crc -band 0xFF)
    return $pkt
}

if ($SelfTest) {
    $vec = [System.Text.Encoding]::ASCII.GetBytes('123456789')
    $crc = Get-Crc16 -Data $vec
    Write-Output ("CRC16('123456789') = 0x{0:X4} (expect 0x31C3) -> {1}" -f $crc, $(if ($crc -eq 0x31C3) { 'PASS' } else { 'FAIL' }))
    $p = Build-Packet -Data ([byte[]]::new(1024)) -Seq 1
    Write-Output ("packet length={0} STX=0x{1:X2} seq={2} nseq=0x{3:X2}" -f $p.Length, $p[0], $p[1], $p[2])
    return
}

if (-not $File) { $File = Join-Path $PSScriptRoot 'an7581-fiberhome-hg5382a-bl31-u-boot.fip' }
if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'xmodem_log.txt' }

if (-not (Test-Path $File)) { Write-Output ("MISSING image: {0}" -f $File); return }

$data = [System.IO.File]::ReadAllBytes($File)
$packets = New-Object 'System.Collections.Generic.List[byte[]]'
for ($off = 0; $off -lt $data.Length; $off += 1024) {
    $len = [Math]::Min(1024, $data.Length - $off)
    $chunk = New-Object byte[] 1024
    if ($len -lt 1024) { for ($k = 0; $k -lt 1024; $k++) { $chunk[$k] = 0x1A } }   # SUB padding
    [Array]::Copy($data, $off, $chunk, 0, $len)
    $packets.Add((Build-Packet -Data $chunk -Seq (($packets.Count + 1) -band 0xFF)))
}

Write-Output ("image  : {0}" -f $File)
Write-Output ("size   : {0} bytes -> {1} packets of 1024" -f $data.Length, $packets.Count)
Write-Output ("sha256 : {0}" -f (Get-FileHash $File -Algorithm SHA256).Hash.ToLower())
Write-Output ("port   : {0} at 115200 8N1, per-packet timeout {1}s, retry {2}, restarts {3}" -f $Port, $PacketTimeoutSec, $MaxRetryPerPacket, $MaxRestarts)

if ($DryRun) { Write-Output 'DRY RUN ok'; return }
if (-not $Port) { Write-Output 'ERROR: -Port COMx is required (see also -ListPorts of serial_log.ps1)'; return }

$sp = [System.IO.Ports.SerialPort]::new($Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 250
$sp.WriteTimeout = 8000
$sp.Handshake = [System.IO.Ports.Handshake]::None
$sp.DtrEnable = $true
$sp.RtsEnable = $true
try { $sp.ReadBufferSize = 65536 } catch { }
try {
    $sp.Open()
} catch {
    Write-Output ("OPEN FAILED on {0}: {1}" -f $Port, $_.Exception.Message)
    Write-Output "Hint: close any serial terminal (or a previous run) that still holds the port."
    try { $sp.Dispose() } catch { }
    return
}

$log = New-Object System.IO.FileStream($LogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$textBuf = New-Object System.Text.StringBuilder
$lineBuf = New-Object System.Text.StringBuilder
$rxTotal = 0
$suppressed = 0
$lastBeat = Get-Date
$deadline = (Get-Date).AddMinutes($OverallMinutes)
$restarts = 0
$isoC = 0              # isolated 'C' handshake bytes
$isoCLastLen = 0

function Write-Out([string]$s) { [Console]::Out.Write($s); [Console]::Out.Flush() }

function Emit-Line([string]$line) {
    if ($line -match 'nand_read\(.*failed|UBI: Bad EC magic in block|^NOTICE:  UBI: scanning|VID header offset|PEB size:|LEB size:') {
        $script:suppressed++
        if ($script:suppressed % 500 -eq 0) { Write-Out ("`n   ... {0} NAND-scan lines suppressed (full log: {1})`n" -f $script:suppressed, $LogFile) }
        return
    }
    Write-Out ("`n" + $line)
}

function Pump([int]$Ms = 100) {
    $end = (Get-Date).AddMilliseconds($Ms)
    do {
        $n = 0
        try { $n = $sp.BytesToRead } catch { return }
        if ($n -gt 0) {
            $tmp = New-Object byte[] $n
            $r = $sp.Read($tmp, 0, $n)
            if ($r -gt 0) {
                $script:rxTotal += $r
                $log.Write($tmp, 0, $r); $log.Flush()
                $s = [System.Text.Encoding]::ASCII.GetString($tmp, 0, $r)
                if ($r -eq 1 -and $tmp[0] -eq 0x43) { $script:isoC++ }
                [void]$textBuf.Append($s)
                foreach ($ch in $s.ToCharArray()) {
                    if ($ch -eq "`n") {
                        $l = $lineBuf.ToString().TrimEnd("`r")
                        if ($l.Length -gt 0) { Emit-Line $l }
                        [void]$lineBuf.Clear()
                    } else { [void]$lineBuf.Append($ch) }
                }
                # The XMODEM handshake arrives as bare 'C' bytes with no newline, so the
                # current partial line is made of nothing but 'C'.  Console text such as
                # "NOTICE:" contains the letter C too, but never as a lone-letter line.
                $cur = $lineBuf.ToString().Trim()
                if ($cur.Length -gt 0 -and $cur.Replace('C', '').Length -eq 0) {
                    if ($cur.Length -gt $script:isoCLastLen) {
                        $script:isoC += ($cur.Length - $script:isoCLastLen)
                        $script:isoCLastLen = $cur.Length
                    }
                }
                if ($Verbose) { Write-Out $s }
            }
        } else { Start-Sleep -Milliseconds 10 }
    } while ((Get-Date) -lt $end)
    if (((Get-Date) - $script:lastBeat).TotalSeconds -ge 15) {
        $script:lastBeat = Get-Date
        Write-Out ("`n[... {0:HH:mm:ss} rx={1} bytes, suppressed={2} lines]" -f (Get-Date), $script:rxTotal, $script:suppressed)
    }
}

function Wait-Response([int]$TimeoutSec) {
    # returns ACK | NAK | CAN | C | TIMEOUT
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        Pump -Ms 120
        $txt = $textBuf.ToString()
        foreach ($pair in @(@('ACK', 0x06), @('NAK', 0x15), @('CAN', 0x18), @('C', 0x43))) {
            if ($txt.IndexOf([char]$pair[1]) -ge 0) {
                [void]$textBuf.Clear()
                return $pair[0]
            }
        }
        if ($textBuf.Length -gt 8192) { [void]$textBuf.Clear() }
    }
    return 'TIMEOUT'
}

function Open-Session {
    # poll 'x' until BL2 answers with the 'C' handshake
    Write-Out ("`n[{0:HH:mm:ss}] waiting for the BL2 XMODEM session; polling 'x' every {1}s`n" -f (Get-Date), $PollXSeconds)
    $end = (Get-Date).AddSeconds(900)
    $lastX = (Get-Date).AddSeconds(-$PollXSeconds)
    $sawPress = $false
    while ((Get-Date) -lt $end) {
        Pump -Ms 200
        $txt = $textBuf.ToString()
        if ($txt.Length -gt 0) {
            if ($txt.IndexOf('Press x') -ge 0 -and -not $sawPress) {
                $sawPress = $true
                Write-Out ("`n[{0:HH:mm:ss}] 'Press x' banner seen" -f (Get-Date))
            }
            [void]$textBuf.Clear()
        }
        if ($script:isoC -ge 2 -or ($sawPress -and $script:isoC -ge 1)) {
            Write-Out ("`n[{0:HH:mm:ss}] XMODEM handshake detected (bare 'C' bytes={1}, press banner={2})" -f (Get-Date), $script:isoC, $sawPress)
            $script:isoC = 0
            $script:isoCLastLen = 0
            [void]$lineBuf.Clear()
            return $true
        }
        if (-not $NoPollX -and ((Get-Date) - $lastX).TotalSeconds -ge $PollXSeconds) {
            $sp.Write([byte[]]@(0x78), 0, 1)
            $lastX = Get-Date
            Write-Out ("`n[{0:HH:mm:ss}] -> sent 'x'" -f (Get-Date))
        }
        if ($textBuf.Length -gt 8192) { [void]$textBuf.Clear() }
    }
    return $false
}

try {
    $sessionReady = $false
    if ($SendXAfter -gt 0) {
        Write-Out ("`n[{0:HH:mm:ss}] -SendXAfter {1}: sending 'x' without waiting for the banner`n" -f (Get-Date), $SendXAfter)
        Start-Sleep -Seconds $SendXAfter
        $sp.Write([byte[]]@(0x78), 0, 1)
        $r = Wait-Response -TimeoutSec 20
        Write-Out ("[{0:HH:mm:ss}] initial 'x' -> {1}`n" -f (Get-Date), $r)
        if ($r -eq 'C') { $sessionReady = $true }
    }

    if (-not $sessionReady) { $sessionReady = Open-Session }
    if (-not $sessionReady) { Write-Output "no XMODEM session; giving up"; return }

    while ($restarts -le $MaxRestarts) {
        Write-Out ("`n[{0:HH:mm:ss}] starting transfer attempt {1}/{2}`n" -f (Get-Date), ($restarts + 1), ($MaxRestarts + 1))
        $i = 0
        $stall = $false
        $start = Get-Date
        $lastReport = Get-Date
        while ($i -lt $packets.Count) {
            $sent = $false
            for ($try = 1; $try -le $MaxRetryPerPacket -and -not $sent; $try++) {
                $sp.Write($packets[$i], 0, $packets[$i].Length)
                $r = Wait-Response -TimeoutSec $PacketTimeoutSec
                if ($r -eq 'ACK') { $sent = $true }
                elseif ($r -eq 'C') { Write-Out ("`n[{0:HH:mm:ss}] receiver re-sent 'C' -> restarting image" -f (Get-Date)); $stall = $true; break }
                elseif ($r -eq 'CAN') { Write-Out ("`n[{0:HH:mm:ss}] CAN received -> restarting image" -f (Get-Date)); $stall = $true; break }
                else { Write-Out ("`n[{0:HH:mm:ss}] packet {1} -> {2} (try {3})" -f (Get-Date), ($i + 1), $r, $try) }
            }
            if ($stall) { break }
            if (-not $sent) {
                Write-Out ("`n[{0:HH:mm:ss}] packet {1} failed {2} times -> re-handshake" -f (Get-Date), ($i + 1), $MaxRetryPerPacket)
                $stall = $true
                break
            }
            $i++
            if (((Get-Date) - $lastReport).TotalSeconds -ge 2) {
                $lastReport = Get-Date
                Write-Out ("`r>> {0}/{1} packets ({2}%), attempt time {3:N0}s" -f $i, $packets.Count, [int]($i * 100 / $packets.Count), ((Get-Date) - $start).TotalSeconds)
            }
            if ((Get-Date) -gt $deadline) { Write-Output "overall deadline hit"; break }
        }

        if (-not $stall) {
            Write-Out ("`n[{0:HH:mm:ss}] all {1} packets ACKed in {2:N0}s -> sending EOT`n" -f (Get-Date), $packets.Count, ((Get-Date) - $start).TotalSeconds)
            $eotAck = $false
            for ($t = 0; $t -lt 5 -and -not $eotAck; $t++) {
                $sp.Write([byte[]]@(0x04), 0, 1)
                $r = Wait-Response -TimeoutSec 5
                Write-Out ("[{0:HH:mm:ss}] EOT -> {1}`n" -f (Get-Date), $r)
                if ($r -eq 'ACK') { $eotAck = $true }
            }
            if ($eotAck) {
                Write-Out ("`n[{0:HH:mm:ss}] FIP accepted. Forwarding device output for {1}s ...`n" -f (Get-Date), $LogSeconds)
                $end = (Get-Date).AddSeconds($LogSeconds)
                while ((Get-Date) -lt $end) { Pump -Ms 200 }
                break
            }
        }

        $restarts++
        if ($restarts -gt $MaxRestarts) { break }
        Write-Out ("`n[{0:HH:mm:ss}] restart #{1}: re-opening the XMODEM session`n" -f (Get-Date), $restarts)
        [void]$textBuf.Clear()
        if (-not (Open-Session)) { Write-Output "no session on restart; giving up"; break }
    }
} finally {
    try { if ($sp.IsOpen) { $sp.Close() } } catch { }
    try { $sp.Dispose() } catch { }
    try { $log.Flush(); $log.Close() } catch { }
    Write-Output ("`n[{0:HH:mm:ss}] serial port released. raw log ({1} bytes) -> {2}" -f (Get-Date), $rxTotal, $LogFile)
}
