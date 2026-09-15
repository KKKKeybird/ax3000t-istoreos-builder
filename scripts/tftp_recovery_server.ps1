param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string]$BindAddress = "192.168.1.2",
    [string]$ExpectedName = "firmware_ubi.bin"
)

$ErrorActionPreference = "Stop"
$payload = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $FilePath))
$ascii = [System.Text.Encoding]::ASCII
$listener = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($BindAddress), 69))
$listener.Client.ReceiveTimeout = 1000

function Send-Packet {
    param(
        [System.Net.Sockets.UdpClient]$Client,
        [System.Net.IPEndPoint]$Remote,
        [byte[]]$Packet
    )
    [void]$Client.Send($Packet, $Packet.Length, $Remote)
}

function Wait-Ack {
    param(
        [System.Net.Sockets.UdpClient]$Client,
        [int]$Block
    )
    $deadline = [Environment]::TickCount64 + 1800
    $Client.Client.ReceiveTimeout = 200
    while ([Environment]::TickCount64 -lt $deadline) {
        $sender = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $reply = $Client.Receive([ref]$sender)
            if ($reply.Length -lt 4) { continue }
            $opcode = ($reply[0] -shl 8) -bor $reply[1]
            $ackBlock = ($reply[2] -shl 8) -bor $reply[3]
            if ($opcode -eq 4 -and $ackBlock -eq $Block) { return $true }
        } catch [System.Net.Sockets.SocketException] {
            continue
        }
    }
    return $false
}

Write-Host "TFTP_READY bind=$BindAddress`:69 file=$ExpectedName bytes=$($payload.Length)"

while ($true) {
    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    try {
        $request = $listener.Receive([ref]$remote)
    } catch [System.Net.Sockets.SocketException] {
        continue
    }

    if ($request.Length -lt 4 -or $request[0] -ne 0 -or $request[1] -ne 1) { continue }
    $parts = $ascii.GetString($request, 2, $request.Length - 2).Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2) { continue }
    $requestedName = $parts[0]
    Write-Host "RRQ from=$remote name=$requestedName"

    if ([System.IO.Path]::GetFileName($requestedName) -ne $ExpectedName) {
        $message = $ascii.GetBytes("File not found")
        $errorPacket = [byte[]]::new(4 + $message.Length + 1)
        $errorPacket[1] = 5
        $errorPacket[3] = 1
        [Array]::Copy($message, 0, $errorPacket, 4, $message.Length)
        Send-Packet $listener $remote $errorPacket
        continue
    }

    $blockSize = 512
    $requestedOptions = [ordered]@{}
    for ($i = 2; $i + 1 -lt $parts.Count; $i += 2) {
        $requestedOptions[$parts[$i].ToLowerInvariant()] = $parts[$i + 1]
    }
    if ($requestedOptions.Contains("blksize")) {
        $candidate = 0
        if ([int]::TryParse($requestedOptions["blksize"], [ref]$candidate)) {
            $blockSize = [Math]::Min([Math]::Max($candidate, 8), 1468)
        }
    }

    $transfer = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($BindAddress), 0))
    $transfer.Client.ReceiveTimeout = 1200
    try {
        if ($requestedOptions.Count -gt 0) {
            $oack = [System.Collections.Generic.List[byte]]::new()
            $oack.Add(0); $oack.Add(6)
            if ($requestedOptions.Contains("blksize")) {
                $oack.AddRange($ascii.GetBytes("blksize")); $oack.Add(0)
                $oack.AddRange($ascii.GetBytes([string]$blockSize)); $oack.Add(0)
            }
            if ($requestedOptions.Contains("timeout")) {
                $oack.AddRange($ascii.GetBytes("timeout")); $oack.Add(0)
                $oack.AddRange($ascii.GetBytes([string]$requestedOptions["timeout"])); $oack.Add(0)
            }
            if ($requestedOptions.Contains("tsize")) {
                $oack.AddRange($ascii.GetBytes("tsize")); $oack.Add(0)
                $oack.AddRange($ascii.GetBytes([string]$payload.Length)); $oack.Add(0)
            }
            if ($requestedOptions.Contains("windowsize")) {
                $oack.AddRange($ascii.GetBytes("windowsize")); $oack.Add(0)
                $oack.AddRange($ascii.GetBytes("1")); $oack.Add(0)
            }
            $acked = $false
            for ($attempt = 0; $attempt -lt 8 -and -not $acked; $attempt++) {
                Send-Packet $transfer $remote $oack.ToArray()
                $acked = Wait-Ack $transfer 0
            }
            if (-not $acked) { throw "No ACK for OACK" }
        }

        $offset = 0
        $block = 1
        do {
            $count = [Math]::Min($blockSize, $payload.Length - $offset)
            $packet = [byte[]]::new(4 + $count)
            $packet[1] = 3
            $packet[2] = ($block -shr 8) -band 0xff
            $packet[3] = $block -band 0xff
            if ($count -gt 0) { [Array]::Copy($payload, $offset, $packet, 4, $count) }
            $acked = $false
            for ($attempt = 0; $attempt -lt 8 -and -not $acked; $attempt++) {
                Send-Packet $transfer $remote $packet
                $acked = Wait-Ack $transfer $block
            }
            if (-not $acked) { throw "No ACK for block $block" }
            $offset += $count
            if (($block % 512) -eq 0) { Write-Host "PROGRESS $offset/$($payload.Length)" }
            $block = ($block + 1) -band 0xffff
        } while ($count -eq $blockSize)
        Write-Host "TRANSFER_COMPLETE bytes=$offset"
    } catch {
        Write-Host "TRANSFER_FAILED $($_.Exception.Message)"
    } finally {
        $transfer.Dispose()
    }
}
