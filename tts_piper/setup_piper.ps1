# Instaleaza vocea romaneasca Piper pentru speak_forecast.m (Client 'piper' / 'auto').
# Nu cere drepturi de administrator. Ruleaza din PowerShell:
#   powershell -ExecutionPolicy Bypass -File tts_piper\setup_piper.ps1
#
# Rezultat (~230 MB): tts_piper\.venv (Python + piper-tts + onnxruntime)
#                     tts_piper\voices\ro_RO-mihai-medium.onnx (+ .json)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$venv = Join-Path $root '.venv'
$voices = Join-Path $root 'voices'

# Python 3.10-3.12: onnxruntime nu are inca roti pentru toate versiunile noi.
$py = $null
foreach ($v in '3.12', '3.11', '3.10') {
    try { & py "-$v" -c "import sys" 2>$null; if ($LASTEXITCODE -eq 0) { $py = @('py', "-$v"); break } } catch {}
}
if (-not $py) { throw 'Lipseste Python 3.10-3.12 (py launcher). Instaleaza-l de pe python.org.' }

if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
    & $py[0] $py[1] -m venv $venv
}
$vpy = Join-Path $venv 'Scripts\python.exe'
& $vpy -m pip install --quiet --upgrade pip
& $vpy -m pip install --quiet piper-tts

New-Item -ItemType Directory -Force $voices | Out-Null
$base = 'https://huggingface.co/rhasspy/piper-voices/resolve/main/ro/ro_RO/mihai/medium'
foreach ($f in 'ro_RO-mihai-medium.onnx.json', 'ro_RO-mihai-medium.onnx') {
    $dst = Join-Path $voices $f
    if (-not (Test-Path $dst)) { Invoke-WebRequest "$base/$f" -OutFile $dst }
}

$txt = Join-Path $env:TEMP 'piper_ro_test.txt'
$wav = Join-Path $env:TEMP 'piper_ro_test.wav'
[IO.File]::WriteAllText($txt, 'Test de voce în limba română.', [Text.UTF8Encoding]::new($false))
& $vpy (Join-Path $root 'piper_say.py') (Join-Path $voices 'ro_RO-mihai-medium.onnx') $txt $wav
if ($LASTEXITCODE -ne 0) { throw 'Testul Piper a esuat.' }
Write-Host "OK: vocea romaneasca functioneaza ($wav)."
