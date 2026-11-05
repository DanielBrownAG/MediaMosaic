<p align="center">
  <img src="assets/mediamosaic-logo.png" alt="MediaMosaic — a mosaic of photo and video tiles" width="520">
</p>

# MediaMosaic

Generate JPEG contact sheets from images and videos using PowerShell on Windows.
MediaMosaic recursively scans a media folder, corrects EXIF orientation, and lays
out previews with captions showing paths relative to the source folder. Large
collections are split into numbered sheets, with 200 files per sheet by default.

Use it to review project photography, audit mixed media collections, or prepare
a visual index for dataset review. Each run produces numbered JPEG sheets, a
CSV index, and a manifest for cleaning up obsolete sheets on subsequent runs.

## Quick start

```powershell
git clone https://github.com/DanielBrownAG/MediaMosaic.git
Set-Location MediaMosaic

# Image-only collections need no FFmpeg installation.
.\MediaMosaic.ps1 -RootFolder 'D:\Photos' -OutputFile '.\Review\ProjectPhotos.jpg'
```

Keep `MediaMosaic.ps1` and `MediaMosaic.psm1` together. The script loads the module
relative to its own location, so you can also invoke it from another directory.

## Requirements

- Windows with PowerShell 5.1 or PowerShell 7+ and `System.Drawing`.
- [FFmpeg](https://ffmpeg.org/download.html) for video and WebP previews. Ordinary
  image collections do not require FFmpeg. Use `ffmpeg` on PATH or pass its full
  executable path with `-FFmpeg`.
- Files must be locally readable. OneDrive and SharePoint synchronised files may
  need downloading before they can be decoded.

The regression suite has been run on Windows with PowerShell 5.1 and 7.6.9.
macOS and Linux are not supported by the current Windows drawing implementation.

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

A corrupt or unreadable file with a supported extension keeps its grid position and
caption with a **PREVIEW FAILED** placeholder. Missing FFmpeg affects only media
that require it. Each failed preview emits a warning with the path and error;
processing continues. Headers show separate rendered and failed counts.
Files with extensions outside the supported list are ignored during discovery.

Files are sorted by full path before pagination. Captions show relative paths
and use ellipsis when the caption area is too small; the CSV contains the full
relative path, so identical filenames in different folders remain identifiable.

## Example sheet

![Example contact sheet](ContactImageSheet-1.jpg)

This is an example from the original version. Current output includes relative
paths in captions and separate rendered/failed counts in the header.

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

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Video or WebP cells show `PREVIEW FAILED` | Run `ffmpeg -version`, or pass the full executable path with `-FFmpeg`. Inspect the CSV `Error` column for decoder details. |
| Photos fail to load | Confirm the source is readable and cloud files are downloaded locally; inspect the warning and CSV error for the affected path. |
| No files are discovered | Check the source path and supported extensions. Generated numbered sheets in the output directory are deliberately excluded. |
| Canvas is too large | Reduce `FilesPerSheet`, `Columns`, or thumbnail dimensions. |
| A rerun leaves old pages | Only surplus pages recorded in the manifest are removed. Outputs from the original version may need manual cleanup. |

The current implementation processes files sequentially and regenerates previews
on each run. FFmpeg has no timeout, so a stalled decoder may require interrupting
the run. Progress reporting, thumbnail caching, filters, an HTML gallery, and
video storyboards are not implemented.

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

The 21-case regression suite requires no Pester installation or downloaded test packages.
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
Tests are run locally with the commands above; this repository does not currently
include a GitHub Actions workflow.

## Project files

| Path | Purpose |
| --- | --- |
| `MediaMosaic.ps1` | Command-line entry point and parameter validation |
| `MediaMosaic.psm1` | Discovery, preview decoding, sheet rendering, and output management |
| `tests/Run-Tests.ps1` | Regression suite and generated media fixtures |
| `assets/mediamosaic-logo.png` | Transparent project logo |
| `assets/mediamosaic-logo-prompt.txt` | Logo generation prompt and provenance |

## License

MIT License.
