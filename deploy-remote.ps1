<#
.SYNOPSIS
  Deploy do servidor PXE no host remoto via SSH a partir do Windows.
  Usa plink.exe/pscp.exe (PuTTY) e faz sudo com a senha do usuario.

.DESCRIPTION
  Envia a pasta deste repo para o servidor e executa as etapas:
  install (01), download (02) e menu (03).

.EXAMPLE
  .\deploy-remote.ps1                 # tudo
  .\deploy-remote.ps1 install
  .\deploy-remote.ps1 download
  .\deploy-remote.ps1 menu

.NOTES
  Requer plink.exe e pscp.exe em -PuttyDir (ou no PATH).
#>
param(
  [ValidateSet('all','install','download','menu')][string]$Step = 'all',
  [string]$HostIP    = '192.168.0.200',
  [string]$User      = 'pxeuser',
  [string]$Pass      = '1q2w3e!@',
  [string]$RemoteDir = '/home/pxeuser/pxe-boot',
  [string]$HostKey   = '',
  [string]$PuttyDir  = "$env:LOCALAPPDATA\Temp\opencode\putty"
)

$ErrorActionPreference = 'Stop'
$LocalDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Parent   = $RemoteDir.Substring(0, $RemoteDir.LastIndexOf('/'))   # /home/pxeuser
$plink    = Join-Path $PuttyDir 'plink.exe'
$pscp     = Join-Path $PuttyDir 'pscp.exe'
if (!(Test-Path $plink) -or !(Test-Path $pscp)) { throw "plink.exe/pscp.exe nao encontrados em $PuttyDir" }
$target = "$User@$HostIP"

if (-not $HostKey) {
  $out = & $plink -ssh -batch -pw $Pass $target "exit" 2>&1 | Out-String
  if ($out -match 'SHA256:[A-Za-z0-9+/=]+') { $HostKey = $Matches[0] }
}
$hkArgs = @(); if ($HostKey) { $hkArgs = @('-hostkey', $HostKey) }

function Invoke-Root([string]$Cmd) { & $plink -ssh -batch @hkArgs -pw $Pass $target "echo '$Pass' | sudo -S bash -lc '$Cmd'" }
function Invoke-User([string]$Cmd) { & $plink -ssh -batch @hkArgs -pw $Pass $target $Cmd }

Write-Host "== Enviando arquivos para ${target}:$RemoteDir ==" -ForegroundColor Cyan
& $pscp -batch @hkArgs -pw $Pass -r $LocalDir "${target}:$Parent/" | Out-Null

if ($Step -in 'install','all')  { Write-Host "== install =="  -ForegroundColor Cyan; Invoke-Root "cd $RemoteDir && chmod +x *.sh && bash 01-install-pxe.sh" }
if ($Step -in 'download','all') { Write-Host "== download ==" -ForegroundColor Cyan; Invoke-Root "cd $RemoteDir && bash 02-download-isos.sh" }
if ($Step -in 'menu','all')     { Write-Host "== menu =="     -ForegroundColor Cyan; Invoke-Root "cd $RemoteDir && bash 03-setup-pxe-menu.sh" }

Write-Host "Concluido: http://$HostIP/distros/" -ForegroundColor Green
