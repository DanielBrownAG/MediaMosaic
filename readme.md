\# MediaMosaic



Generate visual contact sheets from images and videos using PowerShell.



MediaMosaic recursively scans a folder, automatically corrects image orientation using EXIF metadata, extracts preview frames from video files, and creates a single visual index image containing thumbnails and filenames for every media file discovered.



Originally developed to review large exploration and mining project folders containing thousands of photographs and videos, MediaMosaic provides a fast way to catalogue, audit, review, and prepare media collections for AI-assisted analysis.



\---



\## Features



\* Recursive folder scanning

\* Automatic EXIF image orientation correction

\* Video thumbnail generation using FFmpeg

\* Thumbnail grid layout

\* Filename captions beneath each thumbnail

\* Customisable thumbnail dimensions

\* Customisable number of columns

\* High-resolution JPEG output

\* Project title and file count displayed in output image

\* Works with local folders, OneDrive folders, and SharePoint-synchronised libraries



\---



\## Supported Formats



\### Images



\* JPG

\* JPEG

\* PNG

\* BMP

\* GIF

\* WEBP



\### Videos



\* MP4

\* MOV

\* AVI

\* MKV



\---



\## Example Output



```text

Project1.jpg - 347 Files



\[thumbnail] \[thumbnail] \[thumbnail] \[thumbnail]

IMG\_001.jpg IMG\_002.jpg VIDEO001.mp4 IMG\_003.jpg



\[thumbnail] \[thumbnail] \[thumbnail] \[thumbnail]

IMG\_004.jpg IMG\_005.jpg VIDEO002.mov IMG\_006.jpg

```



\---



\## Requirements



\### Windows



MediaMosaic has been tested on:



\* Windows 10

\* Windows 11

\* PowerShell 5.1

\* PowerShell 7+



\### FFmpeg



Video thumbnail generation requires FFmpeg.



Download FFmpeg and update the path in the script:



```powershell

$FFmpeg = "C:\\Tools\\ffmpeg\\ffmpeg.exe"

```



FFmpeg can be downloaded from:



https://ffmpeg.org/download.html



\---



\## Configuration



Update the settings section of the script:



```powershell

$RootFolder = "D:\\Photos"

$OutputFile = "C:\\Temp\\MediaMosaic.jpg"



$ThumbWidth = 250

$ThumbHeight = 180



$Columns = 4

```



\### Settings



| Setting      | Description                  |

| ------------ | ---------------------------- |

| RootFolder   | Folder to scan recursively   |

| OutputFile   | Output JPEG file             |

| ThumbWidth   | Thumbnail width              |

| ThumbHeight  | Thumbnail height             |

| Columns      | Number of thumbnails per row |

| HeaderHeight | Height of the title area     |



\---



\## Usage



Run the script:



```powershell

.\\MediaMosaic.ps1

```



Example output:



```text

Found 347 files.

Added: IMG\_001.jpg

Added: IMG\_002.jpg

Added: VIDEO001.mp4



Contact sheet created:

C:\\Temp\\Project1.jpg

```



\---



\## Common Use Cases



\### Mining \& Exploration



\* Exploration project reviews

\* Geological photography cataloguing

\* Drill hole image indexing

\* Field photography archives

\* Opal mining documentation



\### Project Management



\* SharePoint media audits

\* OneDrive media reviews

\* Construction progress photography

\* Asset management



\### AI \& Computer Vision



\* Dataset review

\* Image collection auditing

\* Computer vision training preparation

\* ChatGPT image review workflows

\* Visual dataset indexing



\---



\## How It Works



\### Images



Image files are loaded directly and automatically rotated using EXIF orientation metadata.



\### Videos



MediaMosaic uses FFmpeg to extract a preview frame from each video and includes it in the contact sheet.



This allows video content to be reviewed without opening each file individually.



\---



\## License



MIT License



\---



\## Contributing



Pull requests, bug reports, and feature suggestions are welcome.



If you find MediaMosaic useful, consider starring the repository.



