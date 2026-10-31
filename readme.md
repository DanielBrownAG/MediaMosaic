# MediaMosaic

Generate JPEG contact sheets from images and videos using PowerShell on Windows.
MediaMosaic recursively scans a media folder, corrects EXIF orientation, and lays
out previews with captions showing paths relative to the source folder. Large
collections are split into numbered sheets, with 200 files per sheet by default.

![Example contact sheet](ContactImageSheet-1.jpg)

## Requirements

- Windows with PowerShell 5.1 or PowerShell 7+ and `System.Drawing`.
- [FFmpeg](https://ffmpeg.org/download.html) for video and WebP previews. Ordinary
  image collections do not require FFmpeg. Use `ffmpeg` on PATH or pass its full
  executable path with `-FFmpeg`.
- Files must be locally readable. OneDrive and SharePoint synchronised files may
  need downloading before they can be decoded.

The regression suite has been run on Windows with PowerShell 5.1 and 7.6.9.

## Usage

Run from PowerShell; there is no need to edit the source:

```powershell
.\MediaMosaic.ps1 -RootFolder 'D:\Photos' -OutputFile 'C:\Temp\ProjectPhotos.jpg'
```

The source directory must exist. Output directories are created automatically.
Paths are treated literally, including spaces, apostrophes, and square brackets.
Relative paths resolve against the current PowerShell filesystem location.
`RootFolder` is required; `OutputFile` defaults to `MediaMosaic.jpg` in the current
location. The output filename is a naming base: `.jpg` and `.jpeg` are accepted,
while generated sheets always use `.jpg`.

```powershell
.\MediaMosaic.ps1 -RootFolder 'D:\Photos[2026]' `
    -OutputFile '.\Review\Project.jpg' `
    -FFmpeg 'C:\Tools\ffmpeg\bin\ffmpeg.exe' `
    -FilesPerSheet 100 -Columns 5 -ThumbWidth 240 -ThumbHeight 180
```

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `RootFolder` | Required | Directory scanned recursively |
| `OutputFile` | `MediaMosaic.jpg` | Base output path, ending in `.jpg` or `.jpeg` |
| `FFmpeg` | `ffmpeg` | Executable name on PATH or full executable path |
| `FilesPerSheet` | `200` | Maximum input files per sheet; 1–100,000 |
| `Columns` | `4` | Grid columns; 1–1,000 |
| `ThumbWidth` | `250` | Thumbnail box width in pixels; 1–10,000 |
| `ThumbHeight` | `180` | Thumbnail box height in pixels; 1–10,000 |
| `HeaderHeight` | `60` | Header height in pixels; 1–10,000 |
| `TextHeight` | `30` | Caption height in pixels; 1–10,000 |
| `Padding` | `15` | Cell padding in pixels; 0–1,000 |

All numeric options are validated. Each sheet is limited to 100 million pixels
and 65,500 pixels per side to reject excessive allocations before creating the
canvas. Smaller cell dimensions can clip text; allow sufficient header and
caption space for readable output. The canvas contains only the required rows.

## Supported media and preview failures

- Images: JPG, JPEG, PNG, BMP, GIF, and WebP.
- Videos: MP4, MOV, AVI, and MKV.

JPG/JPEG, PNG, BMP, and GIF use Windows image decoding. EXIF rotations and mirrored
orientations are corrected when orientation metadata is present. GIFs use their
initial frame. WebP previews are decoded by FFmpeg.

Videos use a frame at approximately three seconds. If that extraction fails or
produces no frame, MediaMosaic retries at the beginning, so short clips still
have a preview. Video cells carry a red **VIDEO** label. FFmpeg runs without
interactive input; its exit status, output file, and diagnostics are checked.
Temporary preview files are removed and image/drawing resources are disposed
on both success and failure.

A corrupt, unreadable, or unsupported media file keeps its grid position and
caption with a **PREVIEW FAILED** placeholder. Missing FFmpeg affects only media
that require it. Each failed preview emits a warning with the path and error;
processing continues. Headers show separate rendered and failed counts.

Files are sorted by full path before pagination. Captions show relative paths
and use ellipsis when the caption area is too small; the CSV contains the full
relative path, so identical filenames in different folders remain identifiable.

## Outputs and reruns

For `-OutputFile 'C:\Temp\ProjectPhotos.jpg'`, a run produces:

```text
ProjectPhotos-1.jpg
ProjectPhotos-2.jpg
ProjectPhotos-index.csv
ProjectPhotos.mediamosaic.json
```

The CSV contains one row per discovered media file, including failed previews:

| Column | Meaning |
| --- | --- |
| `RelativePath` | Complete path relative to `RootFolder` |
| `Sheet` | One-based sheet number |
| `Cell` | One-based cell number within that sheet |
| `Status` | `Rendered` or `Failed` |
| `Error` | Failure details, otherwise empty |

Generated `ProjectPhotos-N.jpg` files in the exact output directory are excluded
from scanning, even when that directory is inside the source tree. This numbered
filename namespace is reserved for outputs; choose a different base if your
source files already use those names. Output sheets with the current numbers,
the CSV, and the manifest are replaced on rerun.
Private staging directories immediately inside the output folder are also
excluded from scanning, including remnants of interrupted runs.

The manifest records the sheet filenames generated by MediaMosaic. After all new
sheets have been generated successfully, obsolete pages recorded in that
manifest are removed. Unrecorded surplus files are preserved, including outputs
from older versions without a manifest. Manifest entries are validated to reject
paths, wildcards, and unrelated filenames before any output is published.

A valid empty source returns zero counts, writes an empty CSV with column
headers, and removes previously recorded sheets. An invalid or inaccessible
source raises an error instead. Generation uses a private staging directory;
a generation error leaves previously published sheets intact. Publishing
multiple files is not an atomic transaction: a filesystem error during publishing
can leave a partially updated set. Avoid simultaneous runs using the same output
base. Keep the manifest alongside the sheets for reliable cleanup.

## Automation

The script returns one summary object:

```powershell
$result = .\MediaMosaic.ps1 -RootFolder 'D:\Photos' -OutputFile '.\Review\Project.jpg'
$result | Format-List
# Discovered, Rendered, Failed, Sheets, IndexPath, ManifestPath

if ($result.Failed -gt 0) {
    Write-Error "$($result.Failed) previews failed; inspect $($result.IndexPath)"
}
```

Partial preview failures are reported through warnings, the summary, and the
CSV; they do not fail the whole run. Fatal errors, such as a missing source,
invalid options, or an output write failure, terminate processing. When invoked
with `powershell.exe -File` or `pwsh -File`, fatal errors return a nonzero process
exit code. Use `Failed` to enforce stricter acceptance of partial results.

The reusable module exports `Invoke-MediaMosaic` with the same parameters:

```powershell
Import-Module .\MediaMosaic.psm1
Invoke-MediaMosaic -RootFolder 'D:\Photos' -OutputFile '.\Review\Project.jpg'
```

## Tests

The regression suite requires no Pester installation or downloaded test packages.
It creates its own fixtures in a unique temporary directory and removes them
afterwards. FFmpeg integration tests generate real videos and WebP images.

```powershell
# Run all tests, requiring FFmpeg on PATH:
.\tests\Run-Tests.ps1 -RequireFFmpeg

# Run explicitly with each supported PowerShell edition:
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1 -RequireFFmpeg
pwsh -NoProfile -File .\tests\Run-Tests.ps1 -RequireFFmpeg
```

Without `-RequireFFmpeg`, FFmpeg integration tests are skipped if it is absent.
The runner returns a nonzero exit code for failed tests. Coverage includes
literal and relative paths, invalid options, missing directories, corrupt media,
short clips, WebP, EXIF rotation and mirroring, pagination, duplicate filenames,
output exclusion, manifest cleanup and validation, empty input, resource cleanup,
and preservation of existing sheets when generation fails.

## License

MIT License.
