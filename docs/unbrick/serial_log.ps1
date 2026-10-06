<#
.SYNOPSIS
    Plain serial logger for the AN758x UART console (Windows PowerShell 5.1 / 7+).

.DESCRIPTION
    Opens a COM port at 115200 8N1 and dumps everything the board prints, together
    with a periodic health line.  Use it to confirm the wiring before running the
    XMODEM rescue script, and to read the BL2 / U-Boot console.

    The port is always released (Close + Dispose), including on Ctrl+C, so a
    follow-up run never fails with "Access to the path 'COMx' is denied".

.EXAMPLE
    .\serial_log.ps1 -ListPorts
    .\serial_log.ps1 -Port COM19 -Seconds 40
    .\serial_log.ps1 -Port COM19 -Seconds 600 -KeepAwakeKeys 'x'
#>
param(
    [string]$Port,
    [int]$Seconds = 40,
    [string]$OutFile = "",
    [string]$KeepAwakeKeys = "",
    [int]$KeyIntervalMs = 5000,
    [switch]$ListPorts
)

$ErrorActionPreference = 'Continue'

if ($ListPorts -or -not $Port) {
    Write-Output 'Serial ports reported by the .NET runtime:'
    [System.IO.Ports.SerialPort]::GetPortNames() | ForEach-Object { Write-Output ("  " + $_) }
    Write-Output ''
    Write-Output 'Ports known to Windows (Status OK = currently present):'
    Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue |
        Select-Object Status, FriendlyName | Format-Table -AutoSize | Out-String | Write-Output
    return
}

if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'serial_log.txt' }

$sp = [System.IO.Ports.SerialPort]::new($Port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 250
$sp.WriteTimeout = 2000
$sp.DtrEnable = $true
$sp.RtsEnable = $true

try {
    $sp.Open()
} catch {
    Write-Output ("OPEN FAILED on {0}: {1}" -f $Port, $_.Exception.Message)
    Write-Output "Hint: close any serial terminal (or a previous run of this script) that still holds the port."
    try { $sp.Dispose() } catch { }
    return
}

$stream = $null
try {
    $stream = New-Object System.IO.FileStream($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
} catch { }

Write-Output ("[{0:HH:mm:ss}] {1} opened at 115200 8N1 for {2}s. Ctrl+C stops early; the port is released either way." -f (Get-Date), $Port, $Seconds)
if ($KeepAwakeKeys) { Write-Output ("[{0:HH:mm:ss}] sending '{1}' every {2} ms" -f (Get-Date), $KeepAwakeKeys, $KeyIntervalMs) }

$rxTotal = 0
$printable = 0
$nextKey = Get-Date
$lastBeat = Get-Date

try {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $sp.BytesToRead
            if ($n -gt 0) {
                $bytes = New-Object byte[] $n
                $read = $sp.Read($bytes, 0, $n)
                if ($read -gt 0) {
                    $rxTotal += $read
                    for ($i = 0; $i -lt $read; $i++) {
                        $b = $bytes[$i]
                        if (($b -ge 32 -and $b -lt 127) -or $b -eq 10 -or $b -eq 13) { $printable++ }
                    }
                    if ($stream) { $stream.Write($bytes, 0, $read); $stream.Flush() }
                    $chunk = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $read)
                    [Console]::Out.Write($chunk)
                    [Console]::Out.Flush()
                }
            }
        } catch {
            Write-Output ("[{0:HH:mm:ss}] read error: {1}" -f (Get-Date), $_.Exception.Message)
        }

        if ($KeepAwakeKeys -and (Get-Date) -ge $nextKey) {
            try {
                $sp.Write($KeepAwakeKeys)
                $nextKey = (Get-Date).AddMilliseconds($KeyIntervalMs)
            } catch { }
        }

        if (((Get-Date) - $lastBeat).TotalSeconds -ge 10) {
            $lastBeat = Get-Date
            $pct = 0
            if ($rxTotal -gt 0) { $pct = [int]($printable * 100 / $rxTotal) }
            [Console]::Out.Write(("`n[{0:HH:mm:ss}] alive: rx={1} bytes, printable={2}% (below ~10% is line noise, not device text)`n" -f (Get-Date), $rxTotal, $pct))
            [Console]::Out.Flush()
        }

        Start-Sleep -Milliseconds 40
    }
} finally {
    try { if ($sp.IsOpen) { $sp.Close() } } catch { }
    try { $sp.Dispose() } catch { }
    try { if ($stream) { $stream.Flush(); $stream.Close() } } catch { }
    $pct = 0
    if ($rxTotal -gt 0) { $pct = [int]($printable * 100 / $rxTotal) }
    Write-Output ("`n[{0:HH:mm:ss}] {1} released. rx={2} bytes, printable={3}% -> {4}" -f (Get-Date), $Port, $rxTotal, $pct, $OutFile)
}
