[CmdletBinding()]
param(
    # Run manually with -Configure to change the saved wallet, worker, or pool.
    [switch]$Configure
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$baseDir      = Join-Path $env:USERPROFILE 'Documents\MoneroMiner'
$extractDir   = Join-Path $baseDir 'xmrig'
$settingsPath = Join-Path $baseDir 'miner-settings.json'
$zipPath      = Join-Path $baseDir 'xmrig-windows-x64.zip'
$checksumPath = Join-Path $baseDir 'SHA256SUMS'

New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

function Get-XmrigExecutable {
    if (Test-Path $extractDir) {
        $found = Get-ChildItem -Path $extractDir -Filter 'xmrig.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-XmrigIfMissing {
    $existing = Get-XmrigExecutable
    if ($existing) {
        Write-Host "Using existing XMRig: $existing" -ForegroundColor Green
        return $existing
    }

    Write-Host 'XMRig was not found. Downloading the official Windows x64 release...' -ForegroundColor Yellow
    $headers = @{
        'User-Agent' = 'Monero-CPU-Miner-Setup'
        'Accept'     = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/xmrig/xmrig/releases/latest' -Headers $headers

    $asset = $release.assets | Where-Object { $_.name -match '^xmrig-\d+\.\d+\.\d+-windows-x64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match '^xmrig-\d+\.\d+\.\d+-(windows-gcc-x64|msvc-win64)\.zip$' } | Select-Object -First 1
    }
    if (-not $asset) {
        throw "Could not locate a Windows x64 archive in official release '$($release.tag_name)'. Check https://github.com/xmrig/xmrig/releases ."
    }

    Write-Host "Release: $($release.tag_name)"
    Write-Host "Archive: $($asset.name)"
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = 'Monero-CPU-Miner-Setup' }

    # Verify against GitHub's asset digest, or the release's official SHA256SUMS file.
    $expectedHash = $null
    if ($asset.digest -and $asset.digest -match '^sha256:([A-Fa-f0-9]{64})$') {
        $expectedHash = $Matches[1].ToLowerInvariant()
    }
    else {
        $checksumsAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
        if (-not $checksumsAsset) {
            throw 'The release provides no SHA-256 digest or SHA256SUMS file. Refusing to run an unverified archive.'
        }
        Invoke-WebRequest -UseBasicParsing -Uri $checksumsAsset.browser_download_url -OutFile $checksumPath -Headers @{ 'User-Agent' = 'Monero-CPU-Miner-Setup' }
        $pattern = '^\s*([A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape($asset.name) + '\s*$'
        $checksumLine = Get-Content -Path $checksumPath | Where-Object { $_ -match $pattern } | Select-Object -First 1
        $checksumMatch = [regex]::Match([string]$checksumLine, $pattern)
        if (-not $checksumMatch.Success) {
            throw "Could not find a SHA-256 checksum for $($asset.name) in the official SHA256SUMS file."
        }
        $expectedHash = $checksumMatch.Groups[1].Value.ToLowerInvariant()
    }

    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed. Expected $expectedHash but got $actualHash. The archive has been deleted."
    }
    Write-Host 'SHA-256 verified.' -ForegroundColor Green

    if (Test-Path $extractDir) { Remove-Item -Path $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $installed = Get-XmrigExecutable
    if (-not $installed) { throw 'xmrig.exe was not found after extracting the verified official archive.' }
    return $installed
}

function Read-OrCreateSettings {
    if ((Test-Path $settingsPath) -and (-not $Configure)) {
        try {
            $saved = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$saved.Wallet) -and
                -not [string]::IsNullOrWhiteSpace([string]$saved.Worker) -and
                -not [string]::IsNullOrWhiteSpace([string]$saved.PoolHost) -and
                [int]$saved.PoolPort -gt 0) {
                Write-Host "Loaded saved settings from $settingsPath" -ForegroundColor Green
                return $saved
            }
        }
        catch {
            Write-Host 'The saved settings file could not be read; setup will run again.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    if ($Configure) {
        Write-Host 'Reconfiguring Monero miner settings.' -ForegroundColor Cyan
    }
    else {
        Write-Host 'First-run setup: settings will be saved, so future launches will not ask again.' -ForegroundColor Cyan
    }
    Write-Host 'Enter only your public Monero receive address. Never enter your seed phrase or private keys.' -ForegroundColor Yellow

    $wallet = (Read-Host 'Enter your Monero wallet address').Trim()
    if ([string]::IsNullOrWhiteSpace($wallet)) { throw 'Wallet address cannot be empty.' }

    $worker = (Read-Host "Worker name (press Enter for 'pc1')").Trim()
    if ([string]::IsNullOrWhiteSpace($worker)) { $worker = 'pc1' }
    if ($worker -match '[\s"'']') { throw 'Worker name cannot contain spaces or quotes. Use a simple name such as pc1.' }

    # XMRPool.eu states that its published mining ports support TLS.
    # SupportXMR choices are only offered when their TCP port is reachable from this PC.
    $candidatePools = @(
        @{ Name = 'XMRPool.eu — CPU port, TLS'; Host = 'xmrpool.eu'; Port = 3333; Tls = $true },
        @{ Name = 'XMRPool.eu — TLS port 443'; Host = 'xmrpool.eu'; Port = 443; Tls = $true },
        @{ Name = 'SupportXMR — TCP port 3333'; Host = 'pool.supportxmr.com'; Port = 3333; Tls = $false },
        @{ Name = 'SupportXMR — TLS port 443'; Host = 'pool.supportxmr.com'; Port = 443; Tls = $true }
    )

    Write-Host ''
    Write-Host 'Checking pool endpoints from this computer...' -ForegroundColor Yellow
    $availablePools = @()
    foreach ($candidate in $candidatePools) {
        $address = "$($candidate.Host):$($candidate.Port)"
        $isOpen = $false
        try {
            $isOpen = [bool](Test-NetConnection -ComputerName $candidate.Host -Port $candidate.Port -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
        catch { $isOpen = $false }

        if ($isOpen) {
            $availablePools += $candidate
            Write-Host "  OPEN   $address" -ForegroundColor Green
        }
        else {
            Write-Host "  CLOSED $address" -ForegroundColor DarkYellow
        }
    }
    if ($availablePools.Count -eq 0) {
        throw 'None of the listed pool ports accepted a TCP connection. Check the network/firewall and run setup again.'
    }

    Write-Host ''
    Write-Host 'Choose a pool endpoint:'
    for ($i = 0; $i -lt $availablePools.Count; $i++) {
        $p = $availablePools[$i]
        $tlsLabel = if ($p.Tls) { 'TLS' } else { 'no TLS' }
        Write-Host (('{0}) {1} ({2}:{3}, {4})' -f ($i + 1), $p.Name, $p.Host, $p.Port, $tlsLabel)
    }

    $choiceText = Read-Host "Enter 1-$($availablePools.Count)"
    $choiceNumber = 0
    if (-not [int]::TryParse($choiceText, [ref]$choiceNumber) -or $choiceNumber -lt 1 -or $choiceNumber -gt $availablePools.Count) {
        throw 'Invalid pool choice.'
    }
    $pool = $availablePools[$choiceNumber - 1]

    $settings = [ordered]@{
        Wallet      = $wallet
        Worker      = $worker
        PoolHost    = [string]$pool.Host
        PoolPort    = [int]$pool.Port
        Tls         = [bool]$pool.Tls
        ThreadsHint = 75
    }
    $settings | ConvertTo-Json -Depth 3 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Host "Saved settings to $settingsPath" -ForegroundColor Green
    Write-Host 'The file contains your public receive address, not your wallet seed or private keys.' -ForegroundColor DarkGray
    return ([pscustomobject]$settings)
}

Write-Host 'Monero CPU Miner (XMRig)' -ForegroundColor Cyan
Write-Host 'Runs visibly in this window. No service or hidden background process is created.'

$settings = Read-OrCreateSettings
$wallet = [string]$settings.Wallet
$worker = [string]$settings.Worker
$poolAddress = '{0}:{1}' -f [string]$settings.PoolHost, [int]$settings.PoolPort
$tls = [bool]$settings.Tls
$threadsHint = [int]$settings.ThreadsHint
if ($threadsHint -lt 1 -or $threadsHint -gt 100) { $threadsHint = 75 }

$xmrigPath = Install-XmrigIfMissing

Write-Host ''
Write-Host 'Starting XMRig. Press Ctrl+C to stop mining.' -ForegroundColor Green
Write-Host "Pool:         $poolAddress"
Write-Host "TLS:          $tls"
Write-Host "Worker:       $worker"
Write-Host "Miner:        $xmrigPath"
Write-Host "Settings:     $settingsPath"
Write-Host 'The saved wallet and pool will be reused on the next launch.'
Write-Host ''

$minerArgs = @(
    '--coin', 'monero',
    '--url', $poolAddress,
    '--user', $wallet,
    '--pass', 'x',
    "--rig-id=$worker",
    '--cpu-max-threads-hint', [string]$threadsHint
)
if ($tls) { $minerArgs += '--tls' }

& $xmrigPath @minerArgs
$exitCode = $LASTEXITCODE

Write-Host ''
Write-Host "XMRig exited with code $exitCode."
