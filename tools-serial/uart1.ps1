param(
  [string]$Send = "",
  [int]$WaitMs = 2500,
  [int]$Baud = 1500000,
  [int]$TotalMs = 10000,
  [switch]$Dtr
)
$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort COM3,$Baud,None,8,one
$sp.Handshake = 'None'
$sp.ReadTimeout = 300
$sp.WriteTimeout = 1000
$sp.DtrEnable = [bool]$Dtr
$sp.RtsEnable = [bool]$Dtr
try { $sp.Open() } catch { Write-Output "OPEN FAIL: $($_.Exception.Message)"; exit 1 }
Write-Output "=== COM3 open @ $Baud DTR=$Dtr ==="

$sp.DiscardInBuffer()
$sp.Write("`r`n"); Start-Sleep -Milliseconds 400
if ($Send -ne "") { foreach ($l in ($Send -split "`n")) { $sp.Write($l + "`r`n"); Start-Sleep -Milliseconds 250 } }
Write-Output "=== sent ==="

$sb = New-Object System.Text.StringBuilder
$deadline = (Get-Date).AddMilliseconds($TotalMs); $lastLen = 0
while ((Get-Date) -lt $deadline) {
  try {
    $n = $sp.BytesToRead
    if ($n -gt 0) {
      [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($sp.Read($n)))
      $cur = $sb.Length
      if ($cur -ne $lastLen) { $lastLen = $cur; $deadline = (Get-Date).AddMilliseconds($WaitMs) }
    }
  } catch { }
  Start-Sleep -Milliseconds 80
}
$sp.Close()
Write-Output "=== recv $($sb.Length) bytes ==="
Write-Output $sb.ToString()
