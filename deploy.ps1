# RemarkableAnimator One-Click Deployment Script
param (
    [string]$TargetIp = "10.11.99.1",   # USB address of every reMarkable; put your Wi-Fi IP in deploy.local.ps1
    [string]$FallbackIp = "10.11.99.1",
    [string]$Device,  # an SSH host from ~/.ssh/config instead of an IP, e.g. rm2
    [switch]$Restart  # also restart xochitl, which is what loads the new code (close the app first)
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$srcDir = Join-Path $scriptDir "src"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  RemarkableAnimator Deployment to Tablet  " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Optional machine-specific settings in deploy.local.ps1 (git-ignored), e.g.:
#   $TargetIp = "192.168.1.50"              # the tablet's Wi-Fi address
#   $askpass  = "C:\path\to\askpass.cmd"    # prints the root password, for non-interactive ssh
# Without an askpass, ssh simply prompts for the password.
$askpass = $null
$localConfig = Join-Path $scriptDir "deploy.local.ps1"
if (Test-Path $localConfig) { . $localConfig }
if ($askpass -and (Test-Path $askpass)) {
    $env:SSH_ASKPASS = $askpass
    $env:SSH_ASKPASS_REQUIRE = "force"
    $env:DISPLAY = "dummy"
}

# Every tablet is 10.11.99.1 over USB, each with its own host key and password: -Device names
# an SSH host that knows which one it is, so the IP check below is skipped
if ($Device) {
    $dest = $Device
} else {
    # Test connectivity
    $ip = $TargetIp
    Write-Host "Checking connection to $ip:22..." -NoNewline
    $tcp = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($ip, 22, $null, $null)
    $success = $async.AsyncWaitHandle.WaitOne(2000)

    if (-not $success) {
        Write-Host " TIMEOUT" -ForegroundColor Yellow
        Write-Host "Trying fallback USB IP $FallbackIp:22..." -NoNewline
        $ip = $FallbackIp
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($ip, 22, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne(2000)
        if (-not $success) {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Error "Could not connect to tablet at $TargetIp or $FallbackIp. Ensure Wi-Fi or USB cable is connected."
        }
    }
    Write-Host " CONNECTED ($ip)" -ForegroundColor Green
    $tcp.Close()
    $dest = "root@$ip"
}

# Target app directory on device
$remoteAppDir = "/home/root/xovi/exthome/appload/RemarkableAnimator"

Write-Host "Ensuring remote directory exists..."
ssh -o StrictHostKeyChecking=no $dest "mkdir -p $remoteAppDir /home/root/.local/share/remarkable-animator"  # app + saved animations

# A running backend can't be overwritten ("text file busy"); stop ours first
ssh -o StrictHostKeyChecking=no $dest 'for p in $(pidof entry); do readlink /proc/$p/exe | grep -q RemarkableAnimator && kill $p; done; true'

Write-Host "Copying files to $remoteAppDir..."
scp -o StrictHostKeyChecking=no -r "$srcDir/*" "${dest}:${remoteAppDir}/"

Write-Host "Setting executable permissions..."
ssh -o StrictHostKeyChecking=no $dest "chmod +x $remoteAppDir/backend/entry $remoteAppDir/backend/*/entry 2>/dev/null || true"

# reMarkable 2 only: the animator-ink XOVI extension inks the pen and eraser through xochitl's own
# fast pen path (extension/animator-ink.c). It loads when xochitl restarts and stays off on any
# other xochitl build. Swapped in by rename: overwriting the file xochitl has loaded can crash it.
$extDir = "/home/root/xovi/extensions.d"
ssh -o StrictHostKeyChecking=no $dest ('test $(uname -m) = armv7l || exit 0; ' +
    "cp $remoteAppDir/extension/animator-ink.so $extDir/.animator-ink.new && mv -f $extDir/.animator-ink.new $extDir/animator-ink.so && echo 'Installed the reMarkable 2 pen extension'")

# AppLoad caches the app's resources.rcc until xochitl restarts, so reopening the app still runs
# the old code. -Restart reloads xochitl; if a reboot wiped XOVI's tmpfs hook, xovi/start
# reinstalls it. Restarting xochitl while the app is open can crash it, hence opt-in.
if (-not $Restart) {
    Write-Host "Copied. Close the app on the tablet, then run .\deploy.ps1 -Restart to load it." -ForegroundColor Green
    exit 0
}
Write-Host "Reloading the tablet UI..."
ssh -o StrictHostKeyChecking=no $dest "if [ -f /etc/systemd/system/xochitl.service.d/00-xovi.conf ]; then systemctl restart xochitl; else bash /home/root/xovi/start; fi"

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Deployment Complete!                     " -ForegroundColor Green
Write-Host "  App is located at:                       " -ForegroundColor Green
Write-Host "  $remoteAppDir                            " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
