param(
    [string]$PortName = "COM4",
    [int]$BaudRate = 115200,
    [string]$LogPath = "$PSScriptRoot\outputs\ax3000t-serial.log",
    [string]$CommandPath = "$PSScriptRoot\outputs\ax3000t-serial-command.txt",
    [string]$AutoPattern = "",
    [string]$AutoText = ""
)

$ErrorActionPreference = "Stop"
$port = [System.IO.Ports.SerialPort]::new($PortName, $BaudRate, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$port.Handshake = [System.IO.Ports.Handshake]::None
$port.DtrEnable = $false
$port.RtsEnable = $false
$port.ReadTimeout = 100
$port.WriteTimeout = 1000
$writer = [System.IO.StreamWriter]::new($LogPath, $true, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$recent = ""
$autoSent = $false
if (-not (Test-Path -LiteralPath $CommandPath)) {
    [System.IO.File]::WriteAllText($CommandPath, "")
}

try {
    $port.Open()
    Write-Host "SERIAL_READY port=$PortName baud=$BaudRate log=$LogPath"
    while ($true) {
        if ($port.BytesToRead -gt 0) {
            $text = $port.ReadExisting()
            [Console]::Write($text)
            $writer.Write($text)
            $recent = ($recent + $text)
            if ($recent.Length -gt 4096) { $recent = $recent.Substring($recent.Length - 4096) }
            if (-not $autoSent -and $AutoPattern.Length -gt 0 -and $recent.Contains($AutoPattern)) {
                $port.Write($AutoText.Replace("\n", "`r"))
                $autoSent = $true
                Write-Host "`nSERIAL_AUTO_SENT $($AutoText.Trim())"
            }
        }
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $port.Write("`r")
            } elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                $port.Write([char]8)
            } elseif ($key.KeyChar -ne [char]0) {
                $port.Write([string]$key.KeyChar)
            }
        }
        $command = ""
        try {
            $command = [System.IO.File]::ReadAllText($CommandPath)
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 20
        }
        if ($command.Length -gt 0) {
            try {
                [System.IO.File]::WriteAllText($CommandPath, "")
            } catch [System.IO.IOException] {
                continue
            }
            $port.Write($command.Replace("\n", "`r"))
            Write-Host "`nSERIAL_SENT $($command.Trim())"
        }
        Start-Sleep -Milliseconds 10
    }
} finally {
    if ($port.IsOpen) { $port.Close() }
    $writer.Dispose()
}
