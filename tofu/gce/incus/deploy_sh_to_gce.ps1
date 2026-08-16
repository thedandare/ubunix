#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string[]]$IPs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$port = 22

$remoteHome = '/home/fibodevop_gmail_com'
$remoteScript = "$remoteHome/ubunix-deploy.sh"

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Shell script not found: $ScriptPath"
}

$localScript = (Resolve-Path -LiteralPath $ScriptPath).Path

if ([IO.Path]::GetExtension($localScript) -ne '.sh') {
    throw "The input file must have a .sh extension: $ScriptPath"
}

$sshKey = Join-Path $env:USERPROFILE '.ssh/root_id_ed25519'
$sshCmd = Join-Path $env:WINDIR 'System32/OpenSSH/ssh.exe'
if (-not (Test-Path -LiteralPath $sshKey -PathType Leaf)) {
    throw "SSH key not found: $sshKey"
}

if (-not (Test-Path -LiteralPath $sshCmd -PathType Leaf)) {
    $sshCmd = 'ssh'
}

$sshOptions = @(
    '-i', $sshKey,
    '-p', $port,
    '-o', 'StrictHostKeyChecking=no'
)

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    & $sshCmd @sshOptions $HostName $Command
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed on $HostName with exit code $LASTEXITCODE."
    }
}

$scriptContent = Get-Content -LiteralPath $localScript -Raw

foreach ($ip in $IPs) {
    $sshHost = "root@$ip"

    Write-Host '========================================================='
    Write-Host " Executing $localScript on $sshHost"
    Write-Host '========================================================='

    Write-Host '=== Copying shell script to remote server ==='
    $scriptContent | & $sshCmd @sshOptions $sshHost "cat > $remoteScript"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy $localScript to $sshHost."
    }

    Write-Host '=== Executing shell script ==='
    Invoke-RemoteCommand -HostName $sshHost "chmod 700 $remoteScript && TERM=xterm-256color bash $remoteScript"

    Write-Host '=== Removing temporary shell script ==='
    Invoke-RemoteCommand -HostName $sshHost "rm -f $remoteScript"
}
