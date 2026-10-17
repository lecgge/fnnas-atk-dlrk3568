param(
  [int]$Baud = 1500000,
  [string]$Log = 'C:\Users\Xuleyu\Documents\work\fn-atk\uart-boot.log',
  [int]$MaxSeconds = 900
)
$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort COM3,$Baud,None,8,one
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
$sp.WriteTimeout = 1000
$sp.DtrEnable = $false
$sp.RtsEnable = $false
try { $sp.Open() } catch { Write-Output "OPEN FAIL: $($_.Exception.Message)"; exit 1 }
Write-Output "=== 监听中 COM3 @ $Baud → $Log ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sb = New-Object System.Text.StringBuilder
$lastFlush = 0
while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) {
  try {
    $n = $sp.BytesToRead
    if ($n -gt 0) {
      $txt = [System.Text.Encoding]::UTF8.GetString($sp.Read($n))
      [void]$sb.Append($txt)
      Add-Content -Path $Log -Value $txt -NoNewline -Encoding UTF8
      $lastFlush = $sw.Elapsed.TotalSeconds
    }
  } catch { }
  Start-Sleep -Milliseconds 50
  # 空闲 45 秒后发两次换行，尝试唤醒 getty
  if ($sb.Length -gt 0 -and ($sw.Elapsed.TotalSeconds - $lastFlush) -gt 45 -and $sw.Elapsed.TotalSeconds -lt 60) {
    $sp.Write("`r`n"); Start-Sleep -Milliseconds 200; $sp.Write("`r`n")
  }
}
$sp.Close()
Write-Output "=== 结束，累计收到 $($sb.Length) 字节 ==="
