# Windows smoke: build with MSVC, then encode and decode real Media Foundation output.
# REC_E2E_ARTIFACT_DIR keeps the recordings and probe reports; REC_E2E_CAPTURE=1 also
# records the real display.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-common.ps1')

$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('rec-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
$artifacts = if ($env:REC_E2E_ARTIFACT_DIR) { $env:REC_E2E_ARTIFACT_DIR } else { $tmp }
New-Item -ItemType Directory -Force $artifacts | Out-Null

try {
    $rec = Build-Rec $root (Join-Path $tmp 'build')

    function Expect-Failure([string]$pattern, [string[]]$arguments) {
        $run = Invoke-Rec $rec $arguments
        if ($run.Code -eq 0) { throw "accepted: rec $arguments" }
        if (-not $run.Text.Contains($pattern)) { throw "rec $arguments printed '$($run.Text)', expected '$pattern'" }
    }
    function Record([string]$name, [string]$file, [string[]]$arguments) {
        $path = Join-Path $artifacts $file
        $run = Invoke-Rec $rec (@('record') + $arguments + @('-o', $path))
        Set-Content -Path (Join-Path $artifacts "$name.record.log") -Value $run.Text
        Write-Host $run.Text
        if ($run.Code -ne 0) { throw "rec record $arguments failed" }
        $probe = Get-Probe $rec $path (Join-Path $artifacts "$name.probe")
        return @{ Log = $run.Text; Probe = $probe }
    }

    if (-not (Invoke-Rec $rec @('--help')).Text.Contains('native screen recorder')) { throw 'help text' }
    Expect-Failure 'fps must be' @('record', '--fps', 'invalid')
    Expect-Failure 'resolution must be' @('record', '--resolution', 'gigantic')
    Expect-Failure 'requires --test-pattern' @('record', '--test-tone')
    Expect-Failure 'requires --test-pattern' @('record', '--test-mic')
    Expect-Failure 'needs a real screen' @('record', '--test-pattern', '--system-audio')
    Expect-Failure 'needs a real screen' @('record', '--test-pattern', '--mic', 'default')
    Expect-Failure 'audio tracks must be' @('record', '--audio-tracks', 'surround')
    Expect-Failure 'gain must be' @('record', '--mic-gain', '99')
    Expect-Failure 'offset must be' @('record', '--system-audio-offset-ms', '5000')

    # The live A/V sync stimulus must at least compile.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'flash-beep.ps1') -CheckOnly
    if ($LASTEXITCODE -ne 0) { throw 'flash-beep.ps1 does not compile' }

    # Media Foundation encode and decode without capture.
    $h264 = Record 'h264' 'h264.mp4' @('--test-pattern', '-r', '1080p', '-f', '30', '-t', '2', '--codec', 'h264')
    Expect-Field $h264.Probe 'codec' 'h264'
    Expect-Field $h264.Probe 'width' '1920'
    Expect-Field $h264.Probe 'height' '1080'
    Expect-Field $h264.Probe 'frames' '60'
    Expect-Field $h264.Probe 'audio_tracks' '0'
    Expect-Text $h264.Log 'written 60, dropped 0'

    # Flash + beep through the AAC encoder: measured A/V offset in the decoded file.
    $av = Record 'av' 'av.mp4' @('--test-pattern', '--test-tone', '-r', '1080p', '-f', '30', '-t', '2', '--codec', 'h264')
    Expect-Field $av.Probe 'frames' '60'
    Expect-Field $av.Probe 'audio_tracks' '1'
    Expect-Field $av.Probe 'audio_codec' 'aac'
    Expect-Text $av.Log 'written 60, dropped 0'
    Expect-Within $av.Probe 'audio_duration' 1.95 2.05
    Expect-Within $av.Probe 'av_sync_events' 2 2
    Expect-Within $av.Probe 'av_offset_max_ms' 0 20

    # A system-audio offset moves audio later by exactly that much.
    $offset = Record 'offset' 'offset.mp4' @('--test-pattern', '--test-tone', '--system-audio-offset-ms', '100', '-f', '30', '-t', '2')
    Expect-Within $offset.Probe 'av_sync_events' 2 2
    Expect-Within $offset.Probe 'av_offset_ms' 80 120

    # Mixer: default track is the system + mic mix, followed by both stems.
    $mix = Record 'mix' 'mix.mov' @('--test-pattern', '--test-tone', '--test-mic', '-f', '30', '-t', '2')
    Expect-Field $mix.Probe 'audio_tracks' '3'
    Expect-Field $mix.Probe 'audio_codec' 'aac'
    Expect-Text $mix.Log 'Mix buffers written'
    Expect-Text $mix.Log 'written 60, dropped 0'
    Expect-Within $mix.Probe 'audio_duration' 1.95 2.05
    Expect-Within $mix.Probe 'av_sync_events' 2 2
    Expect-Within $mix.Probe 'av_offset_max_ms' 0 20

    $stems = Record 'stems' 'stems.mp4' @('--test-pattern', '--test-tone', '--test-mic', '--audio-tracks', 'stems', '-f', '30', '-t', '1')
    Expect-Field $stems.Probe 'audio_tracks' '2'
    $mixonly = Record 'mixonly' 'mixonly.mp4' @('--test-pattern', '--test-tone', '--test-mic', '--audio-tracks', 'mix', '-f', '30', '-t', '1')
    Expect-Field $mixonly.Probe 'audio_tracks' '1'

    # Pause/resume through piped stdin: paused time is cut from the movie, A/V stays in sync.
    $pausePath = Join-Path $artifacts 'pause.mp4'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $run = Start-RecProcess $rec @('record', '--test-pattern', '--test-tone', '--test-mic', '-f', '30', '-t', '3', '-o', $pausePath)
    Start-Sleep -Milliseconds 1000
    Send-RecCommand $run 'pause'
    Start-Sleep -Milliseconds 1500
    Send-RecCommand $run 'resume'
    $paused = Stop-RecProcess $run
    $watch.Stop()
    Set-Content -Path (Join-Path $artifacts 'pause.record.log') -Value $paused.Text
    Write-Host $paused.Text
    if ($paused.Code -ne 0) { throw "paused recording failed: $($paused.Text)" }
    Expect-Text $paused.Text 'Paused at'
    Expect-Text $paused.Text 'Resumed at'
    Expect-Text $paused.Text 'written 90, dropped 0'
    Expect-Text $paused.Text 'not in the movie'
    if ($watch.Elapsed.TotalSeconds -lt 4.2) { throw "pause did not hold the recording ($($watch.Elapsed.TotalSeconds) s)" }
    $pause = Get-Probe $rec $pausePath (Join-Path $artifacts 'pause.probe')
    Expect-Field $pause 'frames' '90'
    Expect-Field $pause 'audio_tracks' '3'
    Expect-Within $pause 'audio_duration' 2.95 3.05
    Expect-Within $pause 'av_sync_events' 3 3
    Expect-Within $pause 'av_offset_max_ms' 0 20

    # Crash safety: a recording killed mid-write still decodes up to its last fragment.
    $crashPath = Join-Path $artifacts 'crash.mp4'
    $run = Start-RecProcess $rec @('record', '--test-pattern', '--test-tone', '-f', '30', '-t', '0', '--codec', 'h264', '-o', $crashPath)
    Start-Sleep -Seconds 4
    $run.Process.Kill()
    $run.Process.WaitForExit()
    $crash = Get-Probe $rec $crashPath (Join-Path $artifacts 'crash.probe')
    Expect-Within $crash 'frames' 60 120
    Expect-Within $crash 'av_sync_events' 2 4
    Expect-Within $crash 'av_offset_max_ms' 0 20
    # HEVC needs a hardware encoder or the HEVC Video Extensions; GPU-less CI runners have neither.
    $hevcPath = Join-Path $artifacts 'hevc.mp4'
    $hevcRun = Invoke-Rec $rec @('record', '--test-pattern', '-r', '1080p', '-f', '30', '-t', '1', '--codec', 'hevc', '-o', $hevcPath)
    if ($hevcRun.Code -ne 0 -and $hevcRun.Text.Contains('HEVC encoder')) {
        Write-Host "HEVC skipped: $($hevcRun.Text)"
    } else {
        if ($hevcRun.Code -ne 0) { throw "HEVC recording failed: $($hevcRun.Text)" }
        $hevc = Get-Probe $rec $hevcPath (Join-Path $artifacts 'hevc.probe')
        Expect-Field $hevc 'codec' 'hevc'
        Expect-Field $hevc 'height' '1080'
        Expect-Field $hevc 'frames' '30'
        Expect-Text $hevcRun.Text 'written 30, dropped 0'
    }

    Expect-Failure 'already exists' @('record', '--test-pattern', '-t', '1', '-o', (Join-Path $artifacts 'h264.mp4'))
    Expect-Field (Get-Probe $rec (Join-Path $artifacts 'h264.mp4') (Join-Path $tmp 'recheck.probe')) 'frames' '60'

    if ($env:REC_E2E_CAPTURE -eq '1') {
        $screen = Record 'screen' 'screen.mp4' @('--display', '1', '-r', '1080p', '-f', '30', '-t', '3', '--codec', 'h264')
        Expect-Field $screen.Probe 'codec' 'h264'
        Expect-Field $screen.Probe 'frames' '90'
    }
    Write-Host 'smoke passed'
} finally {
    if ($artifacts -ne $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
