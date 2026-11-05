#requires -Version 5.1
<# Dependency-free regression suite. FFmpeg tests require ffmpeg on PATH. #>
[CmdletBinding()]
param([switch]$RequireFFmpeg)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'MediaMosaic.psm1') -Force
$module = Get-Module MediaMosaic
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('MediaMosaic-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:passed = 0
$script:failed = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected an exception'
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $caught"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`n$_`n$($_.ScriptStackTrace)" -ForegroundColor Red }
}
function New-TestFolder([string]$Name) {
    $path = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function New-TestImage([string]$Path, [int]$Width = 40, [int]$Height = 20) {
    $bitmap = [Drawing.Bitmap]::new($Width, $Height)
    $graphics = $null
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::CornflowerBlue)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally { if ($graphics) { $graphics.Dispose() }; $bitmap.Dispose() }
}
function Assert-Unlocked([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
}
function Invoke-TestMosaic([string]$InputPath, [string]$OutputPath, [hashtable]$Options = @{}) {
    Invoke-MediaMosaic -RootFolder $InputPath -OutputFile $OutputPath @Options
}
function New-FFmpegFixture([string[]]$Arguments) {
    $messages = & $script:ffmpeg.Source -hide_banner -loglevel error @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Fixture creation failed: $messages" }
}

function New-TestDecoder {
    $folder = New-TestFolder 'decoder [stub]'
    $source = Join-Path $folder 'Decoder.cs'
    $executable = Join-Path $folder 'Decoder.exe'
    @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
class Decoder {
    static int Main(string[] args) {
        if (args[0] == "--echo") {
            for (int i = 1; i < args.Length; i++)
                Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
            return 0;
        }
        string input = args[Array.IndexOf(args, "-i") + 1];
        string mode = File.ReadAllText(input).Trim();
        File.WriteAllText(input + ".pid", Process.GetCurrentProcess().Id.ToString());
        if (mode == "success") {
            File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "frame.png"), args[args.Length - 1]);
            return 0;
        }
        if (mode == "diagnostics") {
            Console.Error.Write(new string('e', 131072));
            Console.Out.Write(new string('o', 131072));
            return 17;
        }
        if (mode == "fallback") {
            string seek = args[Array.IndexOf(args, "-ss") + 1];
            Thread.Sleep(600);
            if (seek != "3")
                File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "frame.png"), args[args.Length - 1]);
            return 0;
        }
        File.WriteAllText(args[args.Length - 1], "partial frame");
        Thread.Sleep(30000);
        return 0;
    }
}
'@ | Set-Content -LiteralPath $source -Encoding UTF8
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $messages = & $compiler /nologo /target:exe "/out:$executable" $source 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not compile decoder fixture: $messages" }
    $frame = [Drawing.Bitmap]::new(16, 16)
    try { $frame.Save((Join-Path $folder 'frame.png'), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $frame.Dispose() }
    return $executable
}

function Assert-DecoderStopped([string]$InputPath) {
    $decoderPid = [int](Get-Content -LiteralPath ($InputPath + '.pid'))
    Assert-True ($null -eq (Get-Process -Id $decoderPid -ErrorAction SilentlyContinue)) 'Timed-out decoder was terminated'
}

function Start-ProgressCapture {
    & $module {
        $script:CapturedProgress = [Collections.Generic.List[hashtable]]::new()
        function script:Write-Progress {
            param($Id, $Activity, $Status, $CurrentOperation, $PercentComplete, [switch]$Completed)
            $script:CapturedProgress.Add(@{
                Id = $Id; Activity = $Activity; Status = $Status; CurrentOperation = $CurrentOperation
                PercentComplete = $PercentComplete; Completed = [bool]$Completed
            })
        }
    }
}
function Stop-ProgressCapture {
    & $module {
        Remove-Item Function:Write-Progress
        Remove-Variable -Name CapturedProgress -Scope Script
    }
}

try {
    Test-Case 'JPEG renders, nested output is created, and resources are released' {
        $inputPath = New-TestFolder 'basic'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        $result = Invoke-TestMosaic $inputPath (Join-Path $testRoot 'new\nested\sheet.jpg')
        Assert-True ($result.Discovered -eq 1 -and $result.Rendered -eq 1 -and $result.Failed -eq 0) 'Accurate summary'
        Assert-True ($result.Sheets.Count -eq 1) 'One sheet'
        $image = [Drawing.Image]::FromFile($result.Sheets[0])
        try { Assert-True ($image.Width -eq 1120 -and $image.Height -eq 300) 'Canvas contains exactly one row' }
        finally { $image.Dispose() }
        Assert-Unlocked $source; Assert-Unlocked $result.Sheets[0]
    }
    Test-Case 'brackets, spaces, apostrophes and Unicode use literal paths' {
        $inputPath = New-TestFolder "photos[2026] O'Brien $([char]0x03A9)"
        New-TestImage (Join-Path $inputPath 'photo[1].jpg')
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'out[1].jpg')
        Assert-True ($result.Rendered -eq 1) 'Literal source/output names work'
    }
    Test-Case 'native image formats render while unrelated extensions are ignored' {
        $inputPath = New-TestFolder 'native-formats'
        $bitmap = [Drawing.Bitmap]::new(40, 20)
        try {
            $bitmap.Save((Join-Path $inputPath 'image.png'), [Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Save((Join-Path $inputPath 'image.gif'), [Drawing.Imaging.ImageFormat]::Gif)
            $bitmap.Save((Join-Path $inputPath 'image.bmp'), [Drawing.Imaging.ImageFormat]::Bmp)
            $bitmap.Save((Join-Path $inputPath 'image.jpeg'), [Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally { $bitmap.Dispose() }
        Set-Content -LiteralPath (Join-Path $inputPath 'ignored.jpg.backup') -Value 'text'
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($result.Discovered -eq 4 -and $result.Rendered -eq 4) 'All native formats render'
    }
    Test-Case 'relative output filenames resolve against the current filesystem location' {
        $inputPath = New-TestFolder 'relative'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        Push-Location -LiteralPath $inputPath
        try {
            $result = Invoke-MediaMosaic -RootFolder '.' -OutputFile 'sheet.jpeg'
            Assert-True ($result.Rendered -eq 1 -and (Test-Path -LiteralPath $result.Sheets[0])) 'Relative output succeeds'
        }
        finally { Pop-Location }
    }
    Test-Case 'corrupt files retain cells and report the underlying error' {
        $inputPath = New-TestFolder 'corrupt'
        New-TestImage (Join-Path $inputPath 'valid.jpg')
        Set-Content -LiteralPath (Join-Path $inputPath 'broken.jpg') -Value 'not an image'
        $warnings = @()
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue -WarningVariable warnings
        $records = @(Import-Csv -LiteralPath $result.IndexPath)
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 1 -and $records.Count -eq 2) 'No silently omitted input'
        Assert-True ($records[0].Status -eq 'Failed' -and $records[0].Error.Length -gt 0) 'Detailed failure in CSV'
        Assert-True ($warnings.Count -eq 1 -and "$($warnings[0])" -match 'broken.jpg') 'Detailed warning'
        Assert-True ($records[0].Cell -eq 1 -and $records[1].Cell -eq 2) 'Stable placeholder positions'
    }
    Test-Case 'entirely failed sheets still have a thumbnail row' {
        $inputPath = New-TestFolder 'all-failed'
        Set-Content -LiteralPath (Join-Path $inputPath 'broken.jpg') -Value 'not an image'
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue
        $image = [Drawing.Image]::FromFile($result.Sheets[0])
        try { Assert-True ($image.Height -eq 300 -and $result.Failed -eq 1) 'Failed input has a visible cell' }
        finally { $image.Dispose() }
    }
    Test-Case 'reruns exclude generated sheets and remove only manifest-owned surplus pages' {
        $inputPath = New-TestFolder 'rerun'
        1..5 | ForEach-Object { New-TestImage (Join-Path $inputPath "$_.jpg") }
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output @{ FilesPerSheet = 2 }
        Assert-True ($first.Sheets.Count -eq 3) 'Three initial pages'
        # A similarly named pre-existing file was never recorded as our output.
        $unowned = Join-Path $inputPath 'sheet-99.jpg'; New-TestImage $unowned
        $second = Invoke-TestMosaic $inputPath $output
        Assert-True ($second.Discovered -eq 5 -and $second.Sheets.Count -eq 1) 'Outputs never become inputs'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inputPath 'sheet-2.jpg'))) 'Obsolete page two removed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inputPath 'sheet-3.jpg'))) 'Obsolete page three removed'
        Assert-True (Test-Path -LiteralPath $unowned) 'Unowned matching filename preserved'
    }
    Test-Case 'empty input returns zero counts and reconciles previous outputs' {
        $inputPath = New-TestFolder 'empty'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        $first = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Remove-Item -LiteralPath $source
        $empty = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($empty.Discovered -eq 0 -and $empty.Sheets.Count -eq 0) 'Empty summary'
        Assert-True (-not (Test-Path -LiteralPath $first.Sheets[0])) 'Owned stale page removed'
        Assert-True (@(Import-Csv -LiteralPath $empty.IndexPath).Count -eq 0) 'Empty CSV retains its schema'
    }
    Test-Case 'abandoned private staging files never become media inputs' {
        $inputPath = New-TestFolder 'abandoned'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $staging = Join-Path $inputPath ('.mediamosaic-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        New-TestImage (Join-Path $staging 'sheet-1.jpg')
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($result.Discovered -eq 1) 'Private staging excluded'
        Assert-True (Test-Path -LiteralPath $staging) 'Abandoned files are not deleted automatically'
    }
    Test-Case 'missing and non-directory roots throw' {
        Assert-Throws { Invoke-TestMosaic (Join-Path $testRoot 'missing') (Join-Path $testRoot 'missing.jpg') }
        $file = Join-Path $testRoot 'file.txt'; Set-Content -LiteralPath $file -Value 'text'
        Assert-Throws { Invoke-TestMosaic $file (Join-Path $testRoot 'file.jpg') } 'directory'
    }
    Test-Case 'invalid numeric options and output extensions are rejected' {
        $inputPath = New-TestFolder 'invalid-options'
        foreach ($option in @('FilesPerSheet', 'Columns', 'ThumbWidth', 'ThumbHeight', 'HeaderHeight', 'TextHeight', 'FFmpegTimeoutSeconds')) {
            $options = @{}; $options[$option] = 0
            Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') $options }
        }
        Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ Padding = -1 } }
        Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.png') } 'extension'
        Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ FFmpegTimeoutSeconds = 3601 } }
    }
    Test-Case 'progress reports files across sheets, counts failed previews, and completes' {
        $inputPath = New-TestFolder 'progress'
        New-TestImage (Join-Path $inputPath 'a.jpg')
        Set-Content -LiteralPath (Join-Path $inputPath 'b.jpg') -Value 'invalid image'
        Start-ProgressCapture
        try {
            $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -FilesPerSheet 1 -WarningAction SilentlyContinue
            $events = @(& $module { $script:CapturedProgress.ToArray() })
            Assert-True ($events[0].Status -match 'Scanning media') 'Discovery progress'
            Assert-True (@($events | Where-Object CurrentOperation -eq 'a.jpg').Count -gt 0) 'Current filename reported'
            Assert-True (@($events | Where-Object Status -match 'Sheet 2/2.*2/2 processed.*elapsed').Count -gt 0) 'Global counts include failure and elapsed time'
            Assert-True (@($events | Where-Object Status -match 'Publishing outputs').Count -gt 0) 'Publishing stage reported'
            Assert-True ($events[-1].Completed -and $result.Failed -eq 1) 'Progress completed after partial failure'
            $percents = @($events | Where-Object { -not $_.Completed -and $_.PercentComplete -ge 0 } | ForEach-Object { $_.PercentComplete })
            for ($i = 1; $i -lt $percents.Count; $i++) {
                Assert-True ($percents[$i] -ge $percents[$i - 1] -and $percents[$i] -le 99) 'Progress remains monotonic until publishing completes'
            }
        }
        finally { Stop-ProgressCapture }
    }
    Test-Case 'progress clears on fatal errors and empty inputs, and NoProgress suppresses it' {
        $inputPath = New-TestFolder 'progress-completion'
        Start-ProgressCapture
        try {
            Assert-Throws { Invoke-TestMosaic (Join-Path $testRoot 'absent') (Join-Path $inputPath 'sheet.jpg') }
            Assert-True (& $module { $script:CapturedProgress[$script:CapturedProgress.Count - 1].Completed }) 'Cleared after fatal error'
            & $module { $script:CapturedProgress.Clear() }
            $empty = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
            Assert-True ($empty.Discovered -eq 0) 'Empty input completes normally'
            Assert-True (& $module { $script:CapturedProgress[$script:CapturedProgress.Count - 1].Completed }) 'Cleared after empty input'
            & $module { $script:CapturedProgress.Clear() }
            New-TestImage (Join-Path $inputPath 'photo.jpg')
            $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ NoProgress = $true }
            Assert-True ($result.Rendered -eq 1) 'Suppression does not affect rendering'
            Assert-True ((& $module { $script:CapturedProgress.Count }) -eq 0) 'No progress events when suppressed'
        }
        finally { Stop-ProgressCapture }
    }
    $decoder = New-TestDecoder
    Test-Case 'cache stores scaled PNGs, reuses them, and releases source/cache locks' {
        $inputPath = New-TestFolder 'cache-basic'
        $source = Join-Path $inputPath 'large.jpg'; New-TestImage $source 800 600
        $output = Join-Path $inputPath 'sheet.jpg'
        $cold = Invoke-TestMosaic $inputPath $output
        Assert-True ($cold.CacheHits -eq 0 -and $cold.CacheMisses -eq 1) 'Cold run counts'
        $entries = @(Get-ChildItem -LiteralPath $cold.CacheFolder -File)
        Assert-True ($entries.Count -eq 1 -and $entries[0].Name -match '^[a-f0-9]{64}\.png$') 'Hashed PNG cache entry'
        $image = [Drawing.Image]::FromFile($entries[0].FullName)
        try { Assert-True ($image.Width -eq 240 -and $image.Height -eq 180) 'Cache stores an aspect-fitted thumbnail, not a full-size image' }
        finally { $image.Dispose() }
        $before = (Get-FileHash -LiteralPath $cold.Sheets[0]).Hash
        $warm = Invoke-TestMosaic $inputPath $output
        Assert-True ($warm.Discovered -eq 1 -and $warm.CacheHits -eq 1 -and $warm.CacheMisses -eq 0) 'Cache is reused and never becomes input'
        Assert-True ((Get-FileHash -LiteralPath $warm.Sheets[0]).Hash -eq $before) 'Warm and cold sheets have identical pixels/encoding'
        Assert-Unlocked $source; Assert-Unlocked $entries[0].FullName
    }
    Test-Case 'source timestamp and size changes independently invalidate the cache' {
        $inputPath = New-TestFolder 'cache-metadata'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output
        $timestamp = [IO.File]::GetLastWriteTimeUtc($source).AddSeconds(10)
        [IO.File]::SetLastWriteTimeUtc($source, $timestamp)
        $changedTime = Invoke-TestMosaic $inputPath $output
        Assert-True ($changedTime.CacheHits -eq 0 -and $changedTime.CacheMisses -eq 1) 'Timestamp invalidation'
        $stream = [IO.File]::OpenWrite($source)
        try { [void]$stream.Seek(0, [IO.SeekOrigin]::End); $stream.WriteByte(0) }
        finally { $stream.Dispose() }
        [IO.File]::SetLastWriteTimeUtc($source, $timestamp)
        $changedSize = Invoke-TestMosaic $inputPath $output
        Assert-True ($changedSize.Rendered -eq 1 -and $changedSize.CacheHits -eq 0 -and $changedSize.CacheMisses -eq 1) 'Size invalidation even with identical timestamp'
    }
    Test-Case 'thumbnail dimensions invalidate entries while layout-only changes reuse them' {
        $inputPath = New-TestFolder 'cache-settings'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $cold = Invoke-TestMosaic $inputPath $output
        $dimensions = Invoke-TestMosaic $inputPath $output @{ ThumbWidth = 200; ThumbHeight = 120 }
        Assert-True ($dimensions.CacheHits -eq 0 -and $dimensions.CacheMisses -eq 1) 'New dimensions require new preview'
        $layout = Invoke-TestMosaic $inputPath $output @{ ThumbWidth = 200; ThumbHeight = 120; Columns = 2; Padding = 20; FFmpegTimeoutSeconds = 45 }
        Assert-True ($layout.CacheHits -eq 1 -and $layout.CacheMisses -eq 0) 'Layout and timeout do not change preview pixels'
    }
    Test-Case 'custom literal cache folders and the default cache are excluded from discovery' {
        $inputPath = New-TestFolder 'cache-custom'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $custom = Join-Path $inputPath "thumbs[1] O'Brien"
        [IO.Directory]::CreateDirectory($custom) | Out-Null
        New-TestImage (Join-Path $custom 'unrelated.jpg')
        $default = Join-Path $inputPath '.mediamosaic-cache'
        [IO.Directory]::CreateDirectory($default) | Out-Null
        New-TestImage (Join-Path $default 'old.jpg')
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ CacheFolder = $custom }
        Assert-True ($result.Discovered -eq 1 -and $result.CacheFolder -eq $custom) 'Both cache roots excluded'
        Assert-True (Test-Path -LiteralPath (Join-Path $custom 'unrelated.jpg')) 'Unrelated cache-folder content is preserved'
        $warm = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ CacheFolder = $custom }
        Assert-True ($warm.CacheHits -eq 1) 'Literal custom path reused'
    }
    Test-Case 'NoCache bypasses reads and writes and does not create a cache directory' {
        $inputPath = New-TestFolder 'cache-disabled'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $uncached = Invoke-TestMosaic $inputPath $output @{ NoCache = $true }
        Assert-True ($null -eq $uncached.CacheFolder -and $uncached.CacheHits -eq 0 -and $uncached.CacheMisses -eq 0) 'Disabled counters'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inputPath '.mediamosaic-cache'))) 'No directory created'
        $cold = Invoke-TestMosaic $inputPath $output
        $entry = Get-ChildItem -LiteralPath $cold.CacheFolder -File
        Set-Content -LiteralPath $entry.FullName -Value 'corrupt cache'
        $before = (Get-FileHash -LiteralPath $entry.FullName).Hash
        $bypassed = Invoke-TestMosaic $inputPath $output @{ NoCache = $true; RefreshCache = $true }
        Assert-True ($bypassed.Rendered -eq 1 -and $bypassed.Discovered -eq 1) 'Cache bypassed but still excluded from scan'
        Assert-True ((Get-FileHash -LiteralPath $entry.FullName).Hash -eq $before) 'Existing cache left untouched'
    }
    Test-Case 'RefreshCache rebuilds current entries and corrupt cache files self-heal' {
        $inputPath = New-TestFolder 'cache-refresh'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output
        $refresh = Invoke-TestMosaic $inputPath $output @{ RefreshCache = $true }
        Assert-True ($refresh.CacheHits -eq 0 -and $refresh.CacheMisses -eq 1) 'Refresh bypasses cache reads'
        $entry = Get-ChildItem -LiteralPath $first.CacheFolder -File
        Set-Content -LiteralPath $entry.FullName -Value 'not PNG'
        $healed = Invoke-TestMosaic $inputPath $output
        Assert-True ($healed.Rendered -eq 1 -and $healed.CacheHits -eq 0 -and $healed.CacheMisses -eq 1) 'Corruption rebuilt'
        $warm = Invoke-TestMosaic $inputPath $output
        Assert-True ($warm.CacheHits -eq 1) 'Rebuilt entry reusable'
        Assert-True (@(Get-ChildItem -LiteralPath $first.CacheFolder -Filter '*.tmp').Count -eq 0) 'No temporary writes leaked'
    }
    Test-Case 'cache errors warn without turning readable media into failed previews' {
        $inputPath = New-TestFolder 'cache-errors'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $blocked = Join-Path $inputPath 'blocked-cache'; Set-Content -LiteralPath $blocked -Value 'file blocking directory creation'
        $warnings = @()
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile $output -CacheFolder $blocked -WarningAction SilentlyContinue -WarningVariable warnings
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 0 -and $null -eq $result.CacheFolder -and $warnings.Count -eq 1) 'Initialization error falls back to uncached rendering'
        $cold = Invoke-TestMosaic $inputPath $output
        $entry = Get-ChildItem -LiteralPath $cold.CacheFolder -File
        Remove-Item -LiteralPath $entry.FullName
        [IO.Directory]::CreateDirectory($entry.FullName) | Out-Null
        $warnings = @()
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile $output -WarningAction SilentlyContinue -WarningVariable warnings
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 0 -and $warnings.Count -eq 1) 'Cache write error does not hide the preview'
        Assert-True (@(Get-ChildItem -LiteralPath $cold.CacheFolder -Filter '*.tmp').Count -eq 0) 'Temporary write cleaned after error'
    }
    Test-Case 'cache folders cannot swallow source or output directories' {
        $inputPath = New-TestFolder 'cache-validation'
        $output = Join-Path $inputPath 'out\sheet.jpg'
        Assert-Throws { Invoke-TestMosaic $inputPath $output @{ CacheFolder = $inputPath } } 'dedicated directory'
        Assert-Throws { Invoke-TestMosaic $inputPath $output @{ CacheFolder = (Join-Path $inputPath 'out') } } 'dedicated directory'
        Assert-Throws { Invoke-TestMosaic $inputPath $output @{ CacheFolder = $testRoot } } 'dedicated directory'
    }
    Test-Case 'discovery does not follow directory junctions outside the source tree' {
        $inputPath = New-TestFolder 'cache-junction'
        $outside = New-TestFolder 'junction-target'
        New-TestImage (Join-Path $inputPath 'source.jpg')
        New-TestImage (Join-Path $outside 'outside.jpg')
        $junction = Join-Path $inputPath 'linked'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg')
        Assert-True ($result.Discovered -eq 1) 'Nested directory links are not traversed'
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'outside.jpg')) 'Linked target is unchanged'
    }
    Test-Case 'video and WebP cache hits skip decoder execution, and decoder settings invalidate them' {
        $inputPath = New-TestFolder 'cache-decoder'
        foreach ($name in @('clip.mp4', 'image.webp')) { Set-Content -LiteralPath (Join-Path $inputPath $name) -Value 'success' }
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output @{ FFmpeg = $decoder }
        Assert-True ($first.Rendered -eq 2 -and $first.CacheMisses -eq 2) 'Both media types cached'
        foreach ($name in @('clip.mp4.pid', 'image.webp.pid')) { Remove-Item -LiteralPath (Join-Path $inputPath $name) }
        $warm = & (Join-Path $repo 'MediaMosaic.ps1') -RootFolder $inputPath -OutputFile $output -FFmpeg $decoder -NoProgress
        $script:module = Get-Module MediaMosaic
        Assert-True ($warm.CacheHits -eq 2 -and $warm.CacheMisses -eq 0) 'CLI uses the warmed cache'
        Assert-True (@(Get-ChildItem -LiteralPath $inputPath -Filter '*.pid').Count -eq 0) 'No decoder was started'
        $changed = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile $output -FFmpeg 'mediamosaic-missing-decoder' -WarningAction SilentlyContinue
        Assert-True ($changed.CacheHits -eq 0 -and $changed.Failed -eq 2) 'A changed decoder setting does not reuse stale previews'
    }
    Test-Case 'failed previews are not cached and can recover on a later run' {
        $inputPath = New-TestFolder 'cache-failure'
        $source = Join-Path $inputPath 'photo.jpg'; Set-Content -LiteralPath $source -Value 'corrupt media'
        $output = Join-Path $inputPath 'sheet.jpg'
        $failed = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile $output -WarningAction SilentlyContinue
        Assert-True ($failed.Failed -eq 1 -and $failed.CacheMisses -eq 1) 'Failure counts as a miss'
        Assert-True (@(Get-ChildItem -LiteralPath $failed.CacheFolder -File).Count -eq 0) 'No failure placeholder stored in cache'
        New-TestImage $source
        $recovered = Invoke-TestMosaic $inputPath $output
        Assert-True ($recovered.Rendered -eq 1 -and $recovered.CacheMisses -eq 1) 'Repaired media retried'
    }
    Test-Case 'elapsed progress refreshes while a decoder is still running' {
        $inputPath = New-TestFolder 'progress-decoder'
        $source = Join-Path $inputPath 'hang.webp'; Set-Content -LiteralPath $source -Value 'hang'
        Start-ProgressCapture
        try {
            $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -FFmpeg $decoder -FFmpegTimeoutSeconds 2 -WarningAction SilentlyContinue
            $events = @(& $module { $script:CapturedProgress.ToArray() })
            Assert-True (@($events | Where-Object { $_.CurrentOperation -eq 'hang.webp' -and
                $_.Status -match '0/1 processed.*[12]s elapsed' }).Count -gt 0) 'Progress refreshed before the file finished'
            Assert-True ($events[-1].Completed -and $result.Failed -eq 1) 'Timeout still completes the progress display'
            Assert-DecoderStopped $source
        }
        finally { Stop-ProgressCapture }
    }
    Test-Case 'native arguments preserve quotes, spaces, Unicode, empty strings and trailing backslashes' {
        $arguments = @('space text', 'a"b', '', 'trailing\', 'quote\"after', "Unicode $([char]0x03A9)")
        $result = & $module {
            param($Executable, $Values)
            Invoke-FFmpegProcess -Executable $Executable -Arguments (@('--echo') + $Values) -TimeoutMilliseconds 5000
        } $decoder $arguments
        $encoded = $result.Diagnostic -split '\r?\n'
        Assert-True ($result.ExitCode -eq 0 -and $encoded.Count -eq $arguments.Count) 'Native argument count preserved'
        for ($i = 0; $i -lt $arguments.Count; $i++) {
            Assert-True ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded[$i])) -ceq $arguments[$i]) "Argument $i round trips"
        }
    }
    Test-Case 'large native stderr and stdout do not deadlock and retain diagnostics' {
        $inputPath = New-TestFolder 'pipes'
        $source = Join-Path $inputPath 'diagnostics.webp'; Set-Content -LiteralPath $source -Value 'diagnostics'
        $result = & $module { param($Executable, $Source)
            Invoke-FFmpegProcess -Executable $Executable -Arguments @('-i', $Source) -TimeoutMilliseconds 5000
        } $decoder $source
        Assert-True ($result.ExitCode -eq 17 -and $result.Diagnostic.Contains(('e' * 131072)) -and
            $result.Diagnostic.Contains(('o' * 131072))) 'Both pipes drained without losing nonzero exit code'
    }
    Test-Case 'timeout terminates the decoder and removes its partial temporary image' {
        $inputPath = New-TestFolder 'timeout-cleanup'
        $source = Join-Path $inputPath 'hang.mp4'; Set-Content -LiteralPath $source -Value 'hang'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { & $module { param($Source, $Executable, $TemporaryFolder)
            Get-FFmpegPreview -Path $Source -FFmpeg $Executable -Video -FFmpegTimeoutSeconds 1 -TemporaryFolder $TemporaryFolder
        } $source $decoder $inputPath } 'timed out'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 8) 'Decoder does not sleep for 30 seconds'
        Assert-DecoderStopped $source
        Assert-True (@(Get-ChildItem -LiteralPath $inputPath -Filter '*.png').Count -eq 0) 'Partial frame removed'
    }
    Test-Case 'video fallback shares the original time budget' {
        $inputPath = New-TestFolder 'timeout-fallback'
        $source = Join-Path $inputPath 'fallback.mp4'; Set-Content -LiteralPath $source -Value 'fallback'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { & $module { param($Source, $Executable)
            Get-FFmpegPreview -Path $Source -FFmpeg $Executable -Video -FFmpegTimeoutSeconds 1
        } $source $decoder } 'timed out'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 5) 'Fallback timeout returns promptly'
        Assert-DecoderStopped $source
        # Each attempt takes 600 ms. Renewing the one-second budget would
        # incorrectly succeed, while the shared budget must time out.
        $preview = & $module { param($Source, $Executable)
            Get-FFmpegPreview -Path $Source -FFmpeg $Executable -Video -FFmpegTimeoutSeconds 3
        } $source $decoder
        try { Assert-True ($preview.Width -eq 16) 'The same fallback succeeds with a sufficient shared budget' }
        finally { $preview.Dispose() }
    }
    Test-Case 'CLI propagates the timeout and continues rendering after a stalled WebP decoder' {
        $inputPath = New-TestFolder 'timeout-continue'
        $source = Join-Path $inputPath 'a.webp'; Set-Content -LiteralPath $source -Value 'hang'
        New-TestImage (Join-Path $inputPath 'b.jpg')
        $result = & (Join-Path $repo 'MediaMosaic.ps1') -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -FFmpeg $decoder -FFmpegTimeoutSeconds 1 -NoProgress -WarningAction SilentlyContinue
        $records = @(Import-Csv -LiteralPath $result.IndexPath)
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 1) 'Run continued to the next file'
        Assert-True ($records[0].Error -match 'timed out' -and $records[1].Status -eq 'Rendered') 'Timeout retained in CSV'
        Assert-DecoderStopped $source
    }
    Test-Case 'relative CSV captions distinguish duplicate filenames and pagination keeps the last file' {
        $inputPath = New-TestFolder 'duplicates'
        foreach ($folder in @('a', 'b', 'c')) {
            $sub = Join-Path $inputPath $folder; [IO.Directory]::CreateDirectory($sub) | Out-Null
            New-TestImage (Join-Path $sub 'photo.jpg')
        }
        $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ FilesPerSheet = 2 }
        $records = @(Import-Csv -LiteralPath $result.IndexPath)
        Assert-True ($records.Count -eq 3 -and $result.Sheets.Count -eq 2) 'Last singleton page retained'
        Assert-True (($records.RelativePath -join '|') -eq 'a\photo.jpg|b\photo.jpg|c\photo.jpg') 'Deterministic relative names'
        Assert-True ($records[2].Sheet -eq 2 -and $records[2].Cell -eq 1) 'Correct final page mapping'
    }
    Test-Case 'oversized canvas fails without replacing existing output or leaking staging files' {
        $inputPath = New-TestFolder 'oversized'
        New-TestImage (Join-Path $inputPath 'photo.jpg')
        $output = Join-Path $inputPath 'sheet.jpg'
        $first = Invoke-TestMosaic $inputPath $output
        $before = (Get-FileHash -LiteralPath $first.Sheets[0]).Hash
        Assert-Throws { Invoke-TestMosaic $inputPath $output @{ Columns = 1000; ThumbWidth = 10000 } } 'Canvas is too large'
        Assert-True ((Get-FileHash -LiteralPath $first.Sheets[0]).Hash -eq $before) 'Previous sheet preserved'
        Assert-True (@(Get-ChildItem -LiteralPath $inputPath -Directory -Force | Where-Object Name -match '^\.mediamosaic-[a-f0-9]{32}$').Count -eq 0) 'No staging directories leaked'
    }
    Test-Case 'manifest cannot delete paths outside its numbered sheet namespace' {
        $inputPath = New-TestFolder 'manifest'
        $protected = Join-Path $inputPath 'keep.jpg'; New-TestImage $protected
        $manifest = Join-Path $inputPath 'sheet.mediamosaic.json'
        foreach ($entry in @('..\keep.jpg', 'keep.jpg', 'sheet-*.jpg', 'sheet-1.jpg\child')) {
            @{ Version = 1; Sheets = @($entry) } | ConvertTo-Json | Set-Content -LiteralPath $manifest
            Assert-Throws { Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') } 'Invalid sheet name'
            Assert-True (Test-Path -LiteralPath $protected) 'Unrelated input preserved'
        }
    }
    Test-Case 'save failure releases the source image and drawing resources' {
        $inputPath = New-TestFolder 'save-failure'
        $source = Join-Path $inputPath 'photo.jpg'; New-TestImage $source
        Assert-Throws {
            & $module {
                param($Source, $Root, $Destination)
                Write-ContactSheet -Files @(Get-Item -LiteralPath $Source) -Root $Root -Path $Destination -Title 'test' -Sheet 1 -FFmpeg 'ffmpeg' -Columns 1 -ThumbWidth 40 -ThumbHeight 20 -HeaderHeight 60 -TextHeight 30 -Padding 5
            } $source $inputPath (Join-Path $inputPath 'missing\sheet.jpg')
        }
        Assert-Unlocked $source
    }
    Test-Case 'EXIF rotation and mirroring handle all eight orientations' {
        $inputPath = New-TestFolder 'orientation'
        $source = Join-Path $inputPath 'source.jpg'
        $bitmap = [Drawing.Bitmap]::new(80, 60)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.FillRectangle([Drawing.Brushes]::Red, 0, 0, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Lime, 40, 0, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Blue, 0, 30, 40, 30)
            $graphics.FillRectangle([Drawing.Brushes]::Yellow, 40, 30, 40, 30)
            $bitmap.Save($source, [Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
        $expectedCorners = @('Red,Lime,Blue,Yellow', 'Lime,Red,Yellow,Blue',
            'Yellow,Blue,Lime,Red', 'Blue,Yellow,Red,Lime', 'Red,Blue,Lime,Yellow',
            'Blue,Red,Yellow,Lime', 'Yellow,Lime,Blue,Red', 'Lime,Yellow,Red,Blue')
        for ($orientation = 1; $orientation -le 8; $orientation++) {
            $image = [Drawing.Image]::FromFile($source)
            $destination = Join-Path $inputPath "$orientation.jpg"
            try {
                $property = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([Drawing.Imaging.PropertyItem])
                $property.Id = 274; $property.Type = 3; $property.Len = 2; $property.Value = [byte[]]@($orientation, 0)
                $image.SetPropertyItem($property)
                $image.Save($destination, [Drawing.Imaging.ImageFormat]::Jpeg)
            }
            finally { $image.Dispose() }
            $rotated = & $module { param($Path) Get-RotatedImage $Path } $destination
            try {
                $expectedWidth = if ($orientation -ge 5) { 60 } else { 80 }
                Assert-True ($rotated.Width -eq $expectedWidth) "Orientation $orientation dimensions"
                $corners = @($rotated.GetPixel(5, 5), $rotated.GetPixel($rotated.Width - 6, 5),
                    $rotated.GetPixel(5, $rotated.Height - 6), $rotated.GetPixel($rotated.Width - 6, $rotated.Height - 6))
                $colors = $expectedCorners[$orientation - 1].Split(',')
                for ($corner = 0; $corner -lt 4; $corner++) {
                    $expected = [Drawing.Color]::FromName($colors[$corner])
                    $actual = $corners[$corner]
                    Assert-True (([Math]::Abs([int]$expected.R - $actual.R) -lt 30) -and
                        ([Math]::Abs([int]$expected.G - $actual.G) -lt 30) -and
                        ([Math]::Abs([int]$expected.B - $actual.B) -lt 30)) "Orientation $orientation corner $corner"
                }
            }
            finally { $rotated.Dispose() }
        }
    }
    Test-Case 'CLI returns a nonzero process exit code for an invalid source' {
        $executable = (Get-Process -Id $PID).Path
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $messages = & $executable -NoProfile -File (Join-Path $repo 'MediaMosaic.ps1') -RootFolder (Join-Path $testRoot 'does-not-exist') 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        Assert-True ($exitCode -ne 0) "Expected nonzero exit: $messages"
    }
    Test-Case 'missing FFmpeg reports failures while ordinary images still render' {
        $inputPath = New-TestFolder 'missing-ffmpeg'
        New-TestImage (Join-Path $inputPath 'valid.jpg')
        Set-Content -LiteralPath (Join-Path $inputPath 'clip.mp4') -Value 'not a video'
        $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -FFmpeg 'mediamosaic-nonexistent-ffmpeg' -WarningAction SilentlyContinue
        Assert-True ($result.Rendered -eq 1 -and $result.Failed -eq 1) 'Failure isolated to video'
    }
    $script:ffmpeg = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($script:ffmpeg) {
        Test-Case 'short videos fall back to their first frame; WebP and regular video render' {
            $inputPath = New-TestFolder 'video [fixtures]'
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=red:s=64x48:d=1', '-c:v', 'mpeg4', (Join-Path $inputPath 'short.mp4'))
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=blue:s=64x48:d=5', '-c:v', 'mpeg4', (Join-Path $inputPath 'long.mp4'))
            $jpeg = Join-Path $testRoot 'webp-source.jpg'; New-TestImage $jpeg
            New-FFmpegFixture @('-i', $jpeg, '-frames:v', '1', (Join-Path $inputPath 'image.webp'))
            $result = Invoke-TestMosaic $inputPath (Join-Path $inputPath 'sheet.jpg') @{ FFmpeg = $script:ffmpeg.Source }
            Assert-True ($result.Rendered -eq 3 -and $result.Failed -eq 0) 'All video/WebP previews rendered'
        }
        Test-Case 'FFmpeg preview clones release temporary PNGs on success and extraction failure' {
            $inputPath = New-TestFolder 'ffmpeg-cleanup'
            $video = Join-Path $inputPath 'short.mp4'
            New-FFmpegFixture @('-f', 'lavfi', '-i', 'color=c=red:s=64x48:d=1', '-c:v', 'mpeg4', $video)
            $preview = & $module { param($Path, $FFmpeg, $TemporaryFolder)
                Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -Video -TemporaryFolder $TemporaryFolder
            } $video $script:ffmpeg.Source $inputPath
            try { Assert-True ($preview.Width -eq 64) 'Returned clone remains usable after temporary file deletion' }
            finally { $preview.Dispose() }
            Assert-Unlocked $video
            $invalid = Join-Path $inputPath 'invalid.mp4'; Set-Content -LiteralPath $invalid -Value 'not video'
            Assert-Throws { & $module { param($Path, $FFmpeg, $TemporaryFolder)
                Get-FFmpegPreview -Path $Path -FFmpeg $FFmpeg -Video -TemporaryFolder $TemporaryFolder
            } $invalid $script:ffmpeg.Source $inputPath } 'FFmpeg'
            Assert-True (@(Get-ChildItem -LiteralPath $inputPath -File -Filter '*.png').Count -eq 0) 'No preview temporary files leaked'
        }
        Test-Case 'invalid videos retain FFmpeg diagnostics in the CSV' {
            $inputPath = New-TestFolder 'invalid-video'
            Set-Content -LiteralPath (Join-Path $inputPath 'broken.mp4') -Value 'not a video'
            $result = Invoke-MediaMosaic -RootFolder $inputPath -OutputFile (Join-Path $inputPath 'sheet.jpg') -WarningAction SilentlyContinue
            $record = Import-Csv -LiteralPath $result.IndexPath
            Assert-True ($result.Failed -eq 1 -and $record.Error -match 'FFmpeg.*exit') 'Diagnostic retained'
        }
    }
    elseif ($RequireFFmpeg) { throw 'FFmpeg is required for this test run but was not found on PATH.' }
    else { Write-Host 'SKIP FFmpeg integration tests (ffmpeg is not on PATH).' }
}
finally {
    # Resolve and verify the unique test directory before recursive cleanup.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -ne $parent -or
        [IO.Path]::GetFileName($resolved) -notmatch '^MediaMosaic-tests-[0-9a-f]{32}$') {
        throw "Refusing cleanup outside the test directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "$script:passed passed; $script:failed failed. PowerShell $($PSVersionTable.PSVersion)"
if ($script:failed) { exit 1 }
