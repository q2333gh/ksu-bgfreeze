# Start bgfreeze-a16 headless on Y9 Win11. See docs/VM_TEST_ENV.md.
$ErrorActionPreference = "Stop"
$env:ANDROID_SDK_ROOT = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
$emu = Join-Path $env:ANDROID_SDK_ROOT "emulator\emulator.exe"
$dir = "C:\Users\12531\bgfreeze-avd"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$log = Join-Path $dir "emulator.log"
$err = Join-Path $dir "emulator.err"
$args = @(
  "-avd", "bgfreeze-a16",
  "-no-snapshot-load",
  "-no-audio",
  "-no-boot-anim",
  "-gpu", "swiftshader_indirect",
  "-no-window"
)
$p = Start-Process -FilePath $emu -ArgumentList $args -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $log -RedirectStandardError $err
"emu_pid=$($p.Id)" | Set-Content (Join-Path $dir "emu.pid")
Write-Output "emu_pid=$($p.Id)"
