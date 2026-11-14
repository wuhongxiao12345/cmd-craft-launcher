@echo off
chcp 65001 >nul
setlocal
set "SELF=%~f0"
set "CCL_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF);$i=$c.LastIndexOf('#PSSTART#');$s=$c.Substring($c.IndexOf([char]10,$i)+1);Invoke-Expression $s"
if not defined CCL_ARGS pause
exit /b
#PSSTART#
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:LauncherPath = $env:SELF
if (-not $script:LauncherPath) { $script:LauncherPath = (Get-Location).Path + [IO.Path]::DirectorySeparatorChar + 'ccl.bat' }
$script:Root    = Split-Path -Parent $script:LauncherPath
$script:CclDir  = Join-Path $script:Root 'ccl'
$script:McDir   = Join-Path $script:Root '.minecraft'
$script:CacheDir= Join-Path $script:CclDir 'cache'
$script:JavaDir = Join-Path $script:CclDir 'java'
$script:ConfigPath = Join-Path $script:CclDir 'config.json'
$script:Sep = [string][IO.Path]::DirectorySeparatorChar
$script:CP  = [string][IO.Path]::PathSeparator

# 自适应下载并发：按逻辑核心数，2~8 核 → 8~32 线程
function Get-DlThreads {
  $cores = 4
  try { $cores = [Environment]::ProcessorCount } catch {}
  $n = $cores * 4
  if ($n -lt 8) { $n = 8 }
  if ($n -gt 32) { $n = 32 }
  return $n
}

# 架构自识别（32/64 位）
$script:Is64 = $true
try { $script:Is64 = [Environment]::Is64BitOperatingSystem } catch {}
$script:OSArch = if ($script:Is64) { 'x64' } else { 'x86' }
$script:JvmArch = if ($script:Is64) { '64' } else { '32' }
$script:NativesArch = if ($script:Is64) { 'natives-windows' } else { 'natives-windows-x86' }

foreach ($d in @($script:CclDir,$script:McDir,$script:CacheDir,$script:JavaDir,
                 (Join-Path $script:McDir 'versions'),(Join-Path $script:McDir 'libraries'),
                 (Join-Path $script:McDir 'assets'),(Join-Path $script:McDir 'mods'))) {
  try {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
  } catch {
    Write-Host ('错误: 无法创建目录 ' + $d) -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor DarkGray
    if (-not $env:CCL_ARGS) { [void](Read-Host '按回车退出') }
    exit 1
  }
}

# 写权限探测
try {
  $probe = Join-Path $script:CclDir ('.wp_' + [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($probe, 'x')
  Remove-Item -LiteralPath $probe -Force -EA SilentlyContinue
} catch {
  Write-Host ('错误: ' + $script:CclDir + ' 不可写，请检查权限。') -ForegroundColor Red
  if (-not $env:CCL_ARGS) { [void](Read-Host '按回车退出') }
  exit 1
}

# 环境依赖检查：curl/tar 为下载与解压必需（Win10 1803+ 自带）
function Test-CommandExists($name) { return ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) }
if (-not (Test-CommandExists 'curl.exe')) {
  Write-Host '错误: 未找到 curl.exe，无法下载文件。请升级到 Windows 10 1803+ 或手动安装 curl。' -ForegroundColor Red
  if (-not $env:CCL_ARGS) { [void](Read-Host '按回车退出'); exit 1 }
}

# launcher_profiles.json：Forge 安装器要求存在（PCL2/HMCL 也会生成）
$lpFile = Join-Path $script:McDir 'launcher_profiles.json'
if (-not (Test-Path -LiteralPath $lpFile)) { try { [IO.File]::WriteAllText($lpFile, '{}', [Text.Encoding]::UTF8) } catch {} }

function Get-Config {
  $d = [ordered]@{
    PlayerName = 'Player'
    JavaPath = ''
    SelectedVersion = ''
    SelectedLoader = 'vanilla'
    SelectedLoaderVersion = ''
    MemoryMB = 2048
    WindowWidth = 854
    WindowHeight = 480
    GameDir = ''
    JvmArgs = ''
    Fullscreen = $false
    DemoMode = $false
    ExtraGameArgs = ''
    VersionIsolation = $false
    DebugMode = $false
  }
  if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
      $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
      $j = $raw | ConvertFrom-Json
      foreach ($k in @($d.Keys)) {
        if ($null -ne $j.PSObject.Properties[$k] -and $null -ne $j.$k) { $d[$k] = $j.$k }
      }
    } catch {
      # 配置损坏：备份并继续用默认值
      try { Copy-Item -LiteralPath $script:ConfigPath -Destination ($script:ConfigPath + '.corrupt') -Force -EA SilentlyContinue } catch {}
      Write-Host '  警告: 配置文件损坏，已备份为 config.json.corrupt 并使用默认设置' -ForegroundColor Yellow
    }
  }
  # 值钳制，防止手改配置导致崩溃
  try { $d.MemoryMB = [Math]::Max(512, [Math]::Min(65536, [int]$d.MemoryMB)) } catch { $d.MemoryMB = 2048 }
  try { $d.WindowWidth = [Math]::Max(320, [Math]::Min(7680, [int]$d.WindowWidth)) } catch { $d.WindowWidth = 854 }
  try { $d.WindowHeight = [Math]::Max(240, [Math]::Min(4320, [int]$d.WindowHeight)) } catch { $d.WindowHeight = 480 }
  if (-not $d.PlayerName -or $d.PlayerName.Trim() -eq '') { $d.PlayerName = 'Player' }
  return $d
}
function Save-Config($cfg) {
  try {
    $json = $cfg | ConvertTo-Json -Depth 10
    $tmp = $script:ConfigPath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:ConfigPath) {
      Copy-Item -LiteralPath $script:ConfigPath -Destination ($script:ConfigPath + '.bak') -Force -EA SilentlyContinue
    }
    Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
  } catch {
    Write-Host ('  警告: 配置保存失败: ' + $_.Exception.Message) -ForegroundColor Yellow
  }
}

# 读取 PCL.ini 中的版本隔离开关（兼容 PCL2 已有配置）
# 返回 $true/$false；无 PCL.ini 或未设置时返回 $null（未知）
function Get-PclIsolation {
  $ini = Join-Path $script:McDir 'PCL.ini'
  if (-not (Test-Path -LiteralPath $ini)) { return $null }
  try {
    foreach ($ln in [IO.File]::ReadAllLines($ini, [Text.Encoding]::UTF8)) {
      $t = $ln.Trim()
      if (-not $t) { continue }
      $eq = $t.IndexOf('=')
      if ($eq -lt 0) { continue }
      $k = $t.Substring(0, $eq).Trim()
      $v = $t.Substring($eq + 1).Trim()
      if ($k -eq 'VersionArgumentIndie' -or $k -eq 'VersionIsolation') {
        $n = 0
        if ([int]::TryParse($v, [ref]$n)) { return ($n -ne 0) }
        return ($v -eq 'true' -or $v -eq '1')
      }
    }
  } catch {}
  return $null
}

# 版本隔离状态：优先沿用 PCL.ini，其次用 config 设置
function Test-VersionIsolation {
  $pcl = Get-PclIsolation
  if ($null -ne $pcl) { return $pcl }
  $cfg = Get-Config
  return [bool]$cfg.VersionIsolation
}

# 指定版本的工作目录：
#   1) 用户显式指定了 GameDir → 用它
#   2) 版本目录内已存在隔离结构（mods/saves 等）或 PCL.ini 指示隔离 → 用版本目录
#   3) 否则用 .minecraft 根目录
function Get-VersionDir($id) {
  $cfg = Get-Config
  if ($cfg.GameDir -and (Test-Path -LiteralPath $cfg.GameDir)) { return $cfg.GameDir }
  if (-not $id) { return $script:McDir }
  $verDir = Join-Path (Join-Path $script:McDir 'versions') $id
  $hasIsolation = $false
  foreach ($sub in @('mods','saves','resourcepacks','config')) {
    if (Test-Path -LiteralPath (Join-Path $verDir $sub)) { $hasIsolation = $true; break }
  }
  if ($hasIsolation -or (Test-VersionIsolation)) { return $verDir }
  return $script:McDir
}

# 当前版本的 Mod 目录（隔离时在版本目录内）
function Get-ModDir($id = $null) {
  $cfg = Get-Config
  if (-not $id) { $id = $cfg.SelectedVersion }
  if ($cfg.GameDir -and (Test-Path -LiteralPath $cfg.GameDir)) { return (Join-Path $cfg.GameDir 'mods') }
  if ($id) {
    $verDir = Join-Path (Join-Path $script:McDir 'versions') $id
    if (Test-Path -LiteralPath (Join-Path $verDir 'mods')) { return (Join-Path $verDir 'mods') }
  }
  if (Test-VersionIsolation -and $id) { return (Join-Path (Join-Path (Join-Path $script:McDir 'versions') $id) 'mods') }
  return (Join-Path $script:McDir 'mods')
}

function Get-Json {
  param($url, $cacheName, $maxAgeMinutes = 60)
  if ($cacheName) {
    $p = Join-Path $script:CacheDir $cacheName
    if (Test-Path -LiteralPath $p) {
      $age = (Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime
      if ($age.TotalMinutes -lt $maxAgeMinutes) {
        try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
      }
    }
  }
  $tmp = Join-Path $script:CacheDir ('dl_' + [guid]::NewGuid().ToString('N') + '.tmp')
  $ok = $false; $txt = ''
  $tryUrls = Get-UrlWithMirror $url
  foreach ($u in $tryUrls) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      & curl.exe -s -f -L --ssl-no-revoke --retry 1 -m 30 -A 'ccl-launcher/1.0.3-beta' -o $tmp $u
      if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) {
        $txt = [IO.File]::ReadAllText($tmp)
        if ($txt.Trim()) { $ok = $true; break }
      }
      Start-Sleep -Milliseconds (300 * $attempt)
    }
    if ($ok) { break }
  }
  Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
  if (-not $ok) { throw ('请求失败(含镜像): ' + $url) }
  $obj = $null
  try { $obj = $txt | ConvertFrom-Json } catch { throw ('响应不是有效 JSON: ' + $url) }
  if ($null -eq $obj) { throw ('响应为空: ' + $url) }
  if ($cacheName) { try { [IO.File]::WriteAllText((Join-Path $script:CacheDir $cacheName), $txt, [Text.Encoding]::UTF8) } catch {} }
  return $obj
}
function Format-Bytes($b) {
  if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N2} MB' -f ($b / 1MB)) }
  if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
  return ('' + [int]$b + ' B')
}

function Draw-ProgressBar($done, $total, $extra = '') {
  $width = 28
  $frac = 0.0
  if ($total -gt 0) { $frac = [double]$done / [double]$total }
  if ($frac -gt 1) { $frac = 1.0 }
  if ($frac -lt 0) { $frac = 0.0 }
  $fill = [int][Math]::Round($frac * $width)
  if ($fill -gt $width) { $fill = $width }
  if ($fill -lt 0) { $fill = 0 }
  $bar = ('#' * $fill) + ('.' * ($width - $fill))
  $pct = [int][Math]::Round($frac * 100)
  $line = '  [' + $bar + '] ' + $pct.ToString().PadLeft(3) + '%  ' + $extra
  Write-Host ([char]13 + $line) -NoNewline
}

function Test-FileHashMatch($path, $sha1, $sha512) {
  if ($sha1) {
    try { if ((Get-FileHash -LiteralPath $path -Algorithm SHA1).Hash -ne ([string]$sha1).ToUpper()) { return $false } } catch { return $false }
  }
  if ($sha512) {
    try { if ((Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash -ne ([string]$sha512).ToUpper()) { return $false } } catch { return $false }
  }
  return $true
}

function Download-File {
  param($url, $dest, $sha1, $showProgress = $false, $sha512 = $null)
  if (Test-Path -LiteralPath $dest) {
    if (-not $sha1 -and -not $sha512) { return }
    if (Test-FileHashMatch $dest $sha1 $sha512) { return }
  }
  $dir = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = $dest + '.tmp'
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
  $allUrls = @(Get-UrlWithMirror $url)
  $ua = 'ccl-launcher/1.0.3-beta'
  if (-not $showProgress) {
    $ok = $false
    foreach ($u in $allUrls) {
      & curl.exe -s -f -L --ssl-no-revoke --retry 1 -m 120 -A $ua -o $tmp $u
      if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) {
        if (Test-FileHashMatch $tmp $sha1 $sha512) { $ok = $true; break }
      }
      Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
    }
    if (-not $ok) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; throw ('下载失败: ' + $url) }
  } else {
    # 先用 HEAD 探测可用源与大小，避免为探测整包下载一次
    $cands = New-Object System.Collections.ArrayList
    $sizeMap = @{}
    foreach ($u in $allUrls) {
      $sz = [int64]0; $headOk = $false
      try {
        $hdr = & curl.exe -s -f -I -L --ssl-no-revoke -m 10 -A $ua $u 2>$null
        if ($LASTEXITCODE -eq 0) {
          $headOk = $true
          foreach ($ln in $hdr) { if ($ln -match '(?i)content-length:\s*(\d+)') { $sz = [int64]$Matches[1]; break } }
        }
      } catch {}
      $sizeMap[$u] = $sz
      if ($headOk) { [void]$cands.Add($u) }
    }
    # HEAD 全部失败时退回按原顺序直接下载（部分 CDN 不支持 HEAD）
    if ($cands.Count -eq 0) { foreach ($u in $allUrls) { [void]$cands.Add($u) } }

    $ok = $false
    foreach ($useUrl in $cands) {
      $totalSize = [int64]0
      if ($sizeMap.ContainsKey($useUrl)) { $totalSize = [int64]$sizeMap[$useUrl] }
      Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
      $proc = Start-Process -FilePath 'curl.exe' -ArgumentList @('-s','-f','-L','--ssl-no-revoke','--retry','2','-m','1800','-A',$ua,'-o',$tmp,$useUrl) -PassThru -WindowStyle Hidden
      $lastT = [DateTime]::Now; $lastB = [int64]0
      while (-not $proc.HasExited) {
        $cur = [int64]0
        if (Test-Path -LiteralPath $tmp) { try { $cur = (Get-Item -LiteralPath $tmp).Length } catch {} }
        $now = [DateTime]::Now
        $spd = ''
        if (($now - $lastT).TotalMilliseconds -ge 500) {
          $bps = ($cur - $lastB) / ($now - $lastT).TotalSeconds
          if ($bps -gt 0) { $spd = '  ' + (Format-Bytes ([int64]$bps)) + '/s' }
          $lastT = $now; $lastB = $cur
        }
        if ($totalSize -gt 0) {
          if ($cur -gt $totalSize) { $totalSize = $cur }
          Draw-ProgressBar $cur $totalSize ((Format-Bytes $cur) + ' / ' + (Format-Bytes $totalSize) + $spd)
        } else {
          $spin = '|/-\'[($cur / 1048576) % 4]
          Write-Host ([char]13 + '  ' + $spin + '  ' + (Format-Bytes $cur) + $spd + '   ') -NoNewline
        }
        Start-Sleep -Milliseconds 250
      }
      $finalSize = [int64]0
      if (Test-Path -LiteralPath $tmp) { try { $finalSize = (Get-Item -LiteralPath $tmp).Length } catch {} }
      if ($totalSize -le 0) { $totalSize = $finalSize }
      Draw-ProgressBar $totalSize $totalSize ((Format-Bytes $finalSize) + ' / ' + (Format-Bytes $totalSize))
      Write-Host ''
      if ($proc.ExitCode -ne 0) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; continue }
      if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -eq 0) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; continue }
      if (-not (Test-FileHashMatch $tmp $sha1 $sha512)) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; continue }
      $ok = $true; break
    }
    if (-not $ok) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; throw ('下载失败(所有镜像不可用或校验不通过): ' + $url) }
  }
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}

# 为给定 URL 生成备选（含镜像）地址列表
function Get-UrlWithMirror($url) {
  $list = New-Object System.Collections.ArrayList
  [void]$list.Add($url)
  # NeoForge / Forge maven -> BMCBL 镜像
  if ($url -match '^https?://maven\.neoforged\.net/releases/(.+)$') {
    [void]$list.Add('https://bmclapi2.bangbang93.com/maven/' + $Matches[1])
  }
  if ($url -match '^https?://(files|maven)\.minecraftforge\.net/(?:maven/)?(.+)$') {
    [void]$list.Add('https://bmclapi2.bangbang93.com/maven/' + $Matches[2])
  }
  # Mojang 资源镜像
  if ($url -match '^https?://(piston-meta|launcher|launchermeta)\.mojang\.com/(.+)$') {
    [void]$list.Add('https://bmclapi2.bangbang93.com/' + $Matches[1] + '/' + $Matches[2])
  }
  if ($url -match '^https?://resources\.download\.minecraft\.net/(.+)$') {
    [void]$list.Add('https://bmclapi2.bangbang93.com/assets/' + $Matches[1])
  }
  if ($url -match '^https?://piston-data\.mojang\.com/(.+)$') {
    [void]$list.Add('https://bmclapi2.bangbang93.com/' + $Matches[1])
  }
  return @($list | Select-Object -Unique)
}

$script:DlScript = @'
param($url, $dest, $sha1, $altUrls)
try {
  if (Test-Path -LiteralPath $dest) {
    if (-not $sha1) { return @{ Ok = $true } }
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA1).Hash -eq $sha1.ToUpper()) { return @{ Ok = $true } }
  }
  $dir = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = $dest + '.' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp'
  $urls = @($url) + @($altUrls)
  $downloaded = $false
  foreach ($u in $urls) {
    & curl.exe -s -f -L --ssl-no-revoke --retry 1 -m 120 -A 'ccl-launcher/1.0.3-beta' -o $tmp $u
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) { $downloaded = $true; break }
    Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
  }
  if (-not $downloaded) { return @{ Ok = $false; Url = $url } }
  if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -eq 0) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; return @{ Ok = $false; Url = $url } }
  if ($sha1) {
    $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash
    if ($got -ne $sha1.ToUpper()) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue; return @{ Ok = $false; Url = $url } }
  }
  Move-Item -LiteralPath $tmp -Destination $dest -Force
  return @{ Ok = $true }
} catch { return @{ Ok = $false; Url = $url } }
'@

function Download-Pool {
  param($items, $throttle = 16, $label = '下载')
  if (-not $items -or $items.Count -eq 0) { return @() }
  $pool = [runspacefactory]::CreateRunspacePool(1, $throttle)
  $pool.Open()
  $handles = New-Object System.Collections.ArrayList
  $destMap = @{}
  foreach ($it in $items) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    $altUrls = @(Get-UrlWithMirror $it.Url | Select-Object -Skip 1)
    [void]$ps.AddScript($script:DlScript).AddArgument($it.Url).AddArgument($it.Dest).AddArgument($it.Sha1).AddArgument($altUrls)
    $h = @{ PS = $ps; H = $ps.BeginInvoke(); Dest = $it.Dest; Url = $it.Url; Finished = $false; Ok = $false }
    [void]$handles.Add($h)
  }
  $failed = New-Object System.Collections.ArrayList
  $total = $handles.Count
  $done = 0
  $lastT = [DateTime]::Now
  $lastBytes = [int64]0
  $startT = [DateTime]::Now
  $lastProgressT = [DateTime]::Now
  $lastDoneSnap = 0
  while ($done -lt $total) {
    if (([DateTime]::Now - $startT).TotalSeconds -gt 1800) { Write-Host ''; Write-Host '  下载超时，终止' -ForegroundColor Yellow; break }
    if ($done -gt $lastDoneSnap) { $lastDoneSnap = $done; $lastProgressT = [DateTime]::Now }
    elseif (([DateTime]::Now - $lastProgressT).TotalSeconds -gt 90) { Write-Host ''; Write-Host '  下载停滞超过90s（网络不可达），终止' -ForegroundColor Yellow; break }
    $bytesNow = [int64]0
    $activeDirs = @{}
    foreach ($h in $handles) {
      if ($h.Finished) {
        if (Test-Path -LiteralPath $h.Dest) { try { $bytesNow += (Get-Item -LiteralPath $h.Dest).Length } catch {} }
      } elseif ($h.H.IsCompleted) {
        $r = $null
        try { $r = $h.PS.EndInvoke($h.H) } catch { $r = @{ Ok = $false; Url = $h.Url } }
        $h.PS.Dispose()
        $h.Finished = $true
        $done++
        if ($r -and $r.Count -gt 0) { $h.Ok = [bool]$r[0].Ok } else { $h.Ok = $false }
        if (-not $h.Ok) { [void]$failed.Add($h.Url) }
        if (Test-Path -LiteralPath $h.Dest) { try { $bytesNow += (Get-Item -LiteralPath $h.Dest).Length } catch {} }
      } else {
        $pd = $null
        try { $pd = Split-Path -Parent $h.Dest } catch {}
        if ($pd) { $activeDirs[$pd] = $true }
      }
    }
    # 同一目录的临时文件只统计一次，避免每个任务都扫描目录（资源文件有数千个）
    foreach ($pd in $activeDirs.Keys) {
      try {
        $sum = (Get-ChildItem -LiteralPath $pd -Filter '*.tmp' -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sum) { $bytesNow += [int64]$sum }
      } catch {}
    }
    $now = [DateTime]::Now
    $spd = ''
    if (($now - $lastT).TotalSeconds -ge 0.5) {
      $bps = ($bytesNow - $lastBytes) / ($now - $lastT).TotalSeconds
      if ($bps -gt 0) { $spd = '  ' + (Format-Bytes ([int64]$bps)) + '/s' }
      $lastT = $now; $lastBytes = $bytesNow
    }
    $info = ($done.ToString() + '/' + $total + '  ' + (Format-Bytes $bytesNow) + $spd)
    Draw-ProgressBar $done $total $info
    if ($done -lt $total) { Start-Sleep -Milliseconds 250 }
  }
  Write-Host ''
  foreach ($h in $handles) { if (-not $h.Finished) { try { $h.PS.Stop() } catch {}; try { $h.PS.Dispose() } catch {} } }
  try { $pool.Close() } catch {}; try { $pool.Dispose() } catch {}
  if ($failed.Count -gt 0) {
    Write-Host ('  重试 ' + $failed.Count + ' 个失败项...') -ForegroundColor Yellow
    $retryItems = @()
    foreach ($u in $failed) {
      $it = $items | Where-Object { $_.Url -eq $u } | Select-Object -First 1
      if ($it) { $retryItems += $it }
    }
    if ($retryItems.Count -gt 0) {
      $pool2 = [runspacefactory]::CreateRunspacePool(1, 4)
      $pool2.Open()
      $h2 = New-Object System.Collections.ArrayList
      foreach ($it in $retryItems) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool2
        $altUrls2 = @(Get-UrlWithMirror $it.Url | Select-Object -Skip 1)
        [void]$ps.AddScript($script:DlScript).AddArgument($it.Url).AddArgument($it.Dest).AddArgument($it.Sha1).AddArgument($altUrls2)
        [void]$h2.Add(@{ PS = $ps; H = $ps.BeginInvoke(); Url = $it.Url; Done = $false })
      }
      $failed2 = New-Object System.Collections.ArrayList
      $rStart = [DateTime]::Now; $pending = $h2.Count
      while ($pending -gt 0) {
        if (([DateTime]::Now - $rStart).TotalSeconds -gt 180) { Write-Host '  重试超时，停止' -ForegroundColor Yellow; break }
        foreach ($h in $h2) {
          if ($h.H.IsCompleted -and -not $h.Done) {
            $h.Done = $true; $r = $null
            try { $r = $h.PS.EndInvoke($h.H) } catch { $r = @{ Ok = $false; Url = $h.Url } }
            $h.PS.Dispose(); $pending--
            if ($r -and $r.Count -gt 0 -and -not $r[0].Ok) { [void]$failed2.Add($h.Url) }
          }
        }
        if ($pending -gt 0) { Start-Sleep -Milliseconds 250 }
      }
      foreach ($h in $h2) {
        if (-not $h.Done) {
          # 超时未完成的项同样算失败，不能静默当作成功
          [void]$failed2.Add($h.Url)
          try { $h.PS.Stop() } catch {}
          try { $h.PS.Dispose() } catch {}
        }
      }
      try { $pool2.Close() } catch {}; try { $pool2.Dispose() } catch {}
      return @($failed2)
    }
  }
  return @($failed)
}

function Get-VersionManifest { return Get-Json 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json' 'version_manifest_v2.json' 60 }

function Get-VersionJson($id) {
  $verDir  = Join-Path (Join-Path $script:McDir 'versions') $id
  $jsonPath= Join-Path $verDir ($id + '.json')
  if (Test-Path -LiteralPath $jsonPath) {
    try {
      $raw = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8
      $obj = $raw | ConvertFrom-Json
      if ($null -ne $obj) { return $obj }
    } catch {
      # 本地 JSON 损坏，删除后重新下载
      Write-Host ('  版本 JSON 损坏，重新获取: ' + $id) -ForegroundColor Yellow
      Remove-Item -LiteralPath $jsonPath -Force -EA SilentlyContinue
    }
  }
  $man = Get-VersionManifest
  $v = $man.versions | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $v) { throw ('版本不存在: ' + $id) }
  if (-not (Test-Path -LiteralPath $verDir)) { New-Item -ItemType Directory -Force -Path $verDir | Out-Null }
  Download-File $v.url $jsonPath $v.sha1
  try { return (Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { throw ('版本 JSON 解析失败: ' + $id) }
}

function Test-Rules($rules, $features = @{}) {
  if (-not $rules) { return $true }
  $allow = $false
  foreach ($r in $rules) {
    $ok = $true
    if ($r.os) {
      if ($r.os.name -and $r.os.name -ne 'windows') { $ok = $false }
      if ($r.os.arch) {
        if ($r.os.arch -eq 'x86' -and $script:Is64) { $ok = $false }
        elseif ($r.os.arch -eq 'x64' -and -not $script:Is64) { $ok = $false }
      }
      if ($r.os.version) { $ok = $false }
    }
    if ($r.features) {
      foreach ($f in $r.features.PSObject.Properties) {
        $want = [bool]$f.Value
        $have = $false
        if ($features.ContainsKey($f.Name)) { $have = [bool]$features[$f.Name] }
        if ($want -ne $have) { $ok = $false }
      }
    }
    if ($ok) { $allow = ($r.action -eq 'allow') }
  }
  return $allow
}

function Resolve-Version($id) {
  $chain = New-Object System.Collections.ArrayList
  $cur = $id
  $seen = @{}
  while ($cur -and -not $seen.ContainsKey($cur)) {
    $seen[$cur] = $true
    $j = Get-VersionJson $cur
    [void]$chain.Add(@{ Id = $cur; Json = $j })
    $cur = $j.inheritsFrom
  }
  if ($chain.Count -eq 0) { throw ('无法解析版本: ' + $id) }
  $baseId = $chain[$chain.Count - 1].Id
  $rev = @($chain); [array]::Reverse($rev)
  $libMap = @{}; $libOrder = New-Object System.Collections.ArrayList
  $gameArgs = New-Object System.Collections.ArrayList
  $jvmArgs  = New-Object System.Collections.ArrayList
  $meta = [ordered]@{
    id = $id; baseId = $baseId; type = 'release'; mainClass = ''
    assets = ''; assetIndex = $null; downloads = $null
    javaVersion = $null; legacyArgs = $null
  }
  foreach ($e in $rev) {
    $j = $e.Json
    foreach ($k in @('type','mainClass','assets','assetIndex','downloads','javaVersion','logging')) {
      if ($null -ne $j.PSObject.Properties[$k] -and $null -ne $j.$k) { $meta[$k] = $j.$k }
    }
    if ($null -ne $j.PSObject.Properties['minecraftArguments'] -and $j.minecraftArguments) { $meta.legacyArgs = $j.minecraftArguments }
    if ($j.arguments) {
      if ($j.arguments.game) { foreach ($x in $j.arguments.game) { [void]$gameArgs.Add($x) } }
      if ($j.arguments.jvm)  { foreach ($x in $j.arguments.jvm)  { [void]$jvmArgs.Add($x) } }
    }
    if ($j.libraries) {
      foreach ($l in $j.libraries) {
        $n = $l.name
        if (-not $libMap.ContainsKey($n)) { [void]$libOrder.Add($n) }
        $libMap[$n] = $l
      }
    }
  }
  $libs = @(); foreach ($n in $libOrder) { $libs += $libMap[$n] }
  $meta.libraries = $libs
  $meta.gameArgs = $gameArgs
  $meta.jvmArgs = $jvmArgs
  return $meta
}

function Get-LibPath($lib) {
  if ($lib.downloads -and $lib.downloads.artifact -and $lib.downloads.artifact.path) { return $lib.downloads.artifact.path }
  $p = $lib.name -split ':'
  if ($p.Count -lt 3) { return $null }
  $g = $p[0] -replace '[.]', '/'
  $a = $p[1]; $v = $p[2]; $c = ''
  if ($p.Count -ge 4) { $c = '-' + $p[3] }
  return ($g + '/' + $a + '/' + $v + '/' + $a + '-' + $v + $c + '.jar')
}

function Resolve-Args($list, $features = @{}) {
  $out = @()
  foreach ($a in $list) {
    if ($a -is [string]) { $out += $a; continue }
    if (Test-Rules $a.rules $features) {
      if ($a.value -is [array]) { $out += $a.value } else { $out += [string]$a.value }
    }
  }
  return $out
}

function Install-Version($id, $select = $true) {
  Write-Host ('正在解析版本 ' + $id + ' ...') -ForegroundColor DarkGray
  $res = Resolve-Version $id
  if (-not $res.downloads -or -not $res.downloads.client) { throw '该版本缺少客户端下载信息' }

  $verDir   = Join-Path (Join-Path $script:McDir 'versions') $res.baseId
  $clientJar= Join-Path $verDir ($res.baseId + '.jar')
  if (-not (Test-Path -LiteralPath $verDir)) { New-Item -ItemType Directory -Force -Path $verDir | Out-Null }

  Write-Host '下载客户端主文件...' -ForegroundColor DarkGray
  Download-File $res.downloads.client.url $clientJar $res.downloads.client.sha1 $true

  $libRoot = Join-Path $script:McDir 'libraries'
  $libItems = New-Object System.Collections.ArrayList
  $nativeJars = New-Object System.Collections.ArrayList
  foreach ($lib in $res.libraries) {
    if (-not (Test-Rules $lib.rules)) { continue }
    if ($lib.name -like '*natives-*') {
      $parts = $lib.name -split ':'
      $cls = ''
      if ($parts.Count -ge 4) { $cls = $parts[3] }
      # 仅取当前架构匹配的 natives
      $want = $script:NativesArch
      if ($cls -ne 'natives-windows' -and $cls -ne $want) { continue }
      if (-not $script:Is64 -and $cls -eq 'natives-windows') { continue }
      if ($script:Is64 -and $cls -eq 'natives-windows-x86') { continue }
      $dl = $lib.downloads.artifact
      if ($dl) {
        $dest = Join-Path $libRoot ($dl.path -replace '/', $script:Sep)
        [void]$libItems.Add(@{ Url = $dl.url; Dest = $dest; Sha1 = $dl.sha1 })
        [void]$nativeJars.Add($dest)
      }
      continue
    }
    if ($lib.natives -and $lib.natives.windows) {
      $cls = $lib.natives.windows
      # 32 位时优先 x86 classifier
      if (-not $script:Is64 -and $lib.downloads.classifiers -and $lib.downloads.classifiers.($cls + '-x86')) { $cls = $cls + '-x86' }
      if ($lib.downloads.classifiers -and $lib.downloads.classifiers.$cls) {
        $dl = $lib.downloads.classifiers.$cls
        $dest = Join-Path $libRoot ($dl.path -replace '/', $script:Sep)
        [void]$libItems.Add(@{ Url = $dl.url; Dest = $dest; Sha1 = $dl.sha1 })
        [void]$nativeJars.Add($dest)
      }
      continue
    }
    if ($lib.downloads -and $lib.downloads.artifact) {
      $dl = $lib.downloads.artifact
      $dest = Join-Path $libRoot ($dl.path -replace '/', $script:Sep)
      [void]$libItems.Add(@{ Url = $dl.url; Dest = $dest; Sha1 = $dl.sha1 })
    }
  }
  Write-Host ('下载依赖库 (' + $libItems.Count + ')') -ForegroundColor DarkGray
  $f1 = Download-Pool $libItems (Get-DlThreads) '依赖库'
  if ($f1.Count -gt 0) { Write-Host ('  有 ' + $f1.Count + ' 个依赖下载失败') -ForegroundColor Yellow }

  $nativesDir = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $res.baseId) 'natives'
  if (-not (Test-Path -LiteralPath $nativesDir)) { New-Item -ItemType Directory -Force -Path $nativesDir | Out-Null }
  # 清理旧的 natives，避免版本更新后残留旧 DLL 造成冲突
  Get-ChildItem -LiteralPath $nativesDir -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  foreach ($nj in $nativeJars) {
    if (-not (Test-Path -LiteralPath $nj)) { continue }
    try {
      $zip = [IO.Compression.ZipFile]::OpenRead($nj)
      foreach ($e in $zip.Entries) {
        if ([string]::IsNullOrEmpty($e.Name)) { continue }
        if ($e.FullName -like 'META-INF/*') { continue }
        $t = Join-Path $nativesDir $e.Name
        [void][IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
      }
      $zip.Dispose()
    } catch { Write-Host ('  解压本地库失败: ' + $nj) -ForegroundColor Yellow }
  }

  $f2 = @()
  if ($res.assetIndex) {
    $idxDir = Join-Path (Join-Path $script:McDir 'assets') 'indexes'
    if (-not (Test-Path -LiteralPath $idxDir)) { New-Item -ItemType Directory -Force -Path $idxDir | Out-Null }
    $idxPath = Join-Path $idxDir ($res.assetIndex.id + '.json')
    Write-Host '下载资源索引...' -ForegroundColor DarkGray
    Download-File $res.assetIndex.url $idxPath $res.assetIndex.sha1 $true
    $idx = Get-Content -LiteralPath $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $objRoot = Join-Path (Join-Path $script:McDir 'assets') 'objects'
    $aitems = New-Object System.Collections.ArrayList
    foreach ($p in $idx.objects.PSObject.Properties) {
      $h = $p.Value.hash
      $pre = $h.Substring(0,2)
      $dest = Join-Path (Join-Path $objRoot $pre) $h
      [void]$aitems.Add(@{ Url = ('https://resources.download.minecraft.net/' + $pre + '/' + $h); Dest = $dest; Sha1 = $h })
    }
    Write-Host ('下载游戏资源 (' + $aitems.Count + ')') -ForegroundColor DarkGray
    $f2 = Download-Pool $aitems (Get-DlThreads) '游戏资源'
    if ($f2.Count -gt 0) { Write-Host ('  有 ' + $f2.Count + ' 个资源下载失败') -ForegroundColor Yellow }

    # 旧版资源索引（virtual / map_to_resources）需要把 objects 展开成资源目录
    if ($idx.virtual -or $idx.map_to_resources) {
      $vRoot = if ($idx.map_to_resources) { Join-Path $script:McDir 'resources' } else { Join-Path (Join-Path (Join-Path $script:McDir 'assets') 'virtual') $res.assetIndex.id }
      $cnt = 0
      foreach ($p in $idx.objects.PSObject.Properties) {
        $h = [string]$p.Value.hash
        if (-not $h -or $h.Length -lt 2) { continue }
        $src = Join-Path (Join-Path $objRoot $h.Substring(0,2)) $h
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $vRoot ($p.Name -replace '/', $script:Sep)
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force -EA SilentlyContinue
        $cnt++
      }
      Write-Host ('  已生成旧版资源目录 (' + $cnt + ' 项)') -ForegroundColor DarkGray
    }
  }

  # 兼容：仅当用户已启用版本隔离（PCL.ini 或已有隔离结构）时才补齐隔离子目录
  if (Test-VersionIsolation) {
    $verDir = Join-Path (Join-Path $script:McDir 'versions') $id
    foreach ($sub in @('mods','saves','resourcepacks','shaderpacks','config')) {
      $d = Join-Path $verDir $sub
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
  }

  # 安装完整性验证
  if (-not (Test-Path -LiteralPath $clientJar)) {
    throw ('安装失败: 客户端主文件缺失 (' + $clientJar + ')')
  }
  if ($clientJar -and (Get-Item -LiteralPath $clientJar).Length -lt 100000) {
    Write-Host '  警告: 客户端主文件体积异常，可能下载不完整' -ForegroundColor Yellow
  }

  if ($select) {
    $cfg = Get-Config
    $cfg.SelectedVersion = $id
    # 安装后选中新版本时回到默认游戏目录，避免沿用上一个整合包实例的目录
    if ($cfg.GameDir) { $cfg.GameDir = ''; Write-Host '  已切回默认游戏目录（原独立目录已取消）' -ForegroundColor DarkGray }
    Save-Config $cfg
  }
  $failTotal = 0
  if ($f1) { $failTotal += $f1.Count }
  if ($f2) { $failTotal += $f2.Count }
  if ($failTotal -gt 0) {
    Write-Host ('版本 ' + $id + ' 安装完成，但有 ' + $failTotal + ' 个文件下载失败，可重新安装补齐') -ForegroundColor Yellow
  } else {
    Write-Host ('版本 ' + $id + ' 安装完成') -ForegroundColor Green
  }
}

function Find-Java {
  $cfg = Get-Config
  if ($cfg.JavaPath -and (Test-Path -LiteralPath $cfg.JavaPath)) { return $cfg.JavaPath }
  $javas = @()
  if (Test-Path -LiteralPath $script:JavaDir) {
    foreach ($d in Get-ChildItem -LiteralPath $script:JavaDir -Directory) {
      $exe = Join-Path (Join-Path $d.FullName 'bin') 'java.exe'
      if (Test-Path -LiteralPath $exe) { $javas += $exe }
    }
  }
  $sys = Get-Command java.exe -ErrorAction SilentlyContinue
  if ($sys) { $javas += $sys.Source }
  if ($javas.Count -eq 0) { return $null }
  return $javas[0]
}

# 按所需版本挑选 Java：在所有候选中选“刚好满足需求的最低版本”，都不满足时选最高版本
function Find-JavaFor($needMajor) {
  $cfg = Get-Config
  $candidates = New-Object System.Collections.ArrayList
  if ($cfg.JavaPath -and (Test-Path -LiteralPath $cfg.JavaPath)) { [void]$candidates.Add($cfg.JavaPath) }
  if (Test-Path -LiteralPath $script:JavaDir) {
    foreach ($d in (Get-ChildItem -LiteralPath $script:JavaDir -Directory | Sort-Object Name -Descending)) {
      $exe = Join-Path (Join-Path $d.FullName 'bin') 'java.exe'
      if (Test-Path -LiteralPath $exe) { [void]$candidates.Add($exe) }
    }
  }
  $sys = Get-Command java.exe -ErrorAction SilentlyContinue
  if ($sys) { [void]$candidates.Add($sys.Source) }
  $best = $null; $bestVer = -1
  $sat = $null; $satVer = [int]::MaxValue
  foreach ($c in $candidates) {
    $v = Get-JavaVersion $c
    if ($v -ge $needMajor) { if ($v -lt $satVer) { $satVer = $v; $sat = $c } }
    elseif ($v -gt $bestVer) { $bestVer = $v; $best = $c }
  }
  # 优先选“刚好够用”的最低版本，避免 1.17 版本被拉到 Java 21
  if ($sat) { return $sat }
  return $best
}

function Get-JavaVersion($exe) {
  try {
    $oldEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $o = ''
    try { $o = (& $exe -version 2>&1 | Out-String) } catch { $o = [string]$_.Exception.Message }
    $ErrorActionPreference = $oldEa
    if ($o -match 'version "([^"]+)"') {
      $v = $Matches[1]
      if ($v -match '^1[.]([0-9]+)') { return [int]$Matches[1] }
      if ($v -match '^([0-9]+)') { return [int]$Matches[1] }
    }
  } catch {}
  return 0
}

function Get-TunaJavaUrl($major) {
  $archDir = if ($script:Is64) { 'x64' } else { 'x86' }
  $dir = 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/' + $major + '/jdk/' + $archDir + '/windows/'
  try {
    $tmp = Join-Path $script:CacheDir ('tuna_' + $major + '.html')
    & curl.exe -s -f -L --ssl-no-revoke -m 30 -o $tmp $dir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return $null }
    $html = [IO.File]::ReadAllText($tmp)
    Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
    $m = [regex]::Matches($html, 'href="([^"]+?[.]zip)"')
    foreach ($x in $m) {
      $n = $x.Groups[1].Value
      if ($n -notmatch '[/\\]') { return ($dir + $n) }
    }
  } catch {}
  return $null
}

function Install-Java($major) {
  if (-not $major) { $major = 21 }
  Write-Host ('正在下载 Java ' + $major + ' ...') -ForegroundColor DarkGray
  $target = Join-Path $script:JavaDir ('jdk' + $major)
  $zip = Join-Path $script:CacheDir ('jdk' + $major + '.zip')
  Remove-Item -LiteralPath $zip -Force -EA SilentlyContinue

  $ok = $false
  $mirror = Get-TunaJavaUrl $major
  if ($mirror) {
    Write-Host ('  镜像: ' + $mirror) -ForegroundColor DarkGray
    try { Download-File $mirror $zip $null $true } catch {}
    if ((Test-Path -LiteralPath $zip) -and (Get-Item $zip).Length -gt 1MB) { $ok = $true }
  }
  if (-not $ok) {
    if ($mirror) { Write-Host '  镜像失败，改用官方源' -ForegroundColor Yellow }
    $adoptArch = if ($script:Is64) { 'x64' } else { 'x32' }
    $url = 'https://api.adoptium.net/v3/binary/latest/' + $major + '/ga/windows/' + $adoptArch + '/jdk/hotspot/normal/eclipse'
    try { Download-File $url $zip $null $true } catch {}
    if ((Test-Path -LiteralPath $zip) -and (Get-Item $zip).Length -gt 1MB) { $ok = $true }
  }
  if (-not $ok) { throw 'Java 下载失败（镜像与官方源均不可用）' }
  Write-Host '解压中...' -ForegroundColor DarkGray
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  $tmpDir = Join-Path $script:JavaDir ('_tmp_' + $major)
  if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  & tar.exe -xf $zip -C $tmpDir
  if ($LASTEXITCODE -ne 0) { throw 'Java 解压失败' }
  $inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1
  if ($inner) { Move-Item -LiteralPath $inner.FullName -Destination $target -Force }
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -EA SilentlyContinue
  Remove-Item -LiteralPath $zip -Force -EA SilentlyContinue
  $exe = Join-Path (Join-Path $target 'bin') 'java.exe'
  if (Test-Path -LiteralPath $exe) {
    # 不自动写 JavaPath：启动时按版本需求挑选，避免装过 JDK8 后所有版本都被钉在 8
    Write-Host ('Java ' + $major + ' 安装完成: ' + $exe) -ForegroundColor Green
  } else { throw 'Java 解压后未找到 java.exe' }
}

function Get-OfflineUuid($name) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('OfflinePlayer:' + $name))
  $b[6] = ($b[6] -band 0x0f) -bor 0x30
  $b[8] = ($b[8] -band 0x3f) -bor 0x80
  $hex = ($b | ForEach-Object { $_.ToString('x2') }) -join ''
  return ($hex.Substring(0,8) + '-' + $hex.Substring(8,4) + '-' + $hex.Substring(12,4) + '-' + $hex.Substring(16,4) + '-' + $hex.Substring(20,12))
}

function Ensure-DefaultLang($gameDir) {
  try {
    if (-not (Test-Path -LiteralPath $gameDir)) { New-Item -ItemType Directory -Force -Path $gameDir | Out-Null }
    $opt = Join-Path $gameDir 'options.txt'
    if (-not (Test-Path -LiteralPath $opt)) {
      [IO.File]::WriteAllText($opt, "lang:zh_cn" + [char]13 + [char]10, (New-Object Text.UTF8Encoding($false)))
      return
    }
    # 已有语言设置时保留用户选择，只在完全没有 lang 行时补默认值
    $raw = [IO.File]::ReadAllText($opt, [Text.Encoding]::UTF8)
    if ($raw -match '(?m)^lang:') { return }
    $prefix = ''
    if ($raw.Length -gt 0 -and -not $raw.EndsWith([string][char]10)) { $prefix = [string][char]13 + [string][char]10 }
    [IO.File]::AppendAllText($opt, $prefix + 'lang:zh_cn' + [char]13 + [char]10, (New-Object Text.UTF8Encoding($false)))
  } catch {}
}

function Expand-Vars($s, $vars) {
  foreach ($k in $vars.Keys) {
    $s = $s.Replace(('$' + '{' + $k + '}'), [string]$vars[$k])
  }
  return $s
}

# 游戏退出后诊断：区分正常退出与崩溃，并给出中文排查建议
function Show-CrashDiagnosis($exitCode, $gameDir) {
  $logPath = Join-Path (Join-Path $gameDir 'logs') 'latest.log'
  $isNormal = ($exitCode -eq 0 -or $exitCode -eq -1 -or $exitCode -eq 255)
  if ($isNormal) { return }

  Write-Host ''
  Write-Host '==========================================' -ForegroundColor Red
  Write-Host '  游戏异常退出（崩溃）' -ForegroundColor Red
  Write-Host '==========================================' -ForegroundColor Red
  Write-Host ('  退出码: ' + $exitCode)

  $tail = @()
  if (Test-Path -LiteralPath $logPath) {
    try { $tail = Get-Content -LiteralPath $logPath -Tail 200 } catch {}
  }
  $all = ''
  if ($tail.Count -gt 0) { $all = ($tail -join [Environment]::NewLine) }

  $hints = New-Object System.Collections.ArrayList
  if ($all -match 'UnsupportedClassVersionError|Unsupported major\.minor') {
    [void]$hints.Add('Java 版本过低：该版本需要更高版本 Java。请到“3. Java 管理”安装匹配版本（1.17+ 需 Java 17，1.20.5+ 需 Java 21）。')
  }
  if ($all -match 'OutOfMemoryError|GC overhead limit') {
    [void]$hints.Add('内存不足：到“7. 设置”调大内存 (MemoryMB)，或关闭占用内存的程序。')
  }
  if ($all -match 'NoClassDefFoundError|ClassNotFoundException') {
    [void]$hints.Add('依赖缺失：可能是 Mod 与游戏版本/加载器不匹配，或依赖库未下载完整。请核对 Mod 版本或重新安装该版本。')
  }
  if ($all -match 'UnsatisfiedLinkError|lwjgl|Failed to locate library') {
    [void]$hints.Add('本地库加载失败：通常是 32/64 位不匹配或显卡驱动过旧。请确认 Java 位数与系统一致，并更新显卡驱动。')
  }
  if ($all -match 'Pixel format not accelerated|OpenGL') {
    [void]$hints.Add('显卡/OpenGL 问题：请更新显卡驱动，或在笔记本上切换到独立显卡运行。')
  }
  if ($all -match 'Duplicate mods|already registered|Mixin apply failed|MixinTransformerError') {
    [void]$hints.Add('Mod 冲突：存在重复或不兼容的 Mod，请到“4. Mod 管理”禁用/删除可疑 Mod 后重试。')
  }
  if ($all -match 'Failed to download|Could not find|FileNotFoundException') {
    [void]$hints.Add('文件缺失/下载失败：请到“2. 版本管理”重新安装该版本以补齐文件。')
  }
  if ($all -match 'Exception in thread|Caused by:') {
    [void]$hints.Add('发生 Java 异常：详见下方日志片段与 logs 目录。')
  }
  if ($hints.Count -eq 0) {
    [void]$hints.Add('未知原因。请查看 logs/latest.log 与 crash-reports 目录，或尝试重新安装版本/更新 Java/禁用最近安装的 Mod。')
  }

  Write-Host ''
  Write-Host '  可能的原因与建议:' -ForegroundColor Yellow
  $n = 0
  foreach ($h in $hints) { $n++; Write-Host ('   ' + $n + '. ' + $h) -ForegroundColor Yellow }

  if ($all) {
    Write-Host ''
    Write-Host '  最近日志（关键行）:' -ForegroundColor DarkGray
    $key = $tail | Where-Object { $_ -match 'ERROR|Caused by|Exception|crash|Failed' } | Select-Object -Last 8
    if (-not $key) { $key = $tail | Select-Object -Last 8 }
    foreach ($ln in $key) { Write-Host ('    ' + $ln) -ForegroundColor DarkGray }
  }
  if (Test-Path -LiteralPath $logPath) {
    Write-Host ''
    Write-Host ('  完整日志: ' + $logPath) -ForegroundColor DarkGray
  }
  $crashDir = Join-Path $gameDir 'crash-reports'
  if (Test-Path -LiteralPath $crashDir) {
    Write-Host ('  崩溃报告目录: ' + $crashDir) -ForegroundColor DarkGray
  }
  Pause-Any
}

function Find-NativesDir($id, $baseId) {
  $verRoot = Join-Path $script:McDir 'versions'
  $idDir = Join-Path $verRoot $id
  $baseDir = Join-Path $verRoot $baseId
  $cands = @(
    (Join-Path $idDir ($id + '-natives')),
    (Join-Path $verRoot ($id + '-natives')),
    (Join-Path $idDir 'natives'),
    (Join-Path $baseDir ($baseId + '-natives')),
    (Join-Path $baseDir 'natives')
  )
  foreach ($c in $cands) {
    if (Test-Path -LiteralPath $c) {
      $any = Get-ChildItem -LiteralPath $c -File -EA SilentlyContinue | Select-Object -First 1
      if ($any) { return $c }
    }
  }
  return $null
}

function Test-LibPlatform($lib) {
  $name = [string]$lib.name
  if ($name -match ':(linux|macos|osx|natives-linux|natives-macos)' -and $name -notmatch 'natives-windows') { return $false }
  if ($name -match ':linux-') { return $false }
  if ($name -like 'ca.weblite:java-objc-bridge*') { return $false }
  return $true
}

function Start-Minecraft($id) {
  $cfg = Get-Config
  $res = Resolve-Version $id
  $verDir = Join-Path (Join-Path $script:McDir 'versions') $res.baseId
  $clientJar = Join-Path $verDir ($res.baseId + '.jar')
  if (-not (Test-Path -LiteralPath $clientJar)) {
    if ($script:DryRun) { throw ('客户端未安装: ' + $res.baseId) }
    Write-Host ('客户端 ' + $res.baseId + ' 尚未安装，是否现在下载? (Y/n)') -ForegroundColor Yellow
    $ans = Read-Host
    if ($ans -match '^[Nn]') { throw ('客户端未安装: ' + $res.baseId) }
    Install-Version $res.baseId $false
    if (-not (Test-Path -LiteralPath $clientJar)) { throw ('客户端安装后仍缺失: ' + $res.baseId) }
  }
  $nativesDir = Find-NativesDir $id $res.baseId
  if (-not $nativesDir) {
    if ($script:DryRun) {
      Write-Host '[dryrun] natives 缺失，跳过补齐' -ForegroundColor Yellow
      $nativesDir = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $res.baseId) 'natives'
    } else {
      Write-Host '检测到本地库(natives)缺失，正在补齐基础版本...' -ForegroundColor Yellow
      try { Install-Version $res.baseId $false } catch { Write-Host ('  补齐失败: ' + $_.Exception.Message) -ForegroundColor Red }
      $nativesDir = Find-NativesDir $id $res.baseId
      if (-not $nativesDir) { $nativesDir = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $res.baseId) 'natives' }
    }
    if (-not (Test-Path -LiteralPath $nativesDir)) { New-Item -ItemType Directory -Force -Path $nativesDir | Out-Null }
  }

  $needJava = 8
  if ($res.javaVersion -and $res.javaVersion.majorVersion) { $needJava = [int]$res.javaVersion.majorVersion }
  $java = Find-JavaFor $needJava
  $curVer = 0
  if ($java) { $curVer = Get-JavaVersion $java }
  if (-not $java -or $curVer -lt $needJava) {
    if ($script:DryRun) {
      Write-Host ('[dryrun] 需 Java ' + $needJava + '，当前 ' + $curVer + '（未安装，dryrun 跳过安装）') -ForegroundColor Yellow
      if (-not $java) { $java = 'java' }
    } else {
      Write-Host ('Java ' + $curVer + ' 低于所需 ' + $needJava + '，自动安装 Java ' + $needJava) -ForegroundColor Yellow
      Install-Java $needJava
      $java = Find-JavaFor $needJava
    }
  }
  if (-not $java) { throw 'Java 不可用' }

  $libRoot = Join-Path $script:McDir 'libraries'
  $cpParts = New-Object System.Collections.ArrayList
  # BootstrapLauncher（NeoForge/Forge 1.17+）自行管理 minecraft 模块，不能再把原版 jar 加入 classpath
  $isBootstrap = ($res.mainClass -eq 'cpw.mods.bootstraplauncher.BootstrapLauncher')
  if (-not $isBootstrap) { [void]$cpParts.Add($clientJar) }
  $missingItems = New-Object System.Collections.ArrayList
  $missingLibs = New-Object System.Collections.ArrayList
  foreach ($lib in $res.libraries) {
    if (-not (Test-Rules $lib.rules)) { continue }
    if ($lib.name -like '*natives-*') { continue }
    if ($lib.natives -and $lib.natives.windows) { continue }
    if (-not (Test-LibPlatform $lib)) { continue }
    $p = Get-LibPath $lib
    if ($p) {
      $full = Join-Path $libRoot ($p -replace '/', $script:Sep)
      if (Test-Path -LiteralPath $full) { [void]$cpParts.Add($full) }
      else {
        [void]$missingLibs.Add($lib.name)
        if ($lib.downloads -and $lib.downloads.artifact -and $lib.downloads.artifact.url) {
          [void]$missingItems.Add(@{ Url = $lib.downloads.artifact.url; Dest = $full; Sha1 = $lib.downloads.artifact.sha1 })
        }
      }
    }
  }
  if ($missingLibs.Count -gt 0) {
    Write-Host ('  检测到 ' + $missingLibs.Count + ' 个依赖库缺失') -ForegroundColor Yellow
    if ($missingItems.Count -gt 0 -and -not $script:DryRun) {
      Write-Host ('  正在补齐 ' + $missingItems.Count + ' 个依赖...') -ForegroundColor DarkGray
      [void](Download-Pool $missingItems (Get-DlThreads) '依赖补齐')
    }
    # 重建 classpath
    $cpParts = New-Object System.Collections.ArrayList
    if (-not $isBootstrap) { [void]$cpParts.Add($clientJar) }
    $stillMissing = 0
    foreach ($lib in $res.libraries) {
      if (-not (Test-Rules $lib.rules)) { continue }
      if ($lib.name -like '*natives-*') { continue }
      if ($lib.natives -and $lib.natives.windows) { continue }
      if (-not (Test-LibPlatform $lib)) { continue }
      $p = Get-LibPath $lib
      if ($p) { $full = Join-Path $libRoot ($p -replace '/', $script:Sep); if (Test-Path -LiteralPath $full) { [void]$cpParts.Add($full) } else { $stillMissing++ } }
    }
    if ($stillMissing -gt 0) { Write-Host ('  仍有 ' + $stillMissing + ' 个依赖无法补齐，游戏可能无法启动') -ForegroundColor Yellow }
  }
  $classpath = ($cpParts -join $script:CP)

  $assetsRoot = Join-Path $script:McDir 'assets'
  $assetIndex = if ($res.assetIndex) { $res.assetIndex.id } else { $res.assets }

  # 官方 log4j 配置（版本 JSON 的 logging 字段）
  $logCfgArg = $null
  if ($res.logging -and $res.logging.client -and $res.logging.client.file -and $res.logging.client.argument) {
    $lf = $res.logging.client.file
    $logCfgPath = Join-Path (Join-Path (Join-Path $script:McDir 'assets') 'log_configs') $lf.id
    if (-not (Test-Path -LiteralPath $logCfgPath) -and -not $script:DryRun) {
      try { Download-File $lf.url $logCfgPath $lf.sha1 } catch {}
    }
    if (Test-Path -LiteralPath $logCfgPath) { $logCfgArg = ([string]$res.logging.client.argument).Replace('${path}', $logCfgPath) }
  }

  $name = $cfg.PlayerName
  if (-not $name) { $name = 'Player' }
  $uuid = Get-OfflineUuid $name
  $token = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
  $gameDir = Get-VersionDir $id
  if (-not (Test-Path -LiteralPath $gameDir)) { New-Item -ItemType Directory -Force -Path $gameDir | Out-Null }
  Ensure-DefaultLang $gameDir
  $mem = 2048; if ($cfg.MemoryMB) { $mem = [int]$cfg.MemoryMB }
  $w = 854; if ($cfg.WindowWidth) { $w = [int]$cfg.WindowWidth }
  $h = 480; if ($cfg.WindowHeight) { $h = [int]$cfg.WindowHeight }

  $vars = @{
    classpath = $classpath
    natives_directory = $nativesDir
    launcher_name = 'ccl'
    launcher_version = '1.0.3-beta'
    auth_player_name = $name
    version_name = $id
    game_directory = $gameDir
    assets_root = $assetsRoot
    assets_index_name = $assetIndex
    auth_uuid = $uuid
    auth_access_token = $token
    clientid = '0'
    auth_xuid = '0'
    user_type = 'legacy'
    auth_session = ('token:' + $token + ':' + $uuid)
    version_type = $res.type
    user_properties = '{}'
    game_assets = (Join-Path (Join-Path $assetsRoot 'virtual') $(if ($assetIndex) { $assetIndex } else { 'legacy' }))
    library_directory = $libRoot
    classpath_separator = $script:CP
    resolution_width = [string]$w
    resolution_height = [string]$h
  }

  $features = @{ has_custom_resolution = $true }

  $argsList = New-Object System.Collections.ArrayList
  [void]$argsList.Add(('-Xmx' + $mem + 'M'))
  [void]$argsList.Add(('-Xms' + $mem + 'M'))
  $jvm = Resolve-Args $res.jvmArgs $features
  if ($jvm.Count -eq 0) {
    [void]$argsList.Add('-Djava.library.path=' + $nativesDir)
    [void]$argsList.Add('-cp')
    [void]$argsList.Add($classpath)
  } else {
    foreach ($a in $jvm) { [void]$argsList.Add((Expand-Vars $a $vars)) }
  }
  if ($cfg.JvmArgs) {
    foreach ($x in ($cfg.JvmArgs -split '\s+')) { if ($x) { [void]$argsList.Add($x) } }
  }

  if ($logCfgArg -and -not ($argsList -match 'log4j\.configurationFile')) { [void]$argsList.Add($logCfgArg) }

  [void]$argsList.Add($res.mainClass)

  if ($res.legacyArgs) {
    $parts = $res.legacyArgs -split ' '
    foreach ($p in $parts) { [void]$argsList.Add((Expand-Vars $p $vars)) }
  } else {
    $g = Resolve-Args $res.gameArgs $features
    foreach ($a in $g) { [void]$argsList.Add((Expand-Vars $a $vars)) }
  }

  if ($cfg.Fullscreen) { [void]$argsList.Add('--fullscreen') }
  if ($cfg.DemoMode) { [void]$argsList.Add('--demo') }
  if ($cfg.ExtraGameArgs) {
    foreach ($x in ($cfg.ExtraGameArgs -split '\s+')) { if ($x) { [void]$argsList.Add($x) } }
  }

  $finalArgs = @()
  foreach ($a in $argsList) {
    if ($a -eq $null) { continue }
    $a = [string]$a
    if ($a.Length -eq 0) { continue }
    $finalArgs += $a
  }
  $javaArgs = $finalArgs

  if ($script:DryRun) {
    Write-Host ('java=' + $java)
    Write-Host ('argc=' + $javaArgs.Count)
    foreach ($x in $javaArgs) { Write-Host ('  [' + $x + ']') }
    return
  }

  $dbgMode = [bool]$cfg.DebugMode
  $launchLog = $null

  if ($dbgMode) {
    # ---------- 调试模式：打印启动详情 ----------
    Write-Host ''
    Write-Host '════════ 调试模式 ════════' -ForegroundColor Magenta
    Write-Host ('  Java      : ' + $java) -ForegroundColor Cyan
    Write-Host ('  版本      : ' + $id)
    Write-Host ('  加载器    : ' + $cfg.SelectedLoader + ' ' + $cfg.SelectedLoaderVersion)
    Write-Host ('  玩家      : ' + $name)
    Write-Host ('  工作目录  : ' + $gameDir)
    Write-Host ('  内存      : ' + $mem + ' MB')
    Write-Host ('  窗口      : ' + $w + ' x ' + $h)
    if ($cfg.JvmArgs) { Write-Host ('  额外 JVM  : ' + $cfg.JvmArgs) }
    if ($cfg.ExtraGameArgs) { Write-Host ('  额外游戏  : ' + $cfg.ExtraGameArgs) }
    Write-Host ('  参数总数  : ' + $javaArgs.Count) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  --- 完整启动参数 ---' -ForegroundColor DarkGray
    $cpMarker = $false
    for ($ai = 0; $ai -lt $javaArgs.Count; $ai++) {
      $a = [string]$javaArgs[$ai]
      if ($cpMarker) {
        # 这一项是 classpath，逐条拆分显示
        $cpMarker = $false
        $entries = $a -split [regex]::Escape($script:CP)
        Write-Host ('    [classpath] ' + $entries.Count + ' 项:') -ForegroundColor DarkGray
        foreach ($e in $entries) { Write-Host ('      ' + $e) -ForegroundColor DarkGray }
        continue
      }
      if ($a -eq '-cp' -or $a -eq '-classpath') { $cpMarker = $true; Write-Host ('    [' + $a + ']'); continue }
      $disp = $a
      if ($disp.Length -gt 180) { $disp = $disp.Substring(0, 150) + ' ... (' + $disp.Length + ' 字符)' }
      Write-Host ('    [' + $disp + ']')
    }
    Write-Host '════════ 游戏输出 ════════' -ForegroundColor Magenta
    Write-Host ''

    # 准备日志文件
    $logDir = Join-Path $script:CclDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $launchLog = Join-Path $logDir ('launch_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    try {
      $hdr = 'CCL launcher debug log' + [char]13 + [char]10
      $hdr += 'time   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + [char]13 + [char]10
      $hdr += 'java   : ' + $java + [char]13 + [char]10
      $hdr += 'game   : ' + $id + [char]13 + [char]10
      $hdr += 'workdir: ' + $gameDir + [char]13 + [char]10
      $hdr += ('-' * 60) + [char]13 + [char]10
      [IO.File]::WriteAllText($launchLog, $hdr, (New-Object Text.UTF8Encoding($false)))
      Write-Host ('  本次输出同时写入: ' + $launchLog) -ForegroundColor DarkGray
      Write-Host ''
    } catch { $launchLog = $null }
  } else {
    Write-Host ''
    Write-Host ('启动: ' + $java) -ForegroundColor Cyan
    Write-Host ('版本: ' + $id + '  玩家: ' + $name) -ForegroundColor Cyan
    Write-Host ''
  }

  if ($env:CCL_DEBUG) {
    $dbg = $java + ' ' + (($javaArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    [IO.File]::WriteAllText((Join-Path $script:CclDir 'cmd.txt'), $dbg, [Text.Encoding]::UTF8)
  }

  $exitCode = 0
  $origDir = (Get-Location).Path
  try {
    if (Test-Path -LiteralPath $gameDir) { Set-Location -LiteralPath $gameDir }
    if ($dbgMode -and $launchLog) {
      # 实时显示 + 追加到日志（用 StreamWriter 保证与头部同为 UTF-8）
      $sw = New-Object IO.StreamWriter($launchLog, $true, (New-Object Text.UTF8Encoding($false)))
      $sw.AutoFlush = $true
      try {
        & $java @javaArgs 2>&1 | ForEach-Object {
          Write-Output $_
          try { $sw.WriteLine([string]$_) } catch {}
        }
        $exitCode = $LASTEXITCODE
      } finally {
        try { $sw.Close() } catch {}
      }
    } else {
      & $java @javaArgs
      $exitCode = $LASTEXITCODE
    }
  } finally {
    Set-Location -LiteralPath $origDir
  }

  if ($dbgMode) {
    Write-Host ''
    Write-Host '════════ 游戏已退出 ════════' -ForegroundColor Magenta
    Write-Host ('  退出码: ' + $exitCode)
    if ($launchLog) { Write-Host ('  完整日志: ' + $launchLog) }
    $gameLatest = Join-Path (Join-Path $gameDir 'logs') 'latest.log'
    if (Test-Path -LiteralPath $gameLatest) { Write-Host ('  游戏日志: ' + $gameLatest) }
  }

  Show-CrashDiagnosis $exitCode $gameDir
}

function Get-VersionSortKey($id) {
  # 语义版本键：major*1e8 + minor*1e4 + patch，降序排列即大版本-小版本
  if ($id -match '^(\d+)\.(\d+)(?:\.(\d+))?') {
    $maj = [long]$Matches[1]; $min = [long]$Matches[2]; $pat = [long]0
    if ($Matches[3]) { $pat = [long]$Matches[3] }
    return ($maj * 100000000 + $min * 10000 + $pat)
  }
  return [long]-1
}

function Sort-Versions($versions) {
  # 正式版在前（按语义版本降序）；快照/预发布在后（保持 API 原始时间顺序）
  $keyed = @()
  $idx = 0
  foreach ($v in @($versions)) {
    $keyed += [PSCustomObject]@{ V = $v; Key = (Get-VersionSortKey $v.id); Rel = ($v.type -eq 'release'); Idx = $idx }
    $idx++
  }
  $rel = @($keyed | Where-Object { $_.Rel } | Sort-Object -Property @{Expression='Key';Descending=$true})
  $non = @($keyed | Where-Object { -not $_.Rel } | Sort-Object -Property Idx)
  return @(($rel + $non) | ForEach-Object { $_.V })
}

function Invoke-SelfTest($a) {
  $cmd = $a[0]
  switch ($cmd) {
    'manifest' {
      $m = Get-VersionManifest
      Write-Host ('latest=' + $m.latest.release + ' count=' + $m.versions.Count)
    }
    'list' {
      $m = Get-VersionManifest
      Sort-Versions $m.versions | Select-Object -First 12 | ForEach-Object { Write-Host ($_.id + ' ' + $_.type) }
    }
    'listrel' {
      $m = Get-VersionManifest
      $rel = @(Sort-Versions $m.versions | Where-Object { $_.type -eq 'release' })
      $rel | Select-Object -First 15 | ForEach-Object { Write-Host $_.id }
    }
    'install' { Install-Version $a[1] }
    'launch' { Start-Minecraft $a[1] }
    'dryrun' { $script:DryRun = $true; Start-Minecraft $a[1] }
    'mirrorurls' {
      $u0 = ($a[1] -replace '["'']','').Trim()
      foreach ($u in (Get-UrlWithMirror $u0)) { Write-Host $u }
    }
    'dlmirror' {
      $dest = Join-Path $script:CacheDir 'mirrortest.jar'
      $r = @{ Url = $a[1]; Dest = $dest; Sha1 = $null }
      [void](Download-Pool @($r) 2 'mirrortest')
      if (Test-Path -LiteralPath $dest) { Write-Host ('size=' + (Get-Item $dest).Length); Remove-Item $dest -Force }
      else { Write-Host 'FAILED' }
    }
    'java' { Install-Java ([int]$a[1]) }
    'tunajava' { $u = Get-TunaJavaUrl $a[1]; if ($u) { Write-Host ('url=' + $u) } else { Write-Host 'url=(null)' } }
    'dumpjvm' {
      $res = Resolve-Version $a[1]
      $vars = @{ classpath='CP'; natives_directory='NATDIR'; launcher_name='ccl'; launcher_version='1.0'; auth_player_name='P'; version_name=$a[1]; game_directory='GD'; assets_root='AR'; assets_index_name='AI'; auth_uuid='U'; auth_access_token='0'; clientid='0'; auth_xuid='0'; user_type='legacy'; version_type='release'; user_properties='{}'; game_assets='GA'; library_directory='LD'; classpath_separator=';'; resolution_width='854'; resolution_height='480'; launcher_bootstrap_file='LB' }
      $jvm = Resolve-Args $res.jvmArgs
      Write-Host ('jvmCount=' + $jvm.Count)
      foreach ($x in $jvm) { Write-Host ('  [' + (Expand-Vars $x $vars) + ']') }
    }
    'findjava' {
      $j = Find-Java
      Write-Host ('java=' + $j)
      if ($j) { Write-Host ('ver=' + (Get-JavaVersion $j)) }
    }
    'uuid' { Write-Host (Get-OfflineUuid $a[1]) }
    'importpack' {
      $script:NonInteractive = $true
      $pp = ($a[1..($a.Count - 1)] -join ' ')
      if ($pp) { $pp = $pp.Trim('"').Trim("'").Trim() }
      Import-Mrpack $pp
    }
    'isolation' {
      $ini = Join-Path $script:McDir 'PCL.ini'
      Write-Host ('mcDir=' + $script:McDir)
      Write-Host ('iniExists=' + (Test-Path -LiteralPath $ini))
      if (Test-Path -LiteralPath $ini) {
        $raw = [IO.File]::ReadAllText($ini, [Text.Encoding]::UTF8)
        Write-Host ('rawLen=' + $raw.Length)
        foreach ($ln in [IO.File]::ReadAllLines($ini, [Text.Encoding]::UTF8)) {
          Write-Host ('LINE=[' + $ln + ']')
          if ($ln -match 'VersionArgumentIndie\s*=\s*(\d+)') { Write-Host ('M=' + $Matches[1]) }
        }
      }
      $pcl = Get-PclIsolation
      $iso = Test-VersionIsolation
      Write-Host ('pcl=' + $pcl + ' effective=' + $iso)
      Write-Host ('verDir=' + (Get-VersionDir $a[1]))
      Write-Host ('modDir=' + (Get-ModDir $a[1]))
    }
    'moddl' {
      $cfg = Get-Config
      if ($a[2]) { $cfg.SelectedVersion = $a[2] }
      if ($a[3]) { $cfg.SelectedLoader = $a[3] }
      Install-ModFromProject $a[1] $cfg
    }
    'modls' {
      $md = Get-ModDir
      Write-Host ('modDir=' + $md)
      if (Test-Path -LiteralPath $md) {
        Get-ChildItem -LiteralPath $md -File | ForEach-Object { Write-Host ('  ' + $_.Name + ' (' + $_.Length + ')') }
      } else { Write-Host '  (not exist)' }
    }
    'forgeinstall' { $script:NonInteractive = $true; Install-Forge }
    'fabricinstall' { $script:NonInteractive = $true; Install-Fabric }
    'neoforgeinstall' { $script:NonInteractive = $true; Install-NeoForge }
    'resolve' {
      $r = Resolve-Version $a[1]
      Write-Host ('base=' + $r.baseId + ' main=' + $r.mainClass + ' libs=' + $r.libraries.Count)
      Write-Host ('jvm=' + (Resolve-Args $r.jvmArgs).Count + ' game=' + (Resolve-Args $r.gameArgs).Count)
      Write-Host ('java=' + $r.javaVersion.majorVersion + ' asset=' + $r.assetIndex.id)
    }
    default { Write-Host ('未知测试命令: ' + $cmd) }
  }
}

function Get-LoaderName($cfg) {
  if ($cfg.SelectedLoader -and $cfg.SelectedLoader -ne 'vanilla') { return $cfg.SelectedLoader }
  return 'fabric'
}

# 判断字符串是否本身就是 MC 版本号（如 1.20.1）
function Test-McVersionId($s) {
  return ($s -match '^1\.\d+(\.\d+)?$')
}

# NeoForge 版本号 ↔ MC 版本：21.1.x -> 1.21.1，21.0.x -> 1.21，47.1.x -> 1.20.1
function ConvertFrom-NeoForgeVer($neoVer) {
  if ($neoVer -match '^(\d+)\.(\d+)\.') {
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    if ($a -ge 47) { if ($a -eq 47 -and $b -eq 1) { return '1.20.1' }; return $null }
    if ($b -eq 0) { return ('1.' + $a) }
    return ('1.' + $a + '.' + $b)
  }
  return $null
}

# MC 版本 -> NeoForge 版本前缀（用于筛选可用版本）
function Get-NeoForgePrefix($mc) {
  if ($mc -match '^1\.(\d+)\.(\d+)$') {
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    if ($a -eq 20 -and $b -eq 1) { return '47.1.' }
    return ($a.ToString() + '.' + $b + '.')
  }
  if ($mc -match '^1\.(\d+)$') { return ([int]$Matches[1]).ToString() + '.0.' }
  return $null
}

# 取得真实的 Minecraft 版本号（去掉加载器前缀），必要时读版本 json 的 inheritsFrom
function Get-McVersion($cfg) {
  $id = $cfg.SelectedVersion
  if (-not $id) { return $null }
  if (Test-McVersionId $id) { return $id }

  # fabric-loader-<loader>-<mc>
  if ($id -match '^fabric-loader-(.+)-((\d+)\.(\d+)(?:\.(\d+))?)$') { return $Matches[2] }
  # <mc>-forge-<ver>
  if ($id -match '^((\d+)\.(\d+)(?:\.(\d+))?)-forge-(.+)$') { return $Matches[1] }
  # neoforge-<ver>
  if ($id -match '^neoforge-(.+)$') {
    $nv = $Matches[1]
    $guess = ConvertFrom-NeoForgeVer $nv
    # 优先读本地版本 json 的 inheritsFrom（最准）
    try {
      $jp = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $id) ($id + '.json')
      if (Test-Path -LiteralPath $jp) {
        $j = Get-Content -LiteralPath $jp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.inheritsFrom -and (Test-McVersionId $j.inheritsFrom)) { return $j.inheritsFrom }
      }
    } catch {}
    return $guess
  }

  # 其他带 inheritsFrom 的自定义版本
  try {
    $jp = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $id) ($id + '.json')
    if (Test-Path -LiteralPath $jp) {
      $j = Get-Content -LiteralPath $jp -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.inheritsFrom -and (Test-McVersionId $j.inheritsFrom)) { return $j.inheritsFrom }
    }
  } catch {}
  return $null
}

# 该 MC 版本需要的 Java 主版本：优先读本地版本 JSON，否则按版本号推断
function Get-JavaMajorForMc($mc) {
  if (-not $mc) { return 17 }
  $jp = Join-Path (Join-Path (Join-Path $script:McDir 'versions') $mc) ($mc + '.json')
  if (Test-Path -LiteralPath $jp) {
    try {
      $j = Get-Content -LiteralPath $jp -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.javaVersion -and $j.javaVersion.majorVersion) { return [int]$j.javaVersion.majorVersion }
    } catch {}
  }
  if ($mc -match '^1\.(\d+)(?:\.(\d+))?') {
    $min = [int]$Matches[1]; $pat = 0
    if ($Matches[2]) { $pat = [int]$Matches[2] }
    if ($min -gt 20 -or ($min -eq 20 -and $pat -ge 5)) { return 21 }
    if ($min -ge 17) { return 17 }
    return 8
  }
  return 8
}

function Test-HasChinese($s) {
  return ($s -match '[一-鿿]')
}

function Search-Modrinth($q, $mcVer, $loader, $limit = 20) {
  $url = 'https://api.modrinth.com/v2/search?query=' + [uri]::EscapeDataString($q) + '&limit=' + $limit
  $url += '&facets=' + [uri]::EscapeDataString(('[["versions:' + $mcVer + '"],["categories:' + $loader + '"]]'))
  # 同一查询缓存 10 分钟；缓存名用查询哈希，避免每次搜索都生成新的随机缓存文件
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $key = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))).Replace('-','').ToLower()
  return (Get-Json $url ('mod_search_' + $key + '.json') 10)
}

function Install-ModFromProject($slug, $cfg) {
  if (-not $cfg.SelectedLoader -or $cfg.SelectedLoader -eq 'vanilla') {
    Write-Host '  原版无法安装 Mod，请先安装加载器并切换到对应版本。' -ForegroundColor Yellow
    return
  }
  $loader = Get-LoaderName $cfg
  $mcVer = Get-McVersion $cfg
  if (-not $mcVer) { Write-Host ('  无法确定 Minecraft 版本（当前: ' + $cfg.SelectedVersion + '）') -ForegroundColor Red; return }
  Write-Host ('  目标: MC ' + $mcVer + ' / 加载器 ' + $loader) -ForegroundColor DarkGray
  $url = 'https://api.modrinth.com/v2/project/' + $slug + '/version?game_versions=' + [uri]::EscapeDataString('["' + $mcVer + '"]') + '&loaders=' + [uri]::EscapeDataString('["' + $loader + '"]')
  $vers = $null
  try { $vers = Get-Json $url $null 0 } catch { Write-Host ('  获取版本失败: ' + $_.Exception.Message) -ForegroundColor Red; return }
  if (-not $vers -or $vers.Count -eq 0) { Write-Host ('  没有匹配 MC ' + $mcVer + ' + ' + $loader + ' 的文件') -ForegroundColor Yellow; return }
  $v = $vers[0]
  # 二次校验：返回文件的 loaders 必须包含当前加载器
  $ok = $false
  foreach ($ld in @($v.loaders)) { if ($ld -eq $loader) { $ok = $true; break } }
  if (-not $ok) {
    Write-Host ('  该文件不适用于 ' + $loader + '（可用: ' + ($v.loaders -join '/') + '）') -ForegroundColor Red
    return
  }
  $file = $null
  foreach ($f in $v.files) { if ($f.primary) { $file = $f; break } }
  if (-not $file) { $file = $v.files[0] }
  $modDir = Get-ModDir
  if (-not (Test-Path -LiteralPath $modDir)) { New-Item -ItemType Directory -Force -Path $modDir | Out-Null }
  # 只取文件名，防止接口返回带路径的文件名
  $fname = [IO.Path]::GetFileName([string]$file.filename)
  if (-not $fname) { $fname = ([string]$slug + '.jar') }
  $sha512 = $null
  if ($file.hashes -and $file.hashes.sha512) { $sha512 = [string]$file.hashes.sha512 }
  $dest = Join-Path $modDir $fname
  Write-Host ('  下载 ' + $fname + ' ...') -ForegroundColor DarkGray
  try { Download-File $file.url $dest $null $true $sha512; Write-Host '  安装完成' -ForegroundColor Green } catch { Write-Host ('  下载失败: ' + $_.Exception.Message) -ForegroundColor Red }
}

function Install-Fabric {
  $cfg = Get-Config
  if (-not $cfg.SelectedVersion) { Write-Host '  请先选择一个 Minecraft 版本' -ForegroundColor Yellow; Pause-Any; return }
  $mc = Get-McVersion $cfg
  if (-not $mc) { $mc = $cfg.SelectedVersion }
  if (-not (Test-McVersionId $mc)) {
    Write-Host ('  无法从当前版本推断 Minecraft 版本（' + $cfg.SelectedVersion + '），请先切换到原版版本') -ForegroundColor Red
    Pause-Any; return
  }
  Write-Host ('  为 ' + $mc + ' 安装 Fabric...') -ForegroundColor Cyan
  $loaderMeta = $null
  try { $loaderMeta = Get-Json ('https://meta.fabricmc.net/v2/versions/loader/' + $mc) ('fabric_loaders_' + $mc + '.json') 30 } catch {
    try { $loaderMeta = Get-Json 'https://meta.fabricmc.net/v2/versions/loader' 'fabric_loaders.json' 30 } catch { Write-Host ('  获取加载器版本失败: ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any; return }
  }
  if (-not $loaderMeta -or $loaderMeta.Count -eq 0) { Write-Host ('  ' + $mc + ' 没有可用的 Fabric 加载器') -ForegroundColor Yellow; Pause-Any; return }
  $loaderVer = $loaderMeta[0].loader.version
  if ($loaderMeta.Count -gt 1 -and -not $script:NonInteractive) {
    Write-Host '  可用加载器版本:'
    $show = [Math]::Min(5, $loaderMeta.Count)
    for ($i = 0; $i -lt $show; $i++) { Write-Host ('    ' + ($i+1) + '. ' + $loaderMeta[$i].loader.version + $(if ($loaderMeta[$i].loader.stable) { ' (稳定)' } else { '' })) }
    $pick = Read-Host ('  选择版本序号 (回车默认 ' + $loaderVer + ')')
    if ($pick -match '^[0-9]+$') { $n = [int]$pick - 1; if ($n -ge 0 -and $n -lt $show) { $loaderVer = $loaderMeta[$n].loader.version } }
  }
  $instMeta = $null
  try { $instMeta = Get-Json 'https://meta.fabricmc.net/v2/versions/installer' 'fabric_installer.json' 30 } catch { Write-Host ('  获取安装器失败: ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any; return }
  $instVer = $instMeta[0].version
  $jarUrl = $instMeta[0].url
  if (-not $jarUrl) { $jarUrl = 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/' + $instVer + '/fabric-installer-' + $instVer + '.jar' }
  $jar = Join-Path $script:CacheDir 'fabric-installer.jar'
  Write-Host ('  下载安装器 ' + $instVer + ' ...') -ForegroundColor DarkGray
  try { Download-File $jarUrl $jar $null $true } catch { Write-Host ('  下载失败: ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any; return }
  $needJ = Get-JavaMajorForMc $mc
  $java = Find-JavaFor $needJ
  if (-not $java) { Write-Host ('  未找到 Java ' + $needJ + '，先安装') -ForegroundColor Yellow; Install-Java $needJ; $java = Find-JavaFor $needJ }
  if (-not $java) { Write-Host '  Java 不可用' -ForegroundColor Red; Pause-Any; return }
  Write-Host '  正在安装 Fabric (可能需要一点时间)...' -ForegroundColor DarkGray
  Push-Location $script:McDir
  try { & $java -jar $jar client -dir $script:McDir -mcversion $mc -loader $loaderVer -noprofile } finally { Pop-Location }
  if ($LASTEXITCODE -eq 0) {
    $fid = 'fabric-loader-' + $loaderVer + '-' + $mc
    $cfg.SelectedVersion = $fid; $cfg.SelectedLoader = 'fabric'; $cfg.SelectedLoaderVersion = $loaderVer
    Save-Config $cfg
    Write-Host ('  Fabric 安装完成: ' + $fid) -ForegroundColor Green
    Write-Host '  已自动切换当前版本到该 Fabric 版本' -ForegroundColor Green
  } else { Write-Host ('  安装失败, 退出码 ' + $LASTEXITCODE) -ForegroundColor Red }
  Pause-Any
}

function Install-Forge {
  $cfg = Get-Config
  if (-not $cfg.SelectedVersion) { Write-Host '  请先选择一个 Minecraft 版本' -ForegroundColor Yellow; Pause-Any; return }
  $mc = Get-McVersion $cfg
  if (-not $mc) { $mc = $cfg.SelectedVersion }
  if (-not (Test-McVersionId $mc)) {
    Write-Host ('  无法从当前版本推断 Minecraft 版本（' + $cfg.SelectedVersion + '），请先切换到原版版本') -ForegroundColor Red
    Pause-Any; return
  }
  Write-Host ('  为 ' + $mc + ' 安装 Forge...') -ForegroundColor Cyan
  $promos = $null
  try { $promos = Get-Json 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json' 'forge_promos.json' 30 } catch { Write-Host ('  获取 Forge 版本失败: ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any; return }
  $fv = $null
  $p1 = $promos.promos.PSObject.Properties[$mc + '-recommended']
  if ($p1) { $fv = $p1.Value }
  if (-not $fv) { $p2 = $promos.promos.PSObject.Properties[$mc + '-latest']; if ($p2) { $fv = $p2.Value } }
  if (-not $fv) { Write-Host ('  ' + $mc + ' 没有可用的 Forge 版本') -ForegroundColor Yellow; Pause-Any; return }
  Write-Host ('  Forge 版本: ' + $fv) -ForegroundColor DarkGray
  $full = $mc + '-' + $fv
  $urls = @(
    ('https://maven.minecraftforge.net/net/minecraftforge/forge/' + $full + '/forge-' + $full + '-installer.jar'),
    ('https://files.minecraftforge.net/maven/net/minecraftforge/forge/' + $full + '/forge-' + $full + '-installer.jar')
  )
  $jar = Join-Path $script:CacheDir 'forge-installer.jar'
  $ok = $false
  foreach ($u in $urls) {
    Write-Host ('  下载安装器: ' + $u) -ForegroundColor DarkGray
    try { Download-File $u $jar $null $true; $ok = $true; break } catch { Write-Host '  失败，尝试备用地址' -ForegroundColor Yellow }
  }
  if (-not $ok) { Write-Host '  下载 Forge 安装器失败' -ForegroundColor Red; Pause-Any; return }
  $needJ = Get-JavaMajorForMc $mc
  $java = Find-JavaFor $needJ
  if (-not $java) { Write-Host ('  未找到 Java ' + $needJ + '，先安装') -ForegroundColor Yellow; Install-Java $needJ; $java = Find-JavaFor $needJ }
  if (-not $java) { Write-Host '  Java 不可用' -ForegroundColor Red; Pause-Any; return }
  Write-Host '  正在安装 Forge (可能需要几分钟)...' -ForegroundColor DarkGray
  & $java -jar $jar --installClient $script:McDir
  if ($LASTEXITCODE -eq 0) {
    $fid = $mc + '-forge-' + $fv
    $cfg.SelectedVersion = $fid; $cfg.SelectedLoader = 'forge'; $cfg.SelectedLoaderVersion = $fv
    Save-Config $cfg
    Write-Host ('  Forge 安装完成: ' + $fid) -ForegroundColor Green
    Write-Host '  已自动切换当前版本到该 Forge 版本' -ForegroundColor Green
  } else { Write-Host ('  安装失败, 退出码 ' + $LASTEXITCODE) -ForegroundColor Red }
  Pause-Any
}

function Prefetch-NeoForgeLibs($installerJar) {
  if (-not (Test-Path -LiteralPath $installerJar)) { return }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead($installerJar)
  try {
    $e = $z.Entries | Where-Object { $_.FullName -eq 'install_profile.json' } | Select-Object -First 1
    if (-not $e) { return }
    $sr = New-Object IO.StreamReader($e.Open())
    $txt = $sr.ReadToEnd(); $sr.Close()
    $j = $txt | ConvertFrom-Json
  } finally { $z.Dispose() }
  $libRoot = Join-Path $script:McDir 'libraries'
  $items = New-Object System.Collections.ArrayList
  $host_maven = 'https://bmclapi2.bangbang93.com/maven/'
  foreach ($lib in @($j.libraries)) {
    if (-not $lib.name) { continue }
    # 优先使用官方给出的 artifact 路径（可正确处理 @zip 等扩展名）
    $rel = $null
    if ($lib.downloads -and $lib.downloads.artifact -and $lib.downloads.artifact.path) {
      $rel = $lib.downloads.artifact.path
    } else {
      $namePart = $lib.name
      $ext = 'jar'
      $at = $namePart.IndexOf('@')
      if ($at -ge 0) { $ext = $namePart.Substring($at + 1); $namePart = $namePart.Substring(0, $at) }
      $p = $namePart -split ':'
      if ($p.Count -lt 3) { continue }
      $g = $p[0] -replace '[.]', '/'; $a = $p[1]; $v = $p[2]
      $cls = if ($p.Count -ge 4) { '-' + $p[3] } else { '' }
      $rel = $g + '/' + $a + '/' + $v + '/' + $a + '-' + $v + $cls + '.' + $ext
    }
    $dest = Join-Path $libRoot ($rel -replace '/', $script:Sep)
    if (Test-Path -LiteralPath $dest) { continue }
    # 仅预取来自 neoforged/cpw/forge maven 的库；Mojang 库走原有逻辑
    $useMirror = $false
    if ($lib.downloads -and $lib.downloads.artifact -and $lib.downloads.artifact.url) {
      $u = $lib.downloads.artifact.url
      if ($u -match 'maven\.(neoforged|minecraftforge)\.net' -or $u -match 'files\.minecraftforge\.net') { $useMirror = $true }
    } else { $useMirror = $true }
    if (-not $useMirror) { continue }
    [void]$items.Add(@{ Url = ($host_maven + $rel); Dest = $dest; Sha1 = $null })
  }
  if ($items.Count -gt 0) {
    Write-Host ('  预置 NeoForge 依赖 (' + $items.Count + '，经镜像) ...') -ForegroundColor DarkGray
    [void](Download-Pool $items (Get-DlThreads) 'NeoForge依赖')
  }
}

function Install-NeoForge {
  $cfg = Get-Config
  if (-not $cfg.SelectedVersion) { Write-Host '  请先选择一个 Minecraft 版本' -ForegroundColor Yellow; Pause-Any; return }
  $ver = $cfg.SelectedVersion
  # 从版本 id 或已装版本 JSON 推断 MC 版本（含 neoforge-* / fabric-* / *-forge-*）
  $mc = Get-McVersion $cfg
  if (-not $mc) { $mc = $ver }
  $neoVer = ''
  if ($ver -match '^neoforge-(.+)$') { $neoVer = $Matches[1] }
  if (-not $mc -or $mc -notmatch '^\d+\.\d+(\.\d+)?$') {
    if ($script:NonInteractive) { Write-Host ('  无法从版本 id 推断 MC 版本: ' + $ver) -ForegroundColor Red; Pause-Any; return }
    $mc = Read-Host '  请输入对应的 Minecraft 版本（如 1.21.1）'
  }
  if (-not $neoVer -and $cfg.SelectedLoader -eq 'neoforge' -and $cfg.SelectedLoaderVersion) { $neoVer = $cfg.SelectedLoaderVersion }
  Write-Host ('  目标: MC ' + $mc + ($(if ($neoVer) { '  NeoForge ' + $neoVer } else { '  NeoForge (自动选版)' }))) -ForegroundColor Cyan
  if (-not $neoVer) {
    # 官方 maven 优先，镜像兜底
    $metaUrls = @(
      'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml',
      'https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/maven-metadata.xml'
    )
    $tmp = Join-Path $script:CacheDir 'neoforge_meta.xml'
    $mok = $false
    foreach ($mu in $metaUrls) {
      & curl.exe -s -f -L --ssl-no-revoke -m 20 -o $tmp $mu
      if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item $tmp).Length -gt 0) { $mok = $true; break }
      Write-Host '  元数据源不可用，尝试下一个' -ForegroundColor DarkGray
    }
    if ($mok) {
      $txt = [IO.File]::ReadAllText($tmp)
      Remove-Item $tmp -Force -EA SilentlyContinue
      $m = [regex]::Matches($txt, '<version>([0-9]+\.[0-9]+\.[0-9]+)</version>')
      $prefix = Get-NeoForgePrefix $mc
      $cands = @()
      foreach ($x in $m) {
        $vn = $x.Groups[1].Value
        if (-not $prefix -or $vn.StartsWith($prefix)) { $cands += $vn }
      }
      if ($cands.Count -gt 0) {
        # 按数字段取最大值，避免字符串序把 21.1.9 排到 21.1.264 之后
        $best = $null; $bestKey = -1
        foreach ($c in $cands) {
          $p = $c -split '\.'
          $k = [int64]$p[0] * 1000000 + [int64]$p[1] * 1000 + [int64]$p[2]
          if ($k -gt $bestKey) { $bestKey = $k; $best = $c }
        }
        $neoVer = $best
        Write-Host ('  自动选择 NeoForge: ' + $neoVer + '（对应 MC ' + $mc + '）') -ForegroundColor DarkGray
      }
    }
  }
  if (-not $neoVer) {
    if ($script:NonInteractive) { Write-Host '  无法自动确定 NeoForge 版本（网络不可达）' -ForegroundColor Red; Pause-Any; return }
    Write-Host '  无法确定 NeoForge 版本，请手动输入' -ForegroundColor Yellow
    $neoVer = Read-Host '  NeoForge 版本 (如 21.1.262)'
  }
  if (-not $neoVer) { Pause-Any; return }
  $rel = 'net/neoforged/neoforge/' + $neoVer + '/neoforge-' + $neoVer + '-installer.jar'
  $jar = Join-Path $script:CacheDir 'neoforge-installer.jar'
  Write-Host ('  下载 NeoForge 安装器 ' + $neoVer + ' ...') -ForegroundColor DarkGray
  $ok = $false
  foreach ($u in @(('https://maven.neoforged.net/releases/' + $rel), ('https://bmclapi2.bangbang93.com/maven/' + $rel))) {
    try { Download-File $u $jar $null $true; $ok = $true; break } catch { Write-Host '  该源不可用，尝试下一个' -ForegroundColor Yellow }
  }
  if (-not $ok) { Write-Host '  下载 NeoForge 安装器失败' -ForegroundColor Red; Pause-Any; return }
  $needJ = Get-JavaMajorForMc $mc
  $java = Find-JavaFor $needJ
  if (-not $java) { Write-Host ('  安装 NeoForge 需要 Java ' + $needJ) -ForegroundColor Yellow; Install-Java $needJ; $java = Find-JavaFor $needJ }
  if (-not $java) { Write-Host '  Java 不可用' -ForegroundColor Red; Pause-Any; return }
  # 预置依赖库（经镜像），避免安装器逐个访问不可达源
  try { Prefetch-NeoForgeLibs $jar } catch { Write-Host ('  预置依赖失败: ' + $_.Exception.Message) -ForegroundColor DarkGray }
  Write-Host '  正在安装 NeoForge (可能需要几分钟)...' -ForegroundColor DarkGray
  & $java -jar $jar --installClient $script:McDir
  if ($LASTEXITCODE -eq 0) {
    $fid = 'neoforge-' + $neoVer
    $cfg.SelectedVersion = $fid; $cfg.SelectedLoader = 'neoforge'; $cfg.SelectedLoaderVersion = $neoVer
    Save-Config $cfg
    Write-Host ('  NeoForge 安装完成: ' + $fid) -ForegroundColor Green
    Write-Host '  已自动切换当前版本到该 NeoForge 版本' -ForegroundColor Green
  } else { Write-Host ('  安装失败, 退出码 ' + $LASTEXITCODE) -ForegroundColor Red }
  Pause-Any
}

# ================= 后台下载任务 =================
$script:BgTaskFile = Join-Path $script:CclDir 'bg_task.json'

# 通用后台任务：label=显示名，testCmd=传给 --test 的参数（如 install 1.20.1 / fabricinstall / forgeinstall）
function Start-BackgroundTask($label, $testCmd) {
  if ($label) { $label = $label.Trim('"').Trim("'").Trim() }
  $logPath = Join-Path $script:CacheDir 'bg_task.log'
  if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -EA SilentlyContinue }
  $bat = $script:LauncherPath
  $cmdLine = '/c ""' + $bat + '" --test ' + $testCmd + ' > "' + $logPath + '" 2>&1"'
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
  $ticks = 0
  try { $ticks = $p.StartTime.Ticks } catch {}
  $state = [ordered]@{
    Pid = $p.Id; Label = $label; LogPath = $logPath; StartTime = (Get-Date).ToString('s')
    StartTicks = $ticks
  }
  $state | ConvertTo-Json | Set-Content -LiteralPath $script:BgTaskFile -Encoding UTF8
  Write-Host ('  已在后台开始：' + $label + '（PID ' + $p.Id + '），可继续其他操作。') -ForegroundColor Green
}

function Start-BackgroundInstall($id) {
  Start-BackgroundTask ('安装版本 ' + $id) ('install ' + $id)
}

function Get-BackgroundTask {
  if (-not (Test-Path -LiteralPath $script:BgTaskFile)) { return $null }
  try { return (Get-Content -LiteralPath $script:BgTaskFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Test-BackgroundTaskRunning($task) {
  if (-not $task) { return $false }
  $p = Get-Process -Id $task.Pid -ErrorAction SilentlyContinue
  if (-not $p) { return $false }
  # PID 可能被系统复用，用启动时间做二次校验
  if ($task.StartTicks) {
    try { if ($p.StartTime.Ticks -ne [int64]$task.StartTicks) { return $false } } catch {}
  }
  return $true
}

function Show-BackgroundStatus($brief = $false) {
  $task = Get-BackgroundTask
  if (-not $task) { if (-not $brief) { Write-Host '  没有后台任务。' -ForegroundColor Yellow; Pause-Any }; return }
  $running = Test-BackgroundTaskRunning $task
  $lastLine = ''
  $pct = -1
  if ($task.LogPath -and (Test-Path -LiteralPath $task.LogPath)) {
    try {
      $lines = Get-Content -LiteralPath $task.LogPath -Tail 30 -EA SilentlyContinue
      $last = $lines | Where-Object { $_ -match '%|下载|完成|失败|错误' } | Select-Object -Last 1
      if ($last) { $lastLine = ($last -replace '[\r]', '').Trim() }
      $ms = [regex]::Matches(($lines -join ' '), '(\d{1,3})%')
      if ($ms.Count -gt 0) { $pct = [int]$ms[$ms.Count - 1].Groups[1].Value }
    } catch {}
  }
  $status = if ($running) { '进行中' } else { '已结束' }
  $pctTxt = if ($pct -ge 0) { ' ' + $pct + '%' } else { '' }
  $label = $task.Label
  if (-not $label -and $task.Version) { $label = '安装版本 ' + $task.Version }
  if (-not $label) { $label = '后台任务' }
  Write-Host ('  后台任务: ' + $label + '  [' + $status + $pctTxt + ']') -ForegroundColor Cyan
  if ($lastLine -and -not $brief) { Write-Host ('  最近: ' + $lastLine) -ForegroundColor DarkGray }
  if (-not $brief) {
    Write-Host ''
    if (-not $running) {
      Write-Host '  任务已结束。是否清除该任务记录? (y/N)' -ForegroundColor Yellow
      $a = Read-Host
      if ($a -match '^[Yy]') { Remove-Item -LiteralPath $script:BgTaskFile -Force -EA SilentlyContinue }
    }
    Pause-Any
  }
}

function Get-InstanceDir($name) {
  $safe = ($name -replace '[\\/:*?"<>|]', '_').Trim()
  $safe = $safe.TrimEnd('.')
  if (-not $safe -or $safe -eq '.' -or $safe -eq '..') { $safe = 'instance' }
  if ($safe -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safe = '_' + $safe }
  $root = Join-Path $script:McDir 'instances'
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd($script:Sep)
  $full = [IO.Path]::GetFullPath((Join-Path $rootFull $safe))
  # 兜底：最终路径必须仍在 instances 目录内
  if (-not $full.StartsWith($rootFull + $script:Sep, [StringComparison]::OrdinalIgnoreCase)) { $full = Join-Path $rootFull 'instance' }
  return $full
}

function Import-Mrpack($zipPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipPath = $zipPath.Trim('"').Trim("'").Trim()
  $zipPath = $zipPath -replace '/', $script:Sep
  $tmp = Join-Path $script:CacheDir ('mrpack_' + [guid]::NewGuid().ToString('N'))
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  Write-Host '  解压整合包...' -ForegroundColor DarkGray
  try { [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tmp) } catch { Write-Host ('  解压失败: ' + $_.Exception.Message) -ForegroundColor Red; return }
  $idxPath = Join-Path $tmp 'modrinth.index.json'
  if (-not (Test-Path -LiteralPath $idxPath)) { Write-Host '  不是有效的 Modrinth 整合包 (缺少 modrinth.index.json)' -ForegroundColor Red; Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue; return }
  $idx = $null
  try { $idx = Get-Content -LiteralPath $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host '  解析 modrinth.index.json 失败' -ForegroundColor Red; Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue; return }
  $packName = $idx.name; if (-not $packName) { $packName = 'imported-pack' }
  $instDir = Get-InstanceDir $packName
  if (Test-Path -LiteralPath $instDir) {
    if (-not $script:NonInteractive) {
      $ans = Read-Host ('  实例 "' + (Split-Path -Leaf $instDir) + '" 已存在，覆盖? (y/N)')
      if ($ans -notmatch '^[Yy]') { Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue; return }
    }
    Remove-Item -LiteralPath $instDir -Recurse -Force -EA SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $instDir | Out-Null

  $mcVer = $null; $loader = 'vanilla'; $loaderVer = ''
  if ($idx.dependencies) {
    foreach ($p in $idx.dependencies.PSObject.Properties) {
      if ($p.Name -eq 'minecraft') { $mcVer = $p.Value }
      elseif ($p.Name -eq 'fabric-loader') { $loader = 'fabric'; $loaderVer = $p.Value }
      elseif ($p.Name -eq 'forge') { $loader = 'forge'; $loaderVer = $p.Value }
      elseif ($p.Name -eq 'quilt-loader') { $loader = 'quilt'; $loaderVer = $p.Value }
      elseif ($p.Name -eq 'neoforge') { $loader = 'neoforge'; $loaderVer = $p.Value }
    }
  }

  $files = @($idx.files)
  $clientFiles = @($files | Where-Object { -not ($_.env -and $_.env.client -eq 'unsupported') })
  Write-Host ('  下载整合包文件 (' + $clientFiles.Count + ') ...') -ForegroundColor DarkGray
  $dlItems = New-Object System.Collections.ArrayList
  $instFull = [IO.Path]::GetFullPath($instDir).TrimEnd($script:Sep)
  $skipped = 0
  foreach ($f in $clientFiles) {
    $rel = ([string]$f.path) -replace '/', $script:Sep
    if (-not $rel -or $rel -match '^[\\/]' -or $rel -match '^[A-Za-z]:') { $skipped++; continue }
    $dest = [IO.Path]::GetFullPath((Join-Path $instFull $rel))
    # 拒绝越出实例目录的路径（防 zip-slip 式写入）
    if (-not $dest.StartsWith($instFull + $script:Sep, [StringComparison]::OrdinalIgnoreCase)) { $skipped++; continue }
    $sha1 = $null
    if ($f.hashes -and $f.hashes.sha1) { $sha1 = $f.hashes.sha1 }
    $url = $null
    if ($f.downloads -and $f.downloads.Count -gt 0) { $url = $f.downloads[0] }
    if ($url) { [void]$dlItems.Add(@{ Url = $url; Dest = $dest; Sha1 = $sha1 }) }
  }
  if ($skipped -gt 0) { Write-Host ('  已跳过 ' + $skipped + ' 个越界或非法路径') -ForegroundColor Yellow }
  if ($dlItems.Count -gt 0) { [void](Download-Pool $dlItems (Get-DlThreads) '整合包文件') }

  $ov = Join-Path $tmp 'overrides'
  if (Test-Path -LiteralPath $ov) {
    Write-Host '  应用覆盖文件...' -ForegroundColor DarkGray
    Get-ChildItem -LiteralPath $ov -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $instDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $ovClient = Join-Path $tmp 'client-overrides'
  if (Test-Path -LiteralPath $ovClient) {
    Get-ChildItem -LiteralPath $ovClient -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $instDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue

  Write-Host ('  整合包已导入: ' + $instDir) -ForegroundColor Green
  Write-Host ('  所需 MC: ' + $mcVer + '   加载器: ' + $loader + ' ' + $loaderVer) -ForegroundColor Cyan

  $cfg = Get-Config
  $cfg.GameDir = $instDir
  # 构造与安装器一致的完整版本 id；仅当该版本目录已存在时才直接选中，否则退回基础版本
  $fullId = $null
  if ($loader -eq 'fabric' -and $mcVer -and $loaderVer) { $fullId = 'fabric-loader-' + $loaderVer + '-' + $mcVer }
  elseif ($loader -eq 'forge' -and $mcVer -and $loaderVer) { $fullId = $mcVer + '-forge-' + $loaderVer }
  elseif ($loader -eq 'neoforge' -and $mcVer -and $loaderVer) { $fullId = 'neoforge-' + $loaderVer }
  elseif ($mcVer) { $fullId = $mcVer }
  $verExists = $false
  if ($fullId) { $verExists = Test-Path -LiteralPath (Join-Path (Join-Path $script:McDir 'versions') $fullId) }
  if ($fullId -and $verExists) {
    $cfg.SelectedVersion = $fullId
    $cfg.SelectedLoader = $loader
    $cfg.SelectedLoaderVersion = $loaderVer
  } else {
    # 加载器版本尚未安装：先保持原版状态，避免“加载器=xxx 但启动的是原版”的错位
    if ($mcVer) { $cfg.SelectedVersion = $mcVer }
    $cfg.SelectedLoader = 'vanilla'
    $cfg.SelectedLoaderVersion = ''
  }
  Save-Config $cfg
  Write-Host '  已切换到该实例的游戏目录。' -ForegroundColor Green

  if ($mcVer -and $loader -ne 'vanilla' -and -not $script:NonInteractive) {
    $ans = Read-Host ('  是否现在安装 ' + $loader + ' (' + $mcVer + ')? (Y/n)')
    if ($ans -notmatch '^[Nn]') {
      if ($loader -eq 'fabric') { Install-Fabric }
      elseif ($loader -eq 'forge') { Install-Forge }
      elseif ($loader -eq 'neoforge') { Install-NeoForge }
      else { Write-Host '  quilt 加载器需手动安装。' -ForegroundColor Yellow }
    }
  }
  if (-not $script:NonInteractive) { Pause-Any }
}

# ================= 统一键盘菜单层（方向键 + Enter） =================

function Pause-Any {
  if ($script:NonInteractive) { return }
  Write-Host ''
  Write-Host '  按 Enter 继续...' -ForegroundColor DarkGray
  try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }
}

function Read-YesNo($prompt) {
  Write-Host ('  ' + $prompt + '  (Y/N)') -ForegroundColor Yellow
  try {
    while ($true) {
      $k = [Console]::ReadKey($true)
      if ([string]$k.Key -eq 'Enter') { return $false }
      if ([string]$k.KeyChar -match '^[Yy]$') { return $true }
      if ([string]$k.KeyChar -match '^[Nn]$') { return $false }
    }
  } catch {
    $a = Read-Host
    return ($a -match '^[Yy]')
  }
}

# 通用选择菜单：返回 @{ Index=序号; Key=Enter/Number/字母/Escape }
function Show-Menu {
  param($Title, $Header = @(), $Items = @(), $Footer = '↑↓ 选择   Enter 确认   Esc 返回', $Start = 0, $PageSize = 14, $Keys = '')
  if (-not $Items -or $Items.Count -eq 0) { return @{ Index = -1; Key = 'Empty' } }
  $sel = [int]$Start
  if ($sel -lt 0 -or $sel -ge $Items.Count) { $sel = 0 }
  $top = 0
  while ($true) {
    if ($sel -lt $top) { $top = $sel }
    if ($sel -ge $top + $PageSize) { $top = $sel - $PageSize + 1 }
    Clear-Host
    if ($Title) { Write-Host $Title -ForegroundColor Cyan; Write-Host '' }
    if ($Header -and $Header.Count -gt 0) {
      foreach ($h in @($Header)) { Write-Host $h }
      Write-Host ''
    }
    $last = [Math]::Min($Items.Count - 1, $top + $PageSize - 1)
    for ($i = $top; $i -le $last; $i++) {
      $txt = [string]$Items[$i]
      if ($i -eq $sel) { Write-Host ('  > ' + $txt) -ForegroundColor Black -BackgroundColor Cyan }
      else { Write-Host ('    ' + $txt) }
    }
    if ($Items.Count -gt $PageSize) {
      $pg = [int][Math]::Floor($top / $PageSize) + 1
      $tp = [int][Math]::Ceiling($Items.Count / $PageSize)
      Write-Host ''
      Write-Host ('  第 ' + $pg + '/' + $tp + ' 页（共 ' + $Items.Count + ' 项）') -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('  ' + $Footer) -ForegroundColor DarkGray
    $k = $null
    try { $k = [Console]::ReadKey($true) } catch { $k = $null }
    if (-not $k) {
      # 非交互环境降级为序号输入
      $line = Read-Host '  输入序号（回车取消）'
      if ($line -eq '0' -or -not $line) { return @{ Index = -1; Key = 'Escape' } }
      if ($line -match '^\d+$') {
        $n = [int]$line - 1
        if ($n -ge 0 -and $n -lt $Items.Count) { return @{ Index = $n; Key = 'Number' } }
      }
      return @{ Index = -1; Key = 'Escape' }
    }
    switch ([string]$k.Key) {
      'UpArrow'    { if ($sel -gt 0) { $sel-- } else { $sel = $Items.Count - 1 } }
      'DownArrow'  { if ($sel -lt $Items.Count - 1) { $sel++ } else { $sel = 0 } }
      'PageUp'     { $sel = [Math]::Max(0, $sel - $PageSize) }
      'PageDown'   { $sel = [Math]::Min($Items.Count - 1, $sel + $PageSize) }
      'Home'       { $sel = 0 }
      'End'        { $sel = $Items.Count - 1 }
      'Enter'      { return @{ Index = $sel; Key = 'Enter' } }
      'Escape'     { return @{ Index = -1; Key = 'Escape' } }
      'LeftArrow'  { $sel = [Math]::Max(0, $sel - $PageSize) }
      'RightArrow' { $sel = [Math]::Min($Items.Count - 1, $sel + $PageSize) }
      default {
        $ch = [string]$k.KeyChar
        if ($ch -eq '0') { return @{ Index = -1; Key = 'Escape' } }
        if ($ch -match '^[0-9]$') {
          $n = [int]$ch - 1
          if ($n -ge 0 -and $n -lt $Items.Count) { return @{ Index = $n; Key = 'Number' } }
        } elseif ($ch -match '^[A-Za-z]$') {
          $u = $ch.ToUpper()
          if ($u -eq 'Q') { return @{ Index = -1; Key = 'Escape' } }
          if ($Keys -and $Keys.ToUpper().Contains($u)) { return @{ Index = $sel; Key = $u } }
        }
      }
    }
  }
}

# ================= 中文 Mod 搜索（多源合并 + 兜底） =================

function Normalize-ModQuery($q) {
  if (-not $q) { return '' }
  $s = [string]$q
  $s = $s -replace [string][char]0x3000, ' '
  $s = $s.Trim().Trim('"').Trim("'").Trim()
  $s = $s -replace '\s+', ' '
  return $s
}

# 常见中文名 -> 英文关键词，麦块不可用/无结果时仍能搜到
function ConvertTo-EnglishQuery($q) {
  $map = @{
    '机械动力' = 'create'; '合成表' = 'jei'; '物品管理器' = 'jei'; '钠' = 'sodium';
    '苹果皮' = 'apple skin'; '小地图' = 'xaero minimap'; '旅行地图' = 'journeymap';
    '光影前置' = 'iris'; '光影' = 'shaders'; '暮色森林' = 'twilight forest';
    '植物魔法' = 'botania'; '匠魂' = 'tinkers construct'; '拔刀剑' = 'slashblade';
    '等价交换' = 'projecte'; '无尽' = 'avaritia'; '工业' = 'industrial craft';
    '家具' = 'furniture'; '背包' = 'backpack'; '储物' = 'storage'; '农业' = 'farming';
    '附魔' = 'enchant'; '任务' = 'quest'; '优化' = 'optimize'; '性能' = 'performance'
  }
  $s = [string]$q
  foreach ($k in $map.Keys) { if ($s.Contains($k)) { $s = $s.Replace($k, ' ' + $map[$k] + ' ') } }
  $s = $s -replace '[一-鿿]', ' '
  $s = ($s -replace '\s+', ' ').Trim()
  if (-not $s) { return $null }
  return $s
}

function Search-ModMinekuai($q, $mcVer, $loader, $limit = 20) {
  $base = 'https://api.minekuai.cn/panel/public/mc-mods?q=' + [uri]::EscapeDataString($q) + '&limit=' + $limit
  if ($loader) { $base += '&loader%5B%5D=' + [uri]::EscapeDataString($loader) }
  if ($mcVer) { $base += '&game_version%5B%5D=' + [uri]::EscapeDataString($mcVer) }
  $resp = $null
  foreach ($extra in @('&status=translated', '')) {
    try { $resp = Get-Json ($base + $extra) $null 0 } catch { $resp = $null }
    if ($resp) { break }
  }
  if (-not $resp) { throw '麦块 API 不可用' }
  $arr = @()
  if ($resp.items) { $arr = @($resp.items) }
  elseif ($resp.data) { $arr = @($resp.data) }
  elseif ($resp.hits) { $arr = @($resp.hits) }
  $hits = New-Object System.Collections.ArrayList
  foreach ($it in $arr) {
    if (-not $it) { continue }
    $slug = $it.slug
    if (-not $slug -and $it.project_id) { $slug = [string]$it.project_id }
    if (-not $slug) { continue }
    $zh = $it.title_zh
    if (-not $zh -and $it.title_cn) { $zh = $it.title_cn }
    if ($zh -and ([string]$zh).Trim() -eq '') { $zh = $null }
    $desc = $it.description_zh
    if (-not $desc -or ([string]$desc).Trim() -eq '') { $desc = $it.description_en }
    if (-not $desc) { $desc = $it.description }
    [void]$hits.Add([PSCustomObject]@{
      slug = [string]$slug
      title = [string]$it.title
      title_zh = $zh
      description = $desc
      downloads = $it.downloads
      loaders = @($it.loaders)
      game_versions = @($it.game_versions)
    })
  }
  return [PSCustomObject]@{ hits = @($hits); source = 'minekuai'; total = $resp.total }
}

function Search-ModCombined($q, $mcVer, $loader, $limit = 20) {
  $q = Normalize-ModQuery $q
  if (-not $q) { return [PSCustomObject]@{ hits = @(); source = 'none'; total = 0 } }
  $all = New-Object System.Collections.ArrayList
  $seen = @{}
  $sources = New-Object System.Collections.ArrayList
  $err = @()

  try {
    $r1 = Search-ModMinekuai $q $mcVer $loader $limit
    foreach ($h in @($r1.hits)) {
      $key = ([string]$h.slug).ToLower()
      if (-not $key -or $seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      [void]$all.Add($h)
    }
    if ($all.Count -gt 0) { [void]$sources.Add('麦块') }
  } catch { $err += $_.Exception.Message }

  if ($all.Count -lt $limit) {
    try {
      $r2 = Search-Modrinth $q $mcVer $loader $limit
      foreach ($h in @($r2.hits)) {
        $key = ([string]$h.slug).ToLower()
        if (-not $key -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$all.Add([PSCustomObject]@{
          slug = [string]$h.slug; title = [string]$h.title; title_zh = $null
          description = $h.description; downloads = $h.downloads
          loaders = @($h.loaders); game_versions = @($h.versions)
        })
      }
      if ($r2.hits -and @($r2.hits).Count -gt 0) { [void]$sources.Add('Modrinth') }
    } catch { $err += $_.Exception.Message }
  }

  # 中文查询仍无结果：翻译成英文再试一次
  if ($all.Count -eq 0 -and (Test-HasChinese $q)) {
    $en = ConvertTo-EnglishQuery $q
    if ($en) {
      try {
        $r3 = Search-Modrinth $en $mcVer $loader $limit
        foreach ($h in @($r3.hits)) {
          $key = ([string]$h.slug).ToLower()
          if (-not $key -or $seen.ContainsKey($key)) { continue }
          $seen[$key] = $true
          [void]$all.Add([PSCustomObject]@{
            slug = [string]$h.slug; title = [string]$h.title; title_zh = $null
            description = $h.description; downloads = $h.downloads
            loaders = @($h.loaders); game_versions = @($h.versions)
          })
        }
        if ($all.Count -gt 0) { [void]$sources.Add('Modrinth(英)') }
      } catch { $err += $_.Exception.Message }
    }
  }

  if ($all.Count -eq 0 -and $err.Count -gt 0) { throw ('搜索失败: ' + ($err -join ' | ')) }
  $src = 'none'
  if ($sources.Count -gt 0) { $src = ($sources -join ' + ') }
  return [PSCustomObject]@{ hits = @($all); source = $src; total = $all.Count }
}

function Show-ModSearch {
  $cfg = Get-Config
  if (-not $cfg.SelectedVersion) { Write-Host '  请先在版本管理中选择一个版本' -ForegroundColor Yellow; Pause-Any; return }
  if (-not $cfg.SelectedLoader -or $cfg.SelectedLoader -eq 'vanilla') {
    Write-Host '  当前是原版，无法搜索 Mod。请先安装并切换到 Fabric / Forge / NeoForge 版本。' -ForegroundColor Yellow
    Pause-Any; return
  }
  $loader = Get-LoaderName $cfg
  $mcVer = Get-McVersion $cfg
  if (-not $mcVer) { Write-Host ('  无法推断 Minecraft 版本: ' + $cfg.SelectedVersion) -ForegroundColor Red; Pause-Any; return }
  $q = $null
  while ($true) {
    if (-not $q) {
      Clear-Host
      Write-Host '=== Mod 搜索 ===' -ForegroundColor Cyan
      Write-Host ('  当前: ' + $cfg.SelectedVersion + '   MC ' + $mcVer + ' / ' + $loader) -ForegroundColor Green
      Write-Host '  支持中文名（机械动力、合成表）或英文名（sodium、jei）'
      $q = Normalize-ModQuery (Read-Host '  搜索关键词 (留空返回)')
      if (-not $q) { return }
      Clear-Host
      Write-Host ('  正在搜索 "' + $q + '" ...') -ForegroundColor DarkGray
      $script:ModSearchResult = $null
      try { $script:ModSearchResult = Search-ModCombined $q $mcVer $loader 20 }
      catch { Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any; $q = $null; continue }
      if (-not $script:ModSearchResult.hits -or $script:ModSearchResult.hits.Count -eq 0) {
        Write-Host '  没有结果，换个关键词试试' -ForegroundColor Yellow
        Start-Sleep -Milliseconds 600
        $q = $null; continue
      }
    }
    $r = $script:ModSearchResult
    $items = @()
    for ($i = 0; $i -lt $r.hits.Count; $i++) {
      $h = $r.hits[$i]
      $zh = $h.title_zh; $en = $h.title
      $label = if ($zh -and $en -and $zh -ne $en) { $zh + ' / ' + $en } elseif ($zh) { $zh } else { $en }
      if (-not $label) { $label = $h.slug }
      if ($label.Length -gt 46) { $label = $label.Substring(0, 46) + '...' }
      $dl = 0; if ($h.downloads) { $dl = [int64]$h.downloads }
      $items += ('{0}. {1}  [{2}]  ↓{3}' -f ($i + 1), $label, $h.slug, $dl)
    }
    $res = Show-Menu -Title ('=== 搜索结果: ' + $q + ' ===') -Header @(('  数据源: ' + $r.source + '   共 ' + $r.hits.Count + ' 条'), ('  MC ' + $mcVer + ' / ' + $loader)) -Items $items -Footer '↑↓ 选择   Enter 下载安装   F 换关键词   Esc 返回' -PageSize 12 -Keys 'F'
    if ($res.Key -eq 'F') { $q = $null; continue }
    if ($res.Key -eq 'Escape' -or $res.Index -lt 0) { return }
    if ($res.Key -eq 'Enter' -or $res.Key -eq 'Number') {
      Install-ModFromProject $r.hits[$res.Index].slug $cfg
      Pause-Any
    }
  }
}

function Show-LocalMods {
  $modDir = Get-ModDir
  if (-not (Test-Path -LiteralPath $modDir)) { New-Item -ItemType Directory -Force -Path $modDir | Out-Null }
  $filter = ''
  while ($true) {
    $all = @(Get-ChildItem -LiteralPath $modDir -File -EA SilentlyContinue | Where-Object { $_.Name -match '(?i)\.jar(\.disabled)?$' } | Sort-Object Name)
    $files = $all
    if ($filter) { $files = @($all | Where-Object { $_.Name -like ('*' + $filter + '*') }) }
    $items = @()
    foreach ($f in $files) {
      $name = $f.Name
      if ($name.ToLower().EndsWith('.disabled')) { $items += ('[禁用] ' + $name.Substring(0, $name.Length - 9)) }
      else { $items += ('[启用] ' + $name) }
    }
    $header = @('  目录: ' + $modDir)
    if ($filter) { $header += ('  筛选: "' + $filter + '"  匹配 ' + $files.Count + '/' + $all.Count) }
    $footer = '↑↓ 选择   Enter 启用/禁用   D 删除   F 筛选   Esc 返回'
    if ($items.Count -eq 0) { $items = @('(空)') }
    $res = Show-Menu -Title '=== 本地 Mod ===' -Header $header -Items $items -Footer $footer -PageSize 14 -Keys 'DF'
    if ($res.Key -eq 'Escape') { return }
    if ($res.Key -eq 'F') {
      $filter = (Read-Host '  筛选关键词（留空清除）').Trim()
      continue
    }
    if ($files.Count -eq 0 -or $res.Index -lt 0 -or $res.Index -ge $files.Count) { continue }
    $f = $files[$res.Index]
    if ($res.Key -eq 'D') {
      if (Read-YesNo ('删除 ' + $f.Name + ' ?')) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
      continue
    }
    if ($res.Key -eq 'Enter' -or $res.Key -eq 'Number') {
      if ($f.Name.ToLower().EndsWith('.disabled')) {
        $newname = $f.Name.Substring(0, $f.Name.Length - 9)
        Rename-Item -LiteralPath $f.FullName -NewName $newname -EA SilentlyContinue
      } else {
        Rename-Item -LiteralPath $f.FullName -NewName ($f.Name + '.disabled') -EA SilentlyContinue
      }
    }
  }
}

function Show-ModMenu {
  $pre = Get-Config
  if (-not $pre.SelectedLoader -or $pre.SelectedLoader -eq 'vanilla') {
    Clear-Host
    Write-Host '=== Mod 管理 ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  当前是原版（vanilla），无法加载 Mod。' -ForegroundColor Yellow
    Write-Host '  请先在「5. 安装 Mod 加载器」安装 Fabric / Forge / NeoForge，' -ForegroundColor Yellow
    Write-Host '  然后在「2. 版本管理」中切换到对应加载器版本。' -ForegroundColor Yellow
    Pause-Any
    return
  }
  while ($true) {
    $cfg = Get-Config
    $v = $cfg.SelectedVersion; if (-not $v) { $v = '(未选择)' }
    $mcv = Get-McVersion $cfg; if (-not $mcv) { $mcv = '(未知)' }
    $res = Show-Menu -Title '=== Mod 管理 ===' -Header @(('  版本: ' + $v), ('  MC ' + $mcv + ' / ' + (Get-LoaderName $cfg))) -Items @('1. 搜索并下载 Mod', '2. 本地 Mod 管理 (启用/禁用/删除)', '0. 返回') -Footer '↑↓ 选择   Enter 确认   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 2) { return }
    if ($res.Index -eq 0) { Show-ModSearch }
    elseif ($res.Index -eq 1) { Show-LocalMods }
  }
}

function Select-Version($releaseOnly = $false) {
  Clear-Host
  Write-Host '正在获取版本列表...' -ForegroundColor DarkGray
  $man = Get-VersionManifest
  $all = @(Sort-Versions $man.versions)
  if ($releaseOnly) { $all = @($all | Where-Object { $_.type -eq 'release' }) }
  $items = @()
  foreach ($v in $all) {
    $tag = '[正式]'
    if ($v.type -eq 'snapshot') { $tag = '[快照]' }
    elseif ($v.type -ne 'release') { $tag = '[' + $v.type + ']' }
    $items += ($v.id + '  ' + $tag)
  }
  $res = Show-Menu -Title '=== 可用版本 ===' -Header @('  共 ' + $all.Count + ' 个版本') -Items $items -Footer '↑↓ 翻滚   Enter 选择   Esc 返回' -PageSize 16
  if ($res.Index -lt 0) { return $null }
  return $all[$res.Index]
}

function Show-VersionMenu {
  while ($true) {
    $res = Show-Menu -Title '=== 版本管理 ===' -Items @('1. 查看并下载官方版本', '2. 已安装版本 (切换/删除)', '0. 返回') -Footer '↑↓ 选择   Enter 确认   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 2) { return }
    if ($res.Index -eq 0) {
      $v = Select-Version $false
      if (-not $v) { continue }
      $m = Show-Menu -Title ('安装版本 ' + $v.id) -Items @('1. 前台安装（显示进度）', '2. 后台安装（可继续操作）', '0. 取消') -Footer '↑↓ 选择   Enter 确认'
      if ($m.Index -eq 1) { Start-BackgroundInstall $v.id; Pause-Any }
      elseif ($m.Index -eq 0) { try { Install-Version $v.id } catch { Write-Host ('安装失败: ' + $_.Exception.Message) -ForegroundColor Red }; Pause-Any }
    } elseif ($res.Index -eq 1) {
      $vd = Join-Path $script:McDir 'versions'
      $vers = @()
      if (Test-Path -LiteralPath $vd) { $vers = @(Get-ChildItem -LiteralPath $vd -Directory | Select-Object -ExpandProperty Name) }
      if ($vers.Count -eq 0) { Clear-Host; Write-Host '  尚无已安装版本' -ForegroundColor Yellow; Pause-Any; continue }
      $cur = (Get-Config).SelectedVersion
      $items = @()
      foreach ($n in $vers) { if ($n -eq $cur) { $items += ('* ' + $n) } else { $items += ('  ' + $n) } }
      $sr = Show-Menu -Title '=== 已安装版本 ===' -Items $items -Footer '↑↓ 选择   Enter 切换   D 删除   Esc 返回' -Keys 'D'
      if ($sr.Key -eq 'Escape' -or $sr.Index -lt 0) { continue }
      $name = $vers[$sr.Index]
      if ($sr.Key -eq 'D') {
        if ($name -eq $cur) { Write-Host '  不能删除当前版本，请先切换' -ForegroundColor Red; Pause-Any; continue }
        $deps = @()
        foreach ($d in @(Get-ChildItem -LiteralPath $vd -Directory -EA SilentlyContinue)) {
          if ($d.Name -eq $name) { continue }
          $jf = Join-Path $d.FullName ($d.Name + '.json')
          if (-not (Test-Path -LiteralPath $jf)) { continue }
          try { $jj = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json; if ($jj.inheritsFrom -eq $name) { $deps += $d.Name } } catch {}
        }
        if ($deps.Count -gt 0) { Write-Host ('  被以下版本继承，先删除它们: ' + ($deps -join ', ')) -ForegroundColor Red; Pause-Any; continue }
        if (Read-YesNo ('删除 ' + $name + ' ?')) {
          try { Remove-Item -LiteralPath (Join-Path $vd $name) -Recurse -Force; Write-Host '  已删除' -ForegroundColor Green } catch { Write-Host ('  删除失败: ' + $_.Exception.Message) -ForegroundColor Red }
          Pause-Any
        }
        continue
      }
      $cfg = Get-Config
      $cfg.SelectedVersion = $name
      $cfg.SelectedLoaderVersion = ''
      if ($name -match '^fabric-loader-(.+)-([0-9].*)$') { $cfg.SelectedLoader = 'fabric'; $cfg.SelectedLoaderVersion = $Matches[1] }
      elseif ($name -match '^neoforge-(.+)$') { $cfg.SelectedLoader = 'neoforge'; $cfg.SelectedLoaderVersion = $Matches[1] }
      elseif ($name -match '^(.+)-forge-(.+)$') { $cfg.SelectedLoader = 'forge'; $cfg.SelectedLoaderVersion = $Matches[2] }
      else { $cfg.SelectedLoader = 'vanilla' }
      if ($cfg.GameDir) { $cfg.GameDir = '' }
      Save-Config $cfg
    }
  }
}

function Show-JavaMenu {
  while ($true) {
    $cur = Find-Java
    $header = @()
    if ($cur) { $header += ('  当前: ' + $cur); $header += ('  版本: ' + (Get-JavaVersion $cur)) }
    else { $header += '  当前: (无)' }
    $res = Show-Menu -Title '=== Java 管理 ===' -Header $header -Items @('1. 安装 Java 8', '2. 安装 Java 17', '3. 安装 Java 21', '4. 手动指定 java.exe 路径', '0. 返回') -Footer '↑↓ 选择   Enter 确认   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 4) { return }
    if ($res.Index -in @(0, 1, 2)) {
      $m = @(8, 17, 21)[$res.Index]
      try { Install-Java $m } catch { Write-Host ('安装失败: ' + $_.Exception.Message) -ForegroundColor Red }
      Pause-Any
    } elseif ($res.Index -eq 3) {
      $p = Read-Host '  java.exe 路径'
      if ($p -and (Test-Path -LiteralPath $p)) { $cfg = Get-Config; $cfg.JavaPath = $p; Save-Config $cfg; Write-Host '  已保存' -ForegroundColor Green }
      else { Write-Host '  路径无效' -ForegroundColor Red }
      Pause-Any
    }
  }
}

function Show-Settings {
  while ($true) {
    $cfg = Get-Config
    $gd = $cfg.GameDir; if (-not $gd) { $gd = '(默认 .minecraft)' }
    $ja = $cfg.JvmArgs; if (-not $ja) { $ja = '(无)' }
    $eg = $cfg.ExtraGameArgs; if (-not $eg) { $eg = '(无)' }
    $items = @(
      '1. 玩家名       : ' + $cfg.PlayerName,
      '2. 内存 (MB)    : ' + $cfg.MemoryMB,
      '3. 窗口大小     : ' + $cfg.WindowWidth + ' x ' + $cfg.WindowHeight,
      '4. 额外 JVM 参数: ' + $ja,
      '5. 游戏目录     : ' + $gd,
      '6. 全屏启动     : ' + $(if ($cfg.Fullscreen) { '是' } else { '否' }),
      '7. 演示模式     : ' + $(if ($cfg.DemoMode) { '是' } else { '否' }),
      '8. 额外游戏参数 : ' + $eg,
      '9. 调试模式     : ' + $(if ($cfg.DebugMode) { '开' } else { '关' }),
      '0. 返回'
    )
    $res = Show-Menu -Title '=== 设置 ===' -Items $items -Footer '↑↓ 选择   Enter 修改/切换   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 9) { return }
    switch ($res.Index) {
      0 { $n = Read-Host '  玩家名'; if ($n) { $cfg.PlayerName = $n.Trim(); Save-Config $cfg } }
      1 {
        $m = Read-Host '  内存 MB (512-65536)'
        if ($m -match '^\d+$' -and [int]$m -ge 512 -and [int]$m -le 65536) { $cfg.MemoryMB = [int]$m; Save-Config $cfg }
        else { Write-Host '  无效数值' -ForegroundColor Red; Pause-Any }
      }
      2 {
        $w = Read-Host '  宽度'; $h = Read-Host '  高度'
        if ($w -match '^\d+$' -and $h -match '^\d+$') { $cfg.WindowWidth = [int]$w; $cfg.WindowHeight = [int]$h; Save-Config $cfg }
        else { Write-Host '  无效数值' -ForegroundColor Red; Pause-Any }
      }
      3 { $cfg.JvmArgs = (Read-Host '  额外 JVM 参数（空格分隔）'); Save-Config $cfg }
      4 {
        $g = Read-Host '  游戏目录（留空恢复默认）'
        if (-not $g) { $cfg.GameDir = ''; Save-Config $cfg }
        elseif (Test-Path -LiteralPath $g) { $cfg.GameDir = $g; Save-Config $cfg }
        else { Write-Host '  目录不存在' -ForegroundColor Red; Pause-Any }
      }
      5 { $cfg.Fullscreen = (-not $cfg.Fullscreen); Save-Config $cfg }
      6 { $cfg.DemoMode = (-not $cfg.DemoMode); Save-Config $cfg }
      7 { $cfg.ExtraGameArgs = (Read-Host '  额外游戏参数（空格分隔）'); Save-Config $cfg }
      8 { $cfg.DebugMode = (-not $cfg.DebugMode); Save-Config $cfg }
    }
  }
}

function Show-LoaderMenu {
  while ($true) {
    $cfg = Get-Config
    $v = $cfg.SelectedVersion; if (-not $v) { $v = '(未选择)' }
    $res = Show-Menu -Title '=== 安装 Mod 加载器 ===' -Header @('  当前版本: ' + $v) -Items @(
      '1. 安装 Fabric（前台）', '2. 安装 Forge（前台）', '3. 安装 NeoForge（前台）',
      '4. 安装 Fabric（后台）', '5. 安装 Forge（后台）', '6. 安装 NeoForge（后台）', '0. 返回'
    ) -Footer '↑↓ 选择   Enter 确认   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 6) { return }
    if (-not $cfg.SelectedVersion) { Write-Host '  请先选择一个 Minecraft 版本' -ForegroundColor Yellow; Pause-Any; continue }
    switch ($res.Index) {
      0 { Install-Fabric }
      1 { Install-Forge }
      2 { Install-NeoForge }
      3 { Start-BackgroundTask ('安装 Fabric (' + $cfg.SelectedVersion + ')') 'fabricinstall'; Pause-Any }
      4 { Start-BackgroundTask ('安装 Forge (' + $cfg.SelectedVersion + ')') 'forgeinstall'; Pause-Any }
      5 { Start-BackgroundTask ('安装 NeoForge (' + $cfg.SelectedVersion + ')') 'neoforgeinstall'; Pause-Any }
    }
  }
}

function Show-ModpackMenu {
  while ($true) {
    $res = Show-Menu -Title '=== 整合包导入 ===' -Header @('  支持 Modrinth 整合包 (.mrpack)') -Items @('1. 从文件导入 (.mrpack)', '2. 已导入实例 (切换)', '0. 返回') -Footer '↑↓ 选择   Enter 确认   Esc 返回'
    if ($res.Key -eq 'Escape' -or $res.Index -eq 2) { return }
    if ($res.Index -eq 0) {
      $p = (Read-Host '  .mrpack 文件完整路径').Trim('"').Trim()
      if ($p -and (Test-Path -LiteralPath $p)) { Import-Mrpack $p } else { Write-Host '  文件不存在' -ForegroundColor Red; Pause-Any }
    } elseif ($res.Index -eq 1) {
      $idir = Join-Path $script:McDir 'instances'
      $ds = @()
      if (Test-Path -LiteralPath $idir) { $ds = @(Get-ChildItem -LiteralPath $idir -Directory -EA SilentlyContinue) }
      if ($ds.Count -eq 0) { Clear-Host; Write-Host '  (无已导入实例)' -ForegroundColor Yellow; Pause-Any; continue }
      $cfg = Get-Config
      $items = @()
      foreach ($d in $ds) { if ($d.FullName -eq $cfg.GameDir) { $items += ('* ' + $d.Name) } else { $items += ('  ' + $d.Name) } }
      $sr = Show-Menu -Title '=== 已导入实例 ===' -Items $items -Footer '↑↓ 选择   Enter 切换   Esc 返回'
      if ($sr.Index -ge 0) {
        $cfg.GameDir = $ds[$sr.Index].FullName
        Save-Config $cfg
      }
    }
  }
}

function Show-MainMenu {
  while ($true) {
    $cfg = Get-Config
    $needJ = 8
    if ($cfg.SelectedVersion) { $mcv = Get-McVersion $cfg; if ($mcv) { $needJ = Get-JavaMajorForMc $mcv } }
    $j = Find-JavaFor $needJ
    if (-not $j) { $j = '(未安装，启动时自动装 Java ' + $needJ + ')' }
    $v = $cfg.SelectedVersion; if (-not $v) { $v = '(未选择)' }
    $header = @(
      ('  玩家   : ' + $cfg.PlayerName),
      ('  版本   : ' + $v),
      ('  加载器 : ' + $cfg.SelectedLoader),
      ('  系统   : ' + $script:OSArch + '  (' + $(if ($script:Is64) { '64 位' } else { '32 位' }) + ')'),
      ('  Java   : ' + $j + '   [需 ' + $needJ + ']')
    )
    $bt = Get-BackgroundTask
    if ($bt -and (Test-BackgroundTaskRunning $bt)) { $header += ('  后台   : ' + $bt.Label + ' [进行中]') }
    $items = @(
      '1. 启动游戏', '2. 版本管理', '3. Java 管理', '4. Mod 管理 (搜索下载/本地管理)',
      '5. 安装 Mod 加载器 (Fabric/Forge/NeoForge)', '6. 整合包导入', '7. 设置', '8. 后台任务', '0. 退出'
    )
    $r = Show-Menu -Title '========== CCL Minecraft 启动器 ==========' -Header $header -Items $items -Footer '↑↓ 选择   Enter 确认   数字直选   Esc 退出'
    if ($r.Key -eq 'Escape' -or $r.Index -eq 8) { return }
    try {
      switch ($r.Index) {
        0 {
          if (-not $cfg.SelectedVersion) {
            $vv = Select-Version $false
            if (-not $vv) { continue }
            $cfg.SelectedVersion = $vv.id; Save-Config $cfg
          }
          try { Start-Minecraft $cfg.SelectedVersion; Pause-Any } catch { Write-Host ('启动失败: ' + $_.Exception.Message) -ForegroundColor Red; Pause-Any }
        }
        1 { Show-VersionMenu }
        2 { Show-JavaMenu }
        3 { Show-ModMenu }
        4 { Show-LoaderMenu }
        5 { Show-ModpackMenu }
        6 { Show-Settings }
        7 { Show-BackgroundStatus $false }
      }
    } catch {
      Write-Host ''
      Write-Host ('操作出错: ' + $_.Exception.Message) -ForegroundColor Red
      Pause-Any
    }
  }
}

$script:Args = @()
if ($env:CCL_ARGS) { $script:Args = @($env:CCL_ARGS -split ' +' | Where-Object { $_ }) }

try {
  if ($script:Args.Count -ge 2 -and $script:Args[0] -eq '--test') {
    Invoke-SelfTest ($script:Args[1..($script:Args.Count - 1)])
  } else {
    Show-MainMenu
  }
} catch {
  Write-Host ''
  Write-Host ('错误: ' + $_.Exception.Message) -ForegroundColor Red
  if (-not $env:CCL_ARGS) { [void](Read-Host '按回车退出') }
  exit 1
}
