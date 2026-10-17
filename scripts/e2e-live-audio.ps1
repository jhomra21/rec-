# Live A/V sync acceptance on a Windows PC with audible output. A full-screen window
# flashes white with a simultaneous beep once a second while rec records the primary
# display and system audio; rec probe then measures the offset in the file.
# REC_E2E_MIC=1 also records the default microphone (mix + stems).
# REC_E2E_PAUSE=1 pauses for 2 s in the middle of the stimulus: the movie must keep its
# full length and stay in sync across the cut.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-common.ps1')

$root = Split-Path -Parent $PSScriptRoot
$artifacts = if ($env:REC_E2E_ARTIFACT_DIR) { $env:REC_E2E_ARTIFACT_DIR } else {
    Join-Path ([IO.Path]::GetTempPath()) ('rec-live-sync-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Force $artifacts | Out-Null
$rec = Build-Rec $root (Join-Path $root 'build')
$movie = Join-Path $artifacts 'recording.mp4'
$pause = $env:REC_E2E_PAUSE -eq '1'

$arguments = @('record', '--display', '1', '--system-audio', '-r', '1080p', '-f', '60', '-t', '12', '--codec', 'h264', '-o', $movie)
if ($env:REC_E2E_MIC -eq '1') { $arguments += @('--mic', 'default') }

Write-Host "Saving recordings and evidence to: $artifacts"
(Invoke-Rec $rec @('devices')).Text | Tee-Object -FilePath (Join-Path $artifacts 'devices.txt')
$run = Start-RecProcess $rec $arguments
$stimulus = $null
try {
    # Allow the recorder to establish its capture streams and first video frame.
    Start-Sleep -Seconds 3
    if ($run.Process.HasExited) { throw "Recording stopped before the stimulus: $((Stop-RecProcess $run).Text)" }
    $seconds = if ($pause) { 8 } else { 6 }
    $stimulus = Start-Process -FilePath powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'flash-beep.ps1'), '-Seconds', $seconds)
    if ($pause) {
        Start-Sleep -Milliseconds 3500
        Send-RecCommand $run 'pause'
        Start-Sleep -Seconds 2
        Send-RecCommand $run 'resume'
    }
    $stimulus.WaitForExit()
    if ($stimulus.ExitCode -ne 0) { throw 'stimulus failed' }
} finally {
    if ($stimulus -and -not $stimulus.HasExited) { $stimulus.Kill() }
}
$result = Stop-RecProcess $run 90
Set-Content -Path (Join-Path $artifacts 'record.log') -Value $result.Text
Write-Host $result.Text
if ($result.Code -ne 0) { throw "Recorder failed; see $artifacts\record.log" }

$probe = Get-Probe $rec $movie (Join-Path $artifacts 'recording.probe')
Expect-Field $probe 'codec' 'h264'
Expect-Field $probe 'audio_codec' 'aac'
Expect-Field $probe 'frames' '720'
Expect-Within $probe 'audio_duration' 11.95 12.05
if ($env:REC_E2E_MIC -eq '1') { Expect-Field $probe 'audio_tracks' '3' }
if ($pause) { Expect-Text $result.Text 'not in the movie' }
$events = [int]$probe['av_sync_events']
if ($events -lt 4) { throw "only $events flash/beep pairs found" }
# ITU-R BT.1359 detectability: audio more than 45 ms early or 125 ms late.
Expect-Within $probe 'av_offset_ms' -45 125

Write-Host "Live A/V sync: $events flash/beep pairs, mean offset $($probe['av_offset_ms']) ms (positive = audio late), worst $($probe['av_offset_max_ms']) ms."
Write-Host "Evidence: $artifacts"
