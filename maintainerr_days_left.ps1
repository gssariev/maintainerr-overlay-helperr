$PLEX_URL = ($env:PLEX_URL -replace '/+$', '')
$PLEX_TOKEN = $env:PLEX_TOKEN
$MAINTAINERR_URL = ($env:MAINTAINERR_URL -replace '/+$', '')

# Ensure trailing slashes are removed from directory paths
$IMAGE_SAVE_PATH = ($env:IMAGE_SAVE_PATH -replace '[/\\]+$', '')
$ORIGINAL_IMAGE_PATH = ($env:ORIGINAL_IMAGE_PATH -replace '[/\\]+$', '')
$TEMP_IMAGE_PATH = ($env:TEMP_IMAGE_PATH -replace '[/\\]+$', '')

$FONT_PATH = $env:FONT_PATH
$FONT_COLOR = $env:FONT_COLOR
$BACK_COLOR = $env:BACK_COLOR

$FONT_SIZE = $env:FONT_SIZE
$PADDING = $env:PADDING
$BACK_RADIUS = $env:BACK_RADIUS
$HORIZONTAL_OFFSET = $env:HORIZONTAL_OFFSET
$HORIZONTAL_ALIGN = $env:HORIZONTAL_ALIGN
$VERTICAL_OFFSET = $env:VERTICAL_OFFSET
$VERTICAL_ALIGN = $env:VERTICAL_ALIGN

$OVERLAY_TEXT = $env:OVERLAY_TEXT
$ENABLE_DAY_SUFFIX = [bool]($env:ENABLE_DAY_SUFFIX -eq "true")
$ENABLE_UPPERCASE = [bool]($env:ENABLE_UPPERCASE -eq "true")
$LANGUAGE = $env:LANGUAGE
$DATE_FORMAT = $env:DATE_FORMAT
$PROCESS_COLLECTIONS = $env:PROCESS_COLLECTIONS
$REAPPLY_OVERLAY = [bool]($env:REAPPLY_OVERLAY -eq "true")
$RESET_OVERLAY = [bool]($env:RESET_OVERLAY -eq "true")

$USE_DAYS = [bool]($env:USE_DAYS -eq "true")

$ErrorActionPreference = 'Stop'
trap {
    $e = $_.Exception
    Log-Message -Type "ERR" -Message ("UNHANDLED: " + $e.GetType().FullName + " - " + $e.Message)
    if ($e.InnerException) {
        Log-Message -Type "ERR" -Message ("INNER: " + $e.InnerException.GetType().FullName + " - " + $e.InnerException.Message)
        Log-Message -Type "DBG" -Message ($e.InnerException.ToString())
    }
    else {
        Log-Message -Type "DBG" -Message ($e.ToString())
    }
    exit 1
}

# Set defaults if not provided
if (-not $DATE_FORMAT) {
    $DATE_FORMAT = "MMM d"
}
if (-not $LANGUAGE) {
    $LANGUAGE = "en-US"
}
if (-not $OVERLAY_TEXT) {
    $OVERLAY_TEXT = "Leaving"
}

if (-not $PROCESS_COLLECTIONS) {
    # Default: include all (by setting to empty array, or ["*"])
    $collectionsToReorder = @("*")
}
else {
    $collectionsToReorder = $PROCESS_COLLECTIONS -split "," | ForEach-Object { $_.Trim() }
}

function Normalize-Culture([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "en-US" }
    $t = $s.Trim()
    # Convert en_US.UTF-8 -> en-US
    $t = $t -replace '\.UTF-?8$', '' -replace '_', '-'
    try {
        [void][System.Globalization.CultureInfo]::GetCultureInfo($t)
        return $t
    }
    catch {
        Log-Message -Type "WRN" -Message "Unsupported culture '$s' (normalized '$t'). Falling back to en-US."
        return "en-US"
    }
}

# Use env or default, then normalize and create CultureInfo
if (-not $LANGUAGE) { $LANGUAGE = "en-US" }
$LANGUAGE = Normalize-Culture $LANGUAGE
$cultureInfo = [System.Globalization.CultureInfo]::GetCultureInfo($LANGUAGE)


# Define path for tracking collection state
$CollectionStateFile = Join-Path $IMAGE_SAVE_PATH "current_collection_state.json"

# Initialize collection state if the file does not exist
if (-not (Test-Path -Path $CollectionStateFile)) {
    @{} | ConvertTo-Json | Set-Content -Path $CollectionStateFile
}

function Log-Message {
    param (
        [string]$Type,
        [string]$Message
    )

    # ANSI escape codes for colors
    $ColorReset = "`e[0m"
    $ColorBlue = "`e[34m"
    $ColorRed = "`e[31m"
    $ColorYellow = "`e[33m"
    $ColorGray = "`e[90m"
    $ColorGreen = "`e[32m"
    $ColorDefault = "`e[37m"

    # Select color based on message type
    $color = switch ($Type) {
        "INF" { $ColorBlue }
        "ERR" { $ColorRed }
        "WRN" { $ColorYellow }
        "DBG" { $ColorGray }
        "SUC" { $ColorGreen }
        default { $ColorDefault }
    }

    # Add a timestamp for each log entry
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    # Output the colored type, timestamp, and uncolored message
    Write-Host "$($color)[$Type]$($ColorReset) [$timestamp] $Message"
}

# Validate required environment variables early to avoid null-call failures
$requiredEnvVars = @{
    "PLEX_URL"            = $PLEX_URL
    "PLEX_TOKEN"          = $PLEX_TOKEN
    "MAINTAINERR_URL"     = $MAINTAINERR_URL
    "IMAGE_SAVE_PATH"     = $IMAGE_SAVE_PATH
    "ORIGINAL_IMAGE_PATH" = $ORIGINAL_IMAGE_PATH
    "TEMP_IMAGE_PATH"     = $TEMP_IMAGE_PATH
}
foreach ($key in $requiredEnvVars.Keys) {
    if (-not $requiredEnvVars[$key]) {
        Log-Message -Type "ERR" -Message "Missing required environment variable: $key"
        exit 1
    }
}

if ($REAPPLY_OVERLAY) {
    Log-Message -Type "INF" -Message "Reapply overlay is enabled. Overlays will be reapplied for all media."
}

# Detect and log timezone info
try {
    $tzName = if ($env:TZ) { $env:TZ } else { (Get-TimeZone).Id }
    Log-Message -Type "INF" -Message "Cron is running based on local time zone ($tzName)."
}
catch {
    Log-Message -Type "WRN" -Message "Unable to determine local timezone; defaulting to UTC."
}


function Get-BestPlexImageUrl {
    param([Parameter(Mandatory = $true)][string]$MetadataId)

    $base = $PLEX_URL.TrimEnd('/')
    $token = $PLEX_TOKEN

    # Fetch metadata (XML) first
    try {
        $meta = Invoke-RestMethod -Uri "$base/library/metadata/$MetadataId" `
            -Headers @{ "X-Plex-Token" = $token } `
            -Method GET -ErrorAction Stop
    }
    catch {
        Log-Message -Type "WRN" -Message "Metadata lookup failed for $MetadataId on ${base}: $_"
        return $null
    }

    $mc = $meta.MediaContainer
    if (-not $mc) { return $null }

    # Pick the primary node (movie = Video, show/season/episode may differ)
    $node = $null
    foreach ($name in @('Video', 'Directory', 'Track', 'Metadata', 'Photo')) {
        if ($mc.$name) { $node = $mc.$name; break }
    }
    if ($node -is [System.Array]) { $node = $node[0] }
    if (-not $node) { return $null }

    # Build candidate list in the preferred order.
    $candidates = New-Object System.Collections.Generic.List[string]

    # 1) EXACT versioned paths from metadata 
    foreach ($p in @($node.thumb, $node.art, $node.parentThumb, $node.grandparentThumb, $node.parentArt, $node.grandparentArt)) {
        if ($p) { $candidates.Add($p) }
    }

    # 2) URLs from <Image> nodes (often duplicate of above, but keep as fallback)
    if ($node.Image) {
        $node.Image | ForEach-Object {
            if ($_.url) { $candidates.Add($_.url) }
        }
    }

    # 3) Fallbacks, in case versioned are missing
    $candidates.Add("/library/metadata/$MetadataId/thumb")
    $candidates.Add("/library/metadata/$MetadataId/art")

    # Dedup while preserving order
    $seen = @{}
    $ordered = foreach ($p in $candidates) { if (-not $seen[$p]) { $seen[$p] = $true; $p } }

    foreach ($p in $ordered) {
        $u = if ($p -like 'http*') { $p }
        elseif ($p.StartsWith('/')) { "$base$p" }
        else { "$base/$p" }

        try {
            $tmp = [System.IO.Path]::GetTempFileName()
            Invoke-WebRequest -Uri $u -Headers @{ "X-Plex-Token" = $token } `
                -UseBasicParsing -OutFile $tmp -ErrorAction Stop | Out-Null
            return $u
        }
        catch {
            continue
        }
        finally {
            if ($null -ne $tmp -and (Test-Path -LiteralPath $tmp)) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $null
}

function Load-CollectionState {
    if (Test-Path -Path $CollectionStateFile) {
        try {
            $rawContent = Get-Content -Path $CollectionStateFile -Raw
            Write-Host "Raw State File Content: $rawContent"            
            # Issue 41: if the JSON is empty or invalid, this can return $null, so we need to handle that case 
            # Use -AsHashTable to ensure we get a hashtable back, and set a reasonable depth for nested structures
            $state = $rawContent | ConvertFrom-Json -AsHashTable -Depth 10

            if ($state -eq $null) {
                Log-Message -Type "WRN" -Message "Warning: Parsed state is null. Initializing as empty."
                return @{}
            }

            if ($state -is [PSCustomObject]) {
                $result = @{}
                foreach ($prop in $state.PSObject.Properties) {
                    $result[$prop.Name] = $prop.Value
                }
                return $result
            }

            return $state
        }
        catch {
            Log-Message -Type "ERR" -Message "Failed to load or parse state file: $_. Initializing as empty."
            return @{}
        }
    }
    else {
        Log-Message -Type "WRN" -Message "State file does not exist. Initializing as empty."
        return @{}
    }
}


function Save-CollectionState {
    param (
        [hashtable]$state
    )

    $stringKeyedState = @{}
    foreach ($key in $state.Keys) {
        $stringKeyedState["$key"] = $state[$key]
    }

    try {
        $json = $stringKeyedState | ConvertTo-Json -Depth 10
        $tmp = "$CollectionStateFile.tmp"

        # Write to a temp file first, then replace (reduces risk of partial writes)
        $json | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $CollectionStateFile -Force

        Log-Message -Type "SUC" -Message "Saved state to $CollectionStateFile"
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to save state: $_"
    }
}

# Function to calculate the calendar date
function Calculate-Date {
    param (
        [Parameter(Mandatory = $true)]
        [datetime]$addDate,

        [Parameter(Mandatory = $true)]
        [int]$deleteAfterDays
    )

    Log-Message -Type "INF" -Message "Attempting to parse date: $addDate"
    $deleteDate = $addDate.AddDays($deleteAfterDays)
    
    # Format the date using the specified culture
    $formattedDate = $deleteDate.ToString($DATE_FORMAT, $cultureInfo)

    if ($ENABLE_DAY_SUFFIX) {
        $daySuffix = switch ($deleteDate.Day) {
            1 { "st" }
            2 { "nd" }
            3 { "rd" }
            21 { "st" }
            22 { "nd" }
            23 { "rd" }
            31 { "st" }
            default { "th" }
        }
        $formattedDate = $formattedDate + $daySuffix
    }
    
    if ($ENABLE_UPPERCASE) {
        $formattedDate = $formattedDate.ToUpper()
    }
    
    return $formattedDate
}

function Get-DaysLeft {
    param(
        [Parameter(Mandatory = $true)][datetime]$addDate,
        [Parameter(Mandatory = $true)][int]$deleteAfterDays
    )
    # End of life moment = addDate + deleteAfterDays 
    $deleteDate = $addDate.AddDays($deleteAfterDays)

    # Round up so at 1.1 days it still says "in 2 days"
    $daysLeft = [math]::Ceiling( ($deleteDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays )

    if ($daysLeft -lt 0) { $daysLeft = 0 }

    # Return both pieces
    return @{
        DaysLeft   = [int]$daysLeft
        DeleteDate = $deleteDate
    }
}

function Select-UploadedPoster {
    param([Parameter(Mandatory = $true)][string]$MetadataId, [Parameter(Mandatory = $true)][string]$UploadPosterId)
    $selUrl = "$PLEX_URL/library/metadata/$MetadataId/poster?url=$( [uri]::EscapeDataString("upload://posters/$UploadPosterId") )"
    try {
        Invoke-RestMethod -Uri $selUrl -Method PUT -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -ErrorAction Stop | Out-Null
        Log-Message -Type "SUC" -Message "Selected uploaded poster $UploadPosterId for $MetadataId ."
        return $true
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed to select uploaded poster $UploadPosterId for ${MetadataId}: $_"
        return $false
    }
}

function Format-LeavingText {
    param(
        [Parameter(Mandatory = $true)][int]$daysLeft,
        [datetime]$addDate,                  # required for USE_DAYS=$false mode
        [int]$deleteAfterDays,               # required for USE_DAYS=$false mode
        [bool]$Uppercase = $ENABLE_UPPERCASE
    )

    if ($USE_DAYS) {
        # --- Customizable text mode ---
        $TEXT_TODAY = $env:TEXT_TODAY ; if (-not $TEXT_TODAY) { $TEXT_TODAY = "TODAY" }
        $TEXT_DAY = $env:TEXT_DAY   ; if (-not $TEXT_DAY) { $TEXT_DAY = "in 1 day" }
        $TEXT_DAYS = $env:TEXT_DAYS  ; if (-not $TEXT_DAYS) { $TEXT_DAYS = "in {0} days" }

        if ($daysLeft -le 0) {
            $text = $TEXT_TODAY
        }
        elseif ($daysLeft -eq 1) {
            $text = $TEXT_DAY
        }
        else {
            $text = [string]::Format($TEXT_DAYS, $daysLeft)
        }
    }
    else {
        # --- Classic date mode ---
        $formattedDate = Calculate-Date -addDate $addDate -deleteAfterDays $deleteAfterDays
        $text = "$OVERLAY_TEXT $formattedDate"
    }

    # Apply uppercase if requested
    if ($Uppercase) {
        try {
            if ($script:cultureInfo) { return $text.ToUpper($script:cultureInfo) }
            if ($global:cultureInfo) { return $text.ToUpper($global:cultureInfo) }
        }
        catch { }
        return $text.ToUpper()
    }

    return $text
}

function Get-TargetCollectionName {
    param([pscustomobject]$Collection)

    $isManual = $false
    if ($null -ne $Collection.manualCollection) {
        if ($Collection.manualCollection -is [bool]) { $isManual = $Collection.manualCollection }
        else {
            $s = "$($Collection.manualCollection)".ToLower()
            $isManual = ($s -eq "true" -or $s -eq "1" -or $s -eq "yes")
        }
    }

    $manualName = "$($Collection.manualCollectionName)".Trim()
    if ($isManual -and $manualName) {
        return $manualName
    }

    return "$($Collection.title)".Trim()
}


function Download-Poster {
    param (
        [string]$posterUrl,
        [string]$savePathBase
    )

    try {
        Log-Message -Type "INF" -Message "Downloading poster from: $posterUrl"

        $tempFile = "${savePathBase}.jpg"
        Invoke-WebRequest -Uri $posterUrl -Headers @{"X-Plex-Token" = $PLEX_TOKEN } -OutFile $tempFile -UseBasicParsing

        # Check if file size is too small (likely invalid)
        if ((Get-Item $tempFile).Length -lt 1024) {
            Log-Message -Type "WRN" -Message "Downloaded file at $tempFile is too small (<1 KB). Treating as invalid."
            Remove-Item -Path $tempFile -Force
            throw "Downloaded file too small to be valid image."
        }

        # Identify real file type
        $formatInfo = & magick "$tempFile" -format "%m" info:
        Log-Message -Type "INF" -Message "Actual format detected: $formatInfo"

        if ([string]::IsNullOrEmpty($formatInfo)) {
            Remove-Item -Path $tempFile -Force
            throw "Unable to detect format."
        }

        $ext = switch ($formatInfo.ToLower()) {
            "jpeg" { ".jpg" }
            "jpg" { ".jpg" }
            "png" { ".png" }
            "webp" { ".webp" }
            default { ".jpg" } # Safe fallback
        }

        # Correct final path
        $savePath = "${savePathBase}${ext}"

        if ($ext -ne ".jpg") {
            Move-Item -Path $tempFile -Destination $savePath -Force
        }
        else {
            $savePath = $tempFile
        }

        # Final validate
        if (-not (Validate-Poster -filePath $savePath)) {
            Log-Message -Type "WRN" -Message "Downloaded file at $savePath is not a valid image. Deleting file."
            Remove-Item -Path $savePath -Force
            throw "Invalid poster file format detected."
        }

        Log-Message -Type "SUC" -Message "Downloaded and saved poster to: $savePath"
        return $savePath
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed to download poster from $posterUrl. Error: $_"
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force
        }
        throw
    }
}

# Function to revert to the original poster
function Revert-ToOriginalPoster {
    param (
        [Parameter(Mandatory = $true)][string]$plexId,
        [Parameter(Mandatory = $true)][string]$originalImagePath
    )

    if (-not (Test-Path -Path $originalImagePath)) {
        Log-Message -Type "WRN" -Message "Original image not found for Plex ID: $plexId. Skipping revert."
        return $false
    }

    $ext = [System.IO.Path]::GetExtension($originalImagePath).ToLower()
    $contentType = switch ($ext) {
        ".jpg" { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".png" { "image/png" }
        ".webp" { "image/webp" }
        default { "application/octet-stream" }
    }

    $uploadUrl = "$PLEX_URL/library/metadata/$plexId/posters?X-Plex-Token=$PLEX_TOKEN"

    try {
        Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster ($ext)."
        $posterBytes = [System.IO.File]::ReadAllBytes($originalImagePath)
        Invoke-RestMethod -Uri $uploadUrl -Method Post -Body $posterBytes -ContentType $contentType -ErrorAction Stop
        Log-Message -Type "SUC" -Message "Reverted Plex ID: $plexId to original."
        return $true
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to revert Plex ID: $plexId. Error: $_"
        return $false
    }
}


function Reset-AllOverlays {
    $state = Load-CollectionState
    if (-not $state -or $state.Keys.Count -eq 0) {
        Log-Message -Type "INF" -Message "No processed state to reset. Nothing to do."
        return
    }

    $processed = @(
        $state.GetEnumerator() |
        Where-Object {
            $v = $_.Value
            if ($v -is [bool]) { return ($v -eq $true) }
            if ($v -is [string]) { return ($v -eq "true") }
            if ($v -is [pscustomobject] -or $v -is [hashtable]) {
                return (("$($v.processed)") -eq "True")
            }
            return $false
        } | Select-Object -ExpandProperty Key
    )

    if (-not $processed -or $processed.Count -eq 0) {
        Log-Message -Type "INF" -Message "No items marked as processed. Nothing to revert."
    }
    else {
        Log-Message -Type "INF" -Message "Reverting overlays for $($processed.Count) items..."
        foreach ($plexId in $processed) {
            $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
            if ($posterFiles -and $posterFiles.Count -gt 0) {
                $originalImagePath = $posterFiles[0].FullName
                $ok = Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
                if ($ok) {
                    try {
                        Remove-Item -Path $originalImagePath -Force -ErrorAction Stop
                        Log-Message -Type "INF" -Message "Deleted original poster after revert for Plex ID $plexId."
                    }
                    catch {
                        Log-Message -Type "WRN" -Message "Could not delete original poster for ${plexId}: $_"
                    }
                }
            }
            else {
                Log-Message -Type "WRN" -Message "Original poster not found for Plex ID $plexId in '$ORIGINAL_IMAGE_PATH'."
            }
        }
    }

    # Clear state and purge temp folder
    Save-CollectionState -state @{}
    Log-Message -Type "SUC" -Message "Reset complete. State cleared and original poster files deleted."

    # Clean temp images created during overlays
    try {
        Get-ChildItem -Path $TEMP_IMAGE_PATH -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Log-Message -Type "INF" -Message "Cleaned up temporary images in '$TEMP_IMAGE_PATH'."
    }
    catch { }
}

function Add-Overlay {
    param (
        [Parameter(Mandatory = $true)][string]$imagePath,
        [Parameter(Mandatory = $true)][string]$text,

        [string]$fontColor = $FONT_COLOR,
        [string]$backColor = $BACK_COLOR,
        [string]$fontPath = $FONT_PATH,

        [string]$fontSizeValue = $FONT_SIZE,          # % of height
        [string]$paddingValue = $PADDING,            # % of height
        [string]$backRadiusValue = $BACK_RADIUS,        # % of height
        [string]$horizontalOffsetValue = $HORIZONTAL_OFFSET,  # % of width
        [string]$verticalOffsetValue = $VERTICAL_OFFSET,    # % of height
        [string]$horizontalAlign = $HORIZONTAL_ALIGN,
        [string]$verticalAlign = $VERTICAL_ALIGN,

        # NEW: remove the input image (your raw temp copy) on success
        [bool]$CleanupInput = $true
    )

    function Normalize-IMColor([string]$c) {
        if (-not $c) { return $null }
        $t = $c.Trim()
        if ($t -match '^#([0-9A-Fa-f]{8})$') {
            $hex = $matches[1]
            $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
            $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
            $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
            $a = [Convert]::ToInt32($hex.Substring(6, 2), 16) / 255
            return "rgba($r,$g,$b,$a)"
        }
        return $t
    }
    function To-Fraction([string]$v) {
        if ([string]::IsNullOrWhiteSpace($v)) { return 0.0 }
        $s = $v.Trim().Replace("%", "")
        if (-not ($s -match "^[0-9]*\.?[0-9]+$")) { return 0.0 }
        $n = [double]$s
        if ($n -le 1.0) { return $n } else { return $n / 100.0 }
    }

    # Work dir for this render (prevents name collisions and eases cleanup)
    $workDir = Join-Path $TEMP_IMAGE_PATH ("ovl_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    try {
        # 1) Read image dimensions
        $dims = & magick "$imagePath" -format "%w %h" info:
        if ($LASTEXITCODE -ne 0 -or -not $dims) { throw "Could not read image dimensions." }
        $imgW, $imgH = ($dims -split ' ') | ForEach-Object { [int]$_ }

        # 2) Percentages → pixels
        $fontFrac = To-Fraction $fontSizeValue
        $padFrac = To-Fraction $paddingValue
        $radFrac = To-Fraction $backRadiusValue
        $offXFrac = To-Fraction $horizontalOffsetValue
        $offYFrac = To-Fraction $verticalOffsetValue

        # 3) Font sizing
        $widthBudgetPct = 0.88
        $minFontFrac = 0.02
        $maxFontFrac = 0.10
        $pointSize = [math]::Round($imgH * ([math]::Min($maxFontFrac, [math]::Max($minFontFrac, $fontFrac))))
        $maxBoxW = [math]::Floor($imgW * $widthBudgetPct)

        # 4) Gravity (for anchor logic only)
        $gX = switch (($horizontalAlign ?? "center").ToLower()) { 
            "left" { "West" } "center" { "Center" } "right" { "East" } default { "Center" } 
        }
        $gY = switch (($verticalAlign ?? "bottom").ToLower()) { 
            "top" { "North" } "center" { "Center" } "bottom" { "South" } default { "South" } 
        }

        # 5) Render label + shrink-to-fit
        $label = Join-Path $workDir "label.png"
        function RenderLabel([int]$pt) {
            Remove-Item -Path $label -ErrorAction SilentlyContinue
            & magick -background none -fill "$fontColor" -font "$fontPath" -pointsize $pt label:"$text" -alpha set "$label"
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $label)) { return $null }
            $d = & magick "$label" -format "%w %h" info:
            if (-not $d) { return $null }
            $w, $h = ($d -split ' ') | ForEach-Object { [int]$_ }
            return @{W = $w; H = $h }
        }
        $m = RenderLabel $pointSize
        if (-not $m) { throw "Initial label render failed." }
        while ($m.W -gt $maxBoxW -and $pointSize -gt [math]::Round($imgH * $minFontFrac)) {
            $pointSize = [math]::Max([math]::Round($imgH * $minFontFrac), $pointSize - [math]::Ceiling([math]::Max(1, $pointSize * 0.08)))
            $m = RenderLabel $pointSize
            if (-not $m) { throw "Label render failed during shrink-to-fit." }
        }
        $labelW, $labelH = [int]$m.W, [int]$m.H

        # 6) Padding & radius
        $padPx = [math]::Max(2, [math]::Round([math]::Max($imgH * $padFrac, $pointSize * 0.45)))
        $radPx = [math]::Round([math]::Max($imgH * $radFrac, $pointSize * 0.35))
        $targetW = $labelW + 2 * $padPx
        $targetH = $labelH + 2 * $padPx
        $effRad = [math]::Min($radPx, [math]::Floor([math]::Min($targetW, $targetH) / 2))

        # 7) Background pill
        $backColorNorm = Normalize-IMColor $backColor
        $transparentBg = -not ($backColorNorm -and $backColorNorm.Trim().ToLower() -notin @("none", "transparent"))

        $labelWithBg = Join-Path $workDir "label_bg.png"
        Remove-Item -Path $labelWithBg -ErrorAction SilentlyContinue
        if ($transparentBg) {
            & magick "$label" -alpha set -bordercolor none -border $padPx "$labelWithBg"
        }
        else {
            $bg = Join-Path $workDir "bg.png"
            $draw = "roundrectangle 0,0 $($targetW-1),$($targetH-1) $effRad,$effRad"
            & magick -size "${targetW}x${targetH}" canvas:none -alpha set -fill "$backColorNorm" -draw "$draw" "$bg"
            & magick "$bg" -alpha set "$label" -alpha set -gravity center -compose over -composite "$labelWithBg"
            Remove-Item -Path $bg -ErrorAction SilentlyContinue
        }

        # 8) Shadow
        $shadowed = Join-Path $workDir "label_shadow.png"
        & magick "$labelWithBg" -alpha set "(" "+clone" "-alpha" "set" "-background" "black" "-shadow" "60x3+3+3" ")" `
            "+swap" "-background" "none" "-layers" "merge" "+repage" -alpha set "$shadowed"

        # 9) Compute anchor coordinates (NorthWest gravity always)
        $anchorX = switch ($gX) {
            "West" { [math]::Round($imgW * $offXFrac) }
            "Center" { [math]::Round(($imgW - $targetW) / 2) + [math]::Round($imgW * $offXFrac) }
            "East" { $imgW - $targetW - [math]::Round($imgW * $offXFrac) }
        }
        $anchorY = switch ($gY) {
            "North" { [math]::Round($imgH * $offYFrac) }
            "Center" { [math]::Round(($imgH - $targetH) / 2) + [math]::Round($imgH * $offYFrac) }
            "South" { $imgH - $targetH - [math]::Round($imgH * $offYFrac) }
        }

        # 10) Composite to a DIFFERENT filename than the input
        $inName = [IO.Path]::GetFileNameWithoutExtension($imagePath)
        $inExt = [IO.Path]::GetExtension($imagePath)
        $outPath = Join-Path $TEMP_IMAGE_PATH "$inName.__overlay$inExt"

        Remove-Item -Path $outPath -ErrorAction SilentlyContinue
        & magick "$imagePath" "$shadowed" -gravity NorthWest -geometry +$anchorX+$anchorY -compose over -composite "$outPath"

        # Validate output
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outPath)) {
            throw "Overlay render failed (no output)."
        }
        if (-not (Validate-Poster -filePath $outPath)) {
            throw "Overlay render failed (invalid image)."
        }
        if ((Get-Item $outPath).Length -lt 2048) {
            throw "Overlay render failed (suspiciously small output)."
        }

        # NEW: optionally delete the INPUT (the raw temp copy without __overlay)
        if ($CleanupInput -and (Test-Path -LiteralPath $imagePath)) {
            try {
                Remove-Item -LiteralPath $imagePath -Force -ErrorAction SilentlyContinue
                Log-Message -Type "INF" -Message "Deleted temporary pre-overlay file: $imagePath"
            }
            catch { }
        }

        return $outPath
    }
    finally {
        # Remove all scratch artifacts for this render
        try {
            if (Test-Path -LiteralPath $workDir) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
}


# Function to upload the modified poster back to Plex
function Upload-Poster {
    param (
        [Parameter(Mandatory = $true)][string]$posterPath,
        [Parameter(Mandatory = $true)][string]$metadataId
    )

    # Basic sanity checks
    if (-not (Test-Path -LiteralPath $posterPath)) {
        throw "Upload-Poster: file does not exist: $posterPath"
    }
    if (-not (Validate-Poster -filePath $posterPath)) {
        throw "Upload-Poster: invalid image: $posterPath"
    }
    $size = (Get-Item -LiteralPath $posterPath).Length
    if ($size -lt 2048) {
        throw "Upload-Poster: output too small ($size bytes): $posterPath"
    }

    # Force JPEG uploads for maximum Plex/client compatibility
    $FORCE_JPEG_UPLOAD = [bool]($env:FORCE_JPEG_UPLOAD -eq "true")

    $pathToSend = $posterPath
    $extension = [System.IO.Path]::GetExtension($posterPath).ToLowerInvariant()

    if ($FORCE_JPEG_UPLOAD -and $extension -notin @(".jpg", ".jpeg")) {
        $jpgPath = Join-Path ([System.IO.Path]::GetDirectoryName($posterPath)) (([System.IO.Path]::GetFileNameWithoutExtension($posterPath)) + ".__upload.jpg")
        & magick "$posterPath" -quality 92 "$jpgPath"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jpgPath) -or -not (Validate-Poster -filePath $jpgPath)) {
            throw "Upload-Poster: failed to convert to jpg for upload."
        }
        $pathToSend = $jpgPath
        $extension = ".jpg"
    }

    switch ($extension) {
        ".jpg" { $contentType = "image/jpeg" }
        ".jpeg" { $contentType = "image/jpeg" }
        ".png" { $contentType = "image/png" }
        ".webp" { $contentType = "image/webp" }
        default { $contentType = "application/octet-stream" }
    }

    $uploadUrl = "$PLEX_URL/library/metadata/$metadataId/posters"

    try {
        $bytes = [System.IO.File]::ReadAllBytes($pathToSend)
        Invoke-RestMethod -Uri $uploadUrl `
            -Method POST `
            -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
            -Body $bytes `
            -ContentType $contentType `
            -ErrorAction Stop | Out-Null
        Log-Message -Type "SUC" -Message "Uploaded poster for metadataId=$metadataId"
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to upload poster for metadataId=${metadataId}: $_"
        throw
    }
    finally {
        # Clean up the rendered overlay and any converted upload copy
        foreach ($p in (@($posterPath, $pathToSend) | Select-Object -Unique)) {
            try {
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                    Log-Message -Type "INF" -Message "Deleted temporary file: $p"
                }
            }
            catch { }
        }
    }
}

function Get-PlexCollectionItemIds {
    param(
        [Parameter(Mandatory = $true)][string]$MAINTAINERR_URL,
        [Parameter(Mandatory = $true)][string]$PLEX_URL,
        [Parameter(Mandatory = $true)][string]$PLEX_TOKEN,
        [Parameter(Mandatory = $true)][string]$LibrarySectionId,
        [Parameter(Mandatory = $true)][string]$CollectionName
    )

    # Find the collection ratingKey via Maintainerr proxy
    $collectionsUrl = "$MAINTAINERR_URL/api/media-server/library/$LibrarySectionId/collections"
    try {
        $collectionsResponse = Invoke-RestMethod -Uri $collectionsUrl -ErrorAction Stop
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to query Maintainerr for collections (url: $collectionsUrl). Error: $_"
        return @()
    }

    $found = $collectionsResponse | Where-Object { $_.title -ieq $CollectionName }
    if (-not $found) {
        Log-Message -Type "WRN" -Message "Plex collection '$CollectionName' not found in section $LibrarySectionId."
        return @()
    }

    $collectionId = $found.ratingKey
    if (-not $collectionId) {
        Log-Message -Type "WRN" -Message "Collection '$CollectionName' has no ratingKey returned by Maintainerr; attempting to resolve via Plex API."

        try {
            $plexCollUrl = "$PLEX_URL/library/sections/$LibrarySectionId/collections"
            $plexCollResp = Invoke-RestMethod -Uri $plexCollUrl -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
            $plexColls = @()
            if ($plexCollResp.MediaContainer.Directory) { $plexColls += $plexCollResp.MediaContainer.Directory }
            if ($plexColls -and $plexColls.Count -gt 0) {
                $plexFound = $plexColls | Where-Object { $_.title -ieq $CollectionName } | Select-Object -First 1
                if ($plexFound -and $plexFound.ratingKey) {
                    $collectionId = $plexFound.ratingKey
                    Log-Message -Type "INF" -Message "Resolved ratingKey for collection '$CollectionName' via Plex API: $collectionId"
                }
            }
        }
        catch {
            Log-Message -Type "WRN" -Message "Failed to resolve collection '$CollectionName' via Plex API: $_"
        }
    }

    if (-not $collectionId) {
        Log-Message -Type "WRN" -Message "Collection '$CollectionName' has no ratingKey available; cannot fetch Plex items."
        return @()
    }

    # Fetch items in the collection directly from Plex
    $itemsUrl = "$PLEX_URL/library/metadata/$collectionId/children"
    try {
        $resp = Invoke-RestMethod -Uri $itemsUrl -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed to fetch items for collection '$CollectionName' (id: $collectionId) from Plex at $itemsUrl. Error: $_"
        return @()
    }

    $mc = $resp.MediaContainer
    if (-not $mc) { return @() }

    # Items can be Video/Directory depending on lib type - normalize to an array
    $nodes = @()
    foreach ($name in @('Video', 'Directory', 'Photo', 'Metadata')) {
        if ($mc.$name) { $nodes += $mc.$name }
    }
    if (-not $nodes) { return @() }

    $ids = @()
    foreach ($n in $nodes) {
        # ratingKey is the metadata id = PlexId
        if ($n.ratingKey) { $ids += "$($n.ratingKey)" }
    }
    return @($ids | Select-Object -Unique)
}

function Validate-Poster {
    param (
        [string]$filePath
    )
    try {
        $result = & magick "$filePath" -format "%m" info:
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        else {
            Log-Message -Type "ERR" -Message "File at $filePath is not a valid image (identify failed)."
            return $false
        }
    }
    catch {
        Log-Message -Type "ERR" -Message "File at $filePath is not a valid image. Error: $_"
        return $false
    }
}


# Function to perform janitorial tasks: revert and delete unused posters
function Janitor-Posters {
    param (
        [array]$mediaList,          # List of current Plex media GUIDs
        [array]$maintainerrGUIDs,   # List of GUIDs in the Maintainerr collection
        [hashtable]$newState,       # Current valid state from Process-MediaItems
        [string]$originalImagePath, # Path to original poster images
        [string]$collectionName     # Name of the collection for context/logging
    )

    Log-Message -Type "INF" -Message "Running janitorial logic for collection: $collectionName"

    # Gather all downloaded posters (any image extension)
    $downloadedPosters = Get-ChildItem -Path $originalImagePath -Include *.jpg, *.jpeg, *.png, *.webp -Recurse |
    ForEach-Object { @{ BaseName = $_.BaseName; FullName = $_.FullName } }

    $downloadedGUIDs = $downloadedPosters | Select-Object -ExpandProperty BaseName

    # GUIDs considered valid (in Plex, in Maintainerr, or in newState)
    $validGUIDs = $mediaList + $maintainerrGUIDs + $newState.Keys

    # GUIDs to handle
    $unusedGUIDs = $downloadedGUIDs | Where-Object { $_ -notin $validGUIDs }
    $revertGUIDs = $downloadedGUIDs | Where-Object { $_ -in $mediaList -and $_ -notin $maintainerrGUIDs }

    # Revert posters for media still in Plex but no longer in Maintainerr
    foreach ($guid in $revertGUIDs) {
        $poster = $downloadedPosters | Where-Object { $_.BaseName -eq $guid }
        if ($poster) {
            Log-Message -Type "INF" -Message "Reverting poster for GUID: $guid"
            Revert-ToOriginalPoster -plexId $guid -originalImagePath $poster.FullName
            Remove-Item -Path $poster.FullName -ErrorAction SilentlyContinue
        }
        else {
            Log-Message -Type "WRN" -Message "No poster file found to revert for GUID: $guid"
        }
    }

    # Delete posters for media removed from Plex or no longer valid
    foreach ($guid in $unusedGUIDs) {
        $poster = $downloadedPosters | Where-Object { $_.BaseName -eq $guid }
        if ($poster) {
            Log-Message -Type "INF" -Message "Deleting unused poster for GUID: $guid"
            Remove-Item -Path $poster.FullName -ErrorAction SilentlyContinue
        }
    }
}

function Test-PlexItemExistsLocal {
    param([Parameter(Mandatory = $true)][string]$PlexId)
    try {
        $url = "$PLEX_URL/library/metadata/$PlexId"
        $null = Invoke-RestMethod -Uri $url -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# Where Plex Metadata & DB are mounted in your container
$PLEX_META_DIR = "/plexmeta"

function Remove-LocalPosterById {
    param(
        [Parameter(Mandatory = $true)][string]$PosterId,
        [string]$MetaRoot = $PLEX_META_DIR,
        [switch]$WhatIf
    )
    if (-not (Test-Path $MetaRoot)) {
        Log-Message -Type "WRN" -Message "Metadata root not found at $MetaRoot"
        return 0
    }

    # Find exact filename matches (no extension), avoid anything under 'Contents'
    $deleted = 0
    # Using -Recurse + filtering in pipeline to guarantee exact name match
    Get-ChildItem -Path $MetaRoot -Recurse -File -ErrorAction SilentlyContinue `
    | Where-Object {
        $_.Name -eq $PosterId -and $_.DirectoryName -notmatch '(?i)[/\\]Contents([/\\]|$)'
    } | ForEach-Object {
        if ($WhatIf) {
            Log-Message -Type "INF" -Message "Would delete: $($_.FullName)"
        }
        else {
            try {
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
                Log-Message -Type "INF" -Message "Deleted: $($_.FullName)"
            }
            catch {
                Log-Message -Type "WRN" -Message "Failed to delete $($_.FullName): $_"
            }
        }
    }
    return $deleted
}

function Remove-OldUploadedPosterForItem {
    param(
        [Parameter(Mandatory = $true)][string]$OldUploadId,
        [Parameter(Mandatory = $true)][array]$CurrentPhotosForItem,  # result of Get-PlexPosters -MetadataId <this item>
        [string]$MetaRoot = $PLEX_META_DIR
    )

    if ([string]::IsNullOrWhiteSpace($OldUploadId)) { return }

    # Find the Photo node for the old upload in THIS item’s poster list
    $oldNode = $CurrentPhotosForItem | Where-Object {
        $_.ratingKey -eq "upload://posters/$OldUploadId"
    }

    if (-not $oldNode) {
        # Not present in the item’s posters list anymore → safe to delete locally
        [void](Remove-LocalPosterById -PosterId $OldUploadId -MetaRoot $MetaRoot)
        return
    }

    # Normalize selected flag ("1"/"true" vs "0"/"false")
    $sel = "$($oldNode.selected)".ToLower()
    $isSelected = ($sel -eq "1" -or $sel -eq "true")

    if (-not $isSelected) {
        # Present but NOT selected → safe to delete locally
        [void](Remove-LocalPosterById -PosterId $OldUploadId -MetaRoot $MetaRoot)
    }
    else {
        # Still selected → do NOT delete
        Log-Message -Type "INF" -Message "Old uploaded poster '$OldUploadId' is still selected; skipping local delete."
    }
}

# --- Helper Functions (Extracted from Process-MediaItems) ---

function Get-PlexPosters {
    param([Parameter(Mandatory = $true)][string]$MetadataId)
    $url = "$PLEX_URL/library/metadata/$MetadataId/posters"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed to list posters for ${MetadataId}: $_"
        return @()
    }
    $mc = $resp.MediaContainer
    if (-not $mc) { return @() }
    $photos = @()
    if ($mc.Photo) { $photos += $mc.Photo }
    return @($photos)
}

function Get-UploadPosterIds {
    param([Parameter(Mandatory = $true)][array]$Photos)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Photos) {
        $rk = if ($p.ratingKey) { "$($p.ratingKey)" } elseif ($p.key) { "$($p.key)" } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($rk) -and $rk.StartsWith("upload://posters/")) {
            $ids.Add($rk.Substring("upload://posters/".Length))
        }
    }
    return @($ids | Select-Object -Unique)
}

function Remove-PlexUploadedPoster {
    param(
        [Parameter(Mandatory = $true)][string]$MetadataId,
        [Parameter(Mandatory = $true)][string]$UploadPosterId
    )
    $delUrl = "$PLEX_URL/library/metadata/$MetadataId/posters?url=$( [uri]::EscapeDataString("upload://posters/$UploadPosterId") )"
    try {
        Invoke-RestMethod -Uri $delUrl -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method DELETE -ErrorAction Stop | Out-Null
        Log-Message -Type "INF" -Message "Removed previous uploaded poster $UploadPosterId for $MetadataId"
        return $true
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed to remove uploaded poster $UploadPosterId for $MetadataId. Error: $_"
        return $false
    }
}

function Purge-ItemUploadedOverlays {
    param(
        [Parameter(Mandatory = $true)][string]$MetadataId,
        [Parameter()][object]$PriorState
    )
    try {
        # Prefer the recorded uploadedPosterId from state; fall back to live scan
        $priorUploadedId = $null
        if ($PriorState -is [pscustomobject] -or $PriorState -is [hashtable]) {
            $priorUploadedId = "$($PriorState.uploadedPosterId)"
        }

        $idsToRemove = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($priorUploadedId)) {
            $idsToRemove.Add($priorUploadedId) | Out-Null
        }
        else {
            # Enumerate current uploaded posters; we only use ids to remove local files
            $photos = Get-PlexPosters -MetadataId $MetadataId
            $uploadIds = Get-UploadPosterIds -Photos $photos
            foreach ($i in $uploadIds) { if ($i) { $idsToRemove.Add($i) | Out-Null } }
        }

        foreach ($oldId in ($idsToRemove | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($oldId)) { continue }
            # Delete the physical uploaded file from the Plex metadata tree (no API call)
            [void](Remove-LocalPosterById -PosterId $oldId)
        }

        if ($idsToRemove.Count -gt 0) {
            Log-Message -Type "INF" -Message "Purged (local) uploaded overlay file(s) for ${MetadataId}: $($idsToRemove -join ', ')"
        }
        else {
            Log-Message -Type "INF" -Message "No uploaded overlay files found to purge locally for $MetadataId."
        }
    }
    catch {
        Log-Message -Type "WRN" -Message "Failed local purge of uploaded overlay file(s) for ${MetadataId}: $_"
    }
}

# --- Per-collection order env lists -----------------------------------------
function Split-List([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    return @(
        $s -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" } |
        Select-Object -Unique
    )
}

# Accept both COLLECTIONS_DESC and COLLECTION_DESC (either works)
$env_COLLECTION_ASC = $env:COLLECTION_ASC
$env_COLLECTION_DESC = $env:COLLECTION_DESC 

# Build case-insensitive hashsets for fast membership checks
$script:AscSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:DescSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($n in (Split-List $env_COLLECTION_ASC)) { [void]$script:AscSet.Add($n) }
foreach ($n in (Split-List $env_COLLECTION_DESC)) { [void]$script:DescSet.Add($n) }

function Get-CollectionOrderOverride {
    param([Parameter(Mandatory)][string]$CollectionName)
    $inAsc = $script:AscSet.Contains($CollectionName)
    $inDesc = $script:DescSet.Contains($CollectionName)

    if ($inAsc -and $inDesc) {
        Log-Message -Type "WRN" -Message "Collection '$CollectionName' found in both COLLECTION_ASC and COLLECTIONS_DESC. Using DESC."
        return "asc"
    }
    if ($inAsc) { return "asc" }
    if ($inDesc) { return "desc" }
    return $null  # means: use old/global logic
}
# ----------------------------------------------------------------------------


function Process-MediaItems {

    $collectionsUrl = "$MAINTAINERR_URL/api/collections/overlay-data"

    $maxRetries = 3
    $retryCount = 0
    $maintainerrData = $null

    while ($retryCount -lt $maxRetries) {
        try {
            $maintainerrData = Invoke-RestMethod -Uri $collectionsUrl -Method Get -ErrorAction Stop
            Log-Message -Type "INF" -Message "Fetched collection data from Maintainerr."
            break
        }
        catch {
            $retryCount++
            Log-Message -Type "WRN" -Message "Attempt $retryCount failed to fetch Maintainerr data. Retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }

    if (-not $maintainerrData) {
        Log-Message -Type "ERR" -Message "Failed to fetch Maintainerr data after $maxRetries attempts. Aborting run."
        return
    }

    # Load current state and ensure keys are strings
    $loadedState = Load-CollectionState
    $currentState = @{}
    foreach ($entry in $loadedState.GetEnumerator()) {
        $currentState["$($entry.Key)"] = $entry.Value
    }

    $newState = @{}

    # Gather ACTUAL Plex membership across all processed collections
    $script:AllPlexCollectionIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($collection in $maintainerrData) {
        # Resolve target name (manual vs automatic)
        $TargetCollectionName = Get-TargetCollectionName -Collection $collection
        $IsManual = ($TargetCollectionName -ne $collection.title)
        if ($IsManual) {
            Log-Message -Type "INF" -Message "Detected custom (manual) collection. Using Plex collection name: '$TargetCollectionName' (from manualCollectionName)."
        }
        else {
            Log-Message -Type "DBG" -Message "Using Maintainerr title as Plex collection name: '$TargetCollectionName'."
        }

        Log-Message -Type "INF" -Message "Processing collection: $($collection.title)"
        $deleteAfterDays = $collection.deleteAfterDays
        $LibrarySectionId = $collection.libraryId
        if (-not $LibrarySectionId) { $LibrarySectionId = "2" }
        $CollectionName = $TargetCollectionName

        # Ensure deleteAfterDays is a valid integer (fallback to 0)
        $deleteAfterDaysInt = 0
        if (-not [int]::TryParse($deleteAfterDays, [ref]$deleteAfterDaysInt)) {
            Log-Message -Type "WRN" -Message "Invalid deleteAfterDays value '$deleteAfterDays' for collection '$CollectionName'. Defaulting to 0."
        }

        # Filter by configured list
        if ("*" -notin $collectionsToReorder) {
            $namesToCheck = @("$($collection.title)", "$CollectionName") | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
            $shouldProcess = $false
            foreach ($n in $namesToCheck) {
                if ($n -in $collectionsToReorder) { $shouldProcess = $true; break }
            }
            if (-not $shouldProcess) {
                Log-Message -Type "INF" -Message "Skipping collection: '$($collection.title)' (target: '$CollectionName'). Carrying state forward."
                foreach ($item in $collection.media) {
                    $plexId = "$($item.plexId)"
                    $prior = $currentState["$plexId"]
                    if ($null -ne $prior) {
                        $newState["$plexId"] = $prior
                    }
                    else {
                        $newState["$plexId"] = @{ processed = $false; deleteDate = $null }
                    }
                }
                continue
            }
        }

        # Build sortable list
        $skippedMissingPlexId = 0
        $firstMissingPlexIdItem = $null

        $mediaList = foreach ($item in $collection.media) {
            # Maintainerr items may use different fields for the Plex metadata ID.
            # Prior versions used 'plexId'; newer versions may use 'mediaServerId'.
            $plexId = if ($item.plexId) { "$($item.plexId)" } elseif ($item.mediaServerId) { "$($item.mediaServerId)" } else { "" }

            # Skip if we don't have a valid Plex metadata ID
            if ([string]::IsNullOrWhiteSpace($plexId)) {
                $skippedMissingPlexId++
                if (-not $firstMissingPlexIdItem) { $firstMissingPlexIdItem = $item }
                continue
            }

            # Ensure we have a valid addDate to calculate deletion date
            if (-not $item.addDate) {
                Log-Message -Type "WRN" -Message "Skipping item $plexId because addDate is missing."
                continue
            }

            try {
                $addDate = [datetime]$item.addDate
            }
            catch {
                Log-Message -Type "WRN" -Message "Skipping item $plexId because addDate is invalid: $($_)"
                continue
            }

            $deleteDate = $addDate.AddDays($deleteAfterDaysInt)

            # Output the object to the pipeline so it gets added to $mediaList
            [PSCustomObject]@{
                PlexId     = $plexId
                DeleteDate = $deleteDate
                AddDate    = $addDate
                Item       = $item
            }
        }

        if ($skippedMissingPlexId -gt 0) {
            $preview = ""
            try {
                $preview = ($firstMissingPlexIdItem | ConvertTo-Json -Depth 4) -replace '\s+', ' '
            }
            catch {
                $preview = "<unable to serialize item>"
            }
            Log-Message -Type "WRN" -Message "Skipped $skippedMissingPlexId items with missing Plex ID in collection '$CollectionName'. Example item: $preview"
        }

        # Capture ACTUAL Plex membership for this collection
        $plexCollectionIds = Get-PlexCollectionItemIds -MAINTAINERR_URL $MAINTAINERR_URL `
            -PLEX_URL $PLEX_URL -PLEX_TOKEN $PLEX_TOKEN `
            -LibrarySectionId $LibrarySectionId -CollectionName $CollectionName

        foreach ($id in $plexCollectionIds) { [void]$script:AllPlexCollectionIds.Add("$id") }

        # If Maintainerr reports nothing, carry state forward using actual Plex collection items
        if (-not $mediaList -or $mediaList.Count -eq 0) {
            Log-Message -Type "INF" -Message "Collection '$CollectionName' has no items from Maintainerr. Carrying state forward from Plex and skipping."
            foreach ($mid in $plexCollectionIds) {
                $mid = "$mid"
                $prior = $currentState[$mid]
                if ($null -ne $prior) {
                    $newState[$mid] = $prior
                }
                else {
                    $newState[$mid] = @{ processed = $false; deleteDate = $null }
                }
            }
            continue
        }

        $sortedMedia = $mediaList | Sort-Object -Property DeleteDate

        foreach ($media in $sortedMedia) {
            $item = $media.Item
            $plexId = $media.PlexId

            # New deletion date
            $deleteDateUtc = ($media.DeleteDate).ToUniversalTime()
            $newDeleteDateIso = $deleteDateUtc.ToString("o")

            # Read prior state 
            $prior = $currentState["$plexId"]
            $priorProcessed = $false
            $priorDeleteDateIso = $null
            $priorUploadedPosterId = $null
            $priorDaysLeftShown = $null

            if ($prior -is [bool]) { $priorProcessed = $prior }
            elseif ($prior -is [string]) { $priorProcessed = ($prior -eq "true") }
            elseif ($prior -is [pscustomobject] -or $prior -is [hashtable]) {
                $priorProcessed = (("$($prior.processed)") -eq "True")
                $priorDeleteDateIso = "$($prior.deleteDate)"
                $priorUploadedPosterId = "$($prior.uploadedPosterId)"
                $priorDaysLeftShown = if ($prior.PSObject.Properties.Match("daysLeftShown")) { [int]$prior.daysLeftShown } else { $null }
            }

            # Compare on date-only
            function To-DateOnlyIso([datetime]$dt) { return $dt.ToUniversalTime().ToString("yyyy-MM-dd") }
            $priorDateOnly = $null
            if ($priorDeleteDateIso) {
                try { $priorDateOnly = (Get-Date $priorDeleteDateIso).ToUniversalTime().ToString("yyyy-MM-dd") } catch { $priorDateOnly = $priorDeleteDateIso }
            }
            $newDateOnly = To-DateOnlyIso $media.DeleteDate

            $needsReoverlayDueToDateChange = $false
            if ($priorProcessed -and $priorDateOnly) {
                if ($priorDateOnly -ne $newDateOnly) {
                    $needsReoverlayDueToDateChange = $true
                    Log-Message -Type "INF" -Message "Delete date changed for $plexId. Old=$priorDateOnly New=$newDateOnly → will rebuild overlay."
                }
            }

            # If using days-left overlays, force rebuild when the *number of days* changes
            $calc = Get-DaysLeft -addDate $media.AddDate -deleteAfterDays $deleteAfterDaysInt
            $currentDaysLeft = [int]$calc.DaysLeft
            if ($USE_DAYS -and $priorProcessed) {
                if ($priorDaysLeftShown -ne $currentDaysLeft) {
                    $needsReoverlayDueToDateChange = $true
                    Log-Message -Type "INF" -Message "Days-left changed for $plexId. Old=$priorDaysLeftShown New=$currentDaysLeft → will rebuild overlay."
                }
            }

            # Case 1: Already processed, date unchanged, and reapply disabled - skip (carry state forward)
            if (-not $needsReoverlayDueToDateChange -and -not $REAPPLY_OVERLAY -and $priorProcessed) {
                Log-Message -Type "INF" -Message "Skipping Plex ID: $plexId (already processed; date unchanged)."
                $newState["$plexId"] = @{
                    processed        = $true
                    deleteDate       = $deleteDateUtc.ToString("o")
                    uploadedPosterId = $priorUploadedPosterId
                    daysLeftShown    = $(if ($USE_DAYS) { $currentDaysLeft } else { $priorDaysLeftShown })
                }
                continue
            }

            try {
                # Always base overlay on the ORIGINAL file if available else download ONCE and keep.
                $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
                if ($posterFiles -and $posterFiles.Count -gt 0) {
                    $originalImagePath = $posterFiles[0].FullName
                    Log-Message -Type "INF" -Message "Using saved original for $plexId ($([IO.Path]::GetExtension($originalImagePath)))"
                }
                else {
                    $posterUrl = Get-BestPlexImageUrl -MetadataId $plexId
                    if (-not $posterUrl) {
                        Log-Message -Type "WRN" -Message "No usable image found for Plex ID: $plexId (server=$PLEX_URL). Skipping."
                        $newState["$plexId"] = @{
                            processed        = $false
                            deleteDate       = $newDeleteDateIso
                            uploadedPosterId = $priorUploadedPosterId
                            daysLeftShown    = $(if ($USE_DAYS) { $currentDaysLeft } else { $null })
                        }
                        continue
                    }
                    Log-Message -Type "WRN" -Message "Original poster not found for $plexId. Downloading once and saving as original..."
                    $originalImagePath = Download-Poster -posterUrl $posterUrl -savePathBase ("$ORIGINAL_IMAGE_PATH/$plexId")
                }

                $prePhotos = Get-PlexPosters -MetadataId $plexId
                $preUploadIds = Get-UploadPosterIds -Photos $prePhotos

                # Build overlay from ORIGINAL - TEMP - upload
                $ext = [System.IO.Path]::GetExtension($originalImagePath)
                $tempImagePath = Join-Path $TEMP_IMAGE_PATH "$plexId$ext"
                Copy-Item -Path $originalImagePath -Destination $tempImagePath -Force

                # Build the overlay text based on mode
                if ($USE_DAYS) {
                    # Fully-custom strings from env (TEXT_TODAY / TEXT_DAY / TEXT_DAYS)
                    $labelText = Format-LeavingText -daysLeft $currentDaysLeft
                }
                else {
                    # Classic date mode uses OVERLAY_TEXT + formatted date internally
                    $labelText = Format-LeavingText -daysLeft $currentDaysLeft -addDate $item.addDate -deleteAfterDays $deleteAfterDays
                }

                $tempImagePath = Add-Overlay -imagePath $tempImagePath -text $labelText
                Upload-Poster -posterPath $tempImagePath -metadataId $plexId

                    
                # --- POST: snapshot again and diff
                $postPhotos = Get-PlexPosters -MetadataId $plexId
                $postUploadIds = Get-UploadPosterIds -Photos $postPhotos

                $newIds = @($postUploadIds | Where-Object { $_ -notin $preUploadIds })
                if ($newIds.Count -gt 0) {
                    $newUploadId = $newIds[0]

                    # Prefer item-scoped selection truth over DB snapshot (handles eventual consistency)
                    if ($priorUploadedPosterId -and $priorUploadedPosterId -ne $newUploadId) {
                        Remove-OldUploadedPosterForItem -OldUploadId $priorUploadedPosterId -CurrentPhotosForItem $postPhotos
                    }

                    # FORCE-SELECT THE NEWLY UPLOADED POSTER
                    $null = Select-UploadedPoster -MetadataId $plexId -UploadPosterId $newUploadId

                    $newState["$plexId"] = @{
                        processed        = $true
                        deleteDate       = $newDeleteDateIso
                        uploadedPosterId = $newUploadId
                        daysLeftShown    = $(if ($USE_DAYS) { $currentDaysLeft } else { $null })
                    }
                    Log-Message -Type "INF" -Message "Updated state for ${plexId}: processed=true, deleteDate=$newDeleteDateIso, uploadedPosterId=$newUploadId"
                }
                else {
                    $newState["$plexId"] = @{
                        processed        = $true
                        deleteDate       = $newDeleteDateIso
                        uploadedPosterId = $priorUploadedPosterId
                        daysLeftShown    = $(if ($USE_DAYS) { $currentDaysLeft } else { $null })
                    }
                    Log-Message -Type "WRN" -Message "No new upload id detected for $plexId; keeping uploadedPosterId='$priorUploadedPosterId'"
                }


            }
            catch {
                Log-Message -Type "WRN" -Message "Failed to process Plex ID: $plexId. Error: $_"
            }
        }

        # --- Reorder collection -----------------------------------
        $sortedPlexIds = @($sortedMedia | ForEach-Object { $_.PlexId })  # force array
        if (-not $sortedPlexIds -or $sortedPlexIds.Count -eq 0) {
            Log-Message -Type "INF" -Message "Skipping reorder for '$CollectionName' (Maintainerr reports no items)."
            continue
        }
        if ($sortedPlexIds.Count -eq 1) {
            Log-Message -Type "INF" -Message "Skipping reorder for '$CollectionName' (only one item)."
            continue
        }

        # Ensure memberships match before reordering
        $maintSet = @($sortedPlexIds | Sort-Object -Unique)
        $plexSet = @($plexCollectionIds | Sort-Object -Unique)
        $maintOnly = Compare-Object -ReferenceObject $maintSet -DifferenceObject $plexSet -PassThru | Where-Object { $_ -in $maintSet }
        $plexOnly = Compare-Object -ReferenceObject $plexSet  -DifferenceObject $maintSet -PassThru | Where-Object { $_ -in $plexSet }
        if ($maintOnly.Count -gt 0 -or $plexOnly.Count -gt 0) {
            Log-Message -Type "WRN" -Message ("Collection membership mismatch for '$CollectionName'. " +
                "Maintainerr-only: [{0}] | Plex-only: [{1}]" -f ($maintOnly -join ','), ($plexOnly -join ','))
            Log-Message -Type "INF" -Message "Skipping reorder until memberships match."
            continue
        }
        Set-PlexCollectionOrder `
            -MAINTAINERR_URL $MAINTAINERR_URL `
            -PLEX_URL $PLEX_URL `
            -PLEX_TOKEN $PLEX_TOKEN `
            -LibrarySectionId $LibrarySectionId `
            -CollectionName $CollectionName `
            -SortedPlexIds $sortedPlexIds
        # ----------------------------------------------------------------------
    }

    # --- Robust removals: confirm with ACTUAL Plex membership -----------------
    $currentKeys = @($currentState.Keys | ForEach-Object { "$_" })

    foreach ($plexId in $currentKeys) {
        $inNewState = $newState.ContainsKey("$plexId")
        $inPlexCollections = $script:AllPlexCollectionIds.Contains("$plexId")

        if (-not $inNewState -and -not $inPlexCollections) {
            Log-Message -Type "INF" -Message "Item $plexId confirmed removed (not in newState AND not in Plex collections)."

            # Find saved original (if any)
            $posterFiles = Get-ChildItem -Path $ORIGINAL_IMAGE_PATH -Include "$plexId.*" -Recurse -ErrorAction SilentlyContinue
            $originalImagePath = if ($posterFiles) { $posterFiles[0].FullName } else { $null }

            if (-not $originalImagePath -or -not (Test-Path -Path $originalImagePath)) {
                Log-Message -Type "WRN" -Message "Original poster not found for Plex ID: $plexId. Purging any leftover uploaded overlays and skipping revert."
                # Even if original is missing, still try to purge uploaded overlays from Plex & disk
                Purge-ItemUploadedOverlays -MetadataId $plexId -PriorState $currentState["$plexId"]
                continue
            }

            # If the item no longer exists at all in Plex, just delete saved original and any lingering uploaded overlays
            if (-not (Test-PlexItemExistsLocal -PlexId $plexId)) {
                Log-Message -Type "INF" -Message "Plex ID: $plexId no longer exists in Plex. Purging overlays and deleting saved original."
                Purge-ItemUploadedOverlays -MetadataId $plexId -PriorState $currentState["$plexId"]
                Remove-Item -Path $originalImagePath -Force -ErrorAction SilentlyContinue
                continue
            }

            # Purge uploaded overlays FIRST (Plex poster entry + local metadata file), then revert
            Purge-ItemUploadedOverlays -MetadataId $plexId -PriorState $currentState["$plexId"]

            Log-Message -Type "INF" -Message "Reverting Plex ID: $plexId to original poster."
            $ok = Revert-ToOriginalPoster -plexId $plexId -originalImagePath $originalImagePath
            if ($ok) {
                Remove-Item -Path $originalImagePath -Force -ErrorAction SilentlyContinue
                Log-Message -Type "INF" -Message "Deleted original poster after revert for Plex ID $plexId."
            }
            continue
        }
        elseif (-not $inNewState -and $inPlexCollections) {
            # Maintainerr didn't return media item; item is still in Plex collection—carry forward state
            Log-Message -Type "WRN" -Message "Item $plexId absent from Maintainerr this run, but present in Plex collection — skipping revert and carrying state."
            $prior = $currentState["$plexId"]
            if ($null -ne $prior) {
                $newState["$plexId"] = $prior
            }
            else {
                $newState["$plexId"] = @{ processed = $false; deleteDate = $null }
            }
            continue
        }
        else {
            Log-Message -Type "INF" -Message "Item $plexId is still in the collection."
        }
    }

    # Janitorial cleanup — use ACTUAL Plex membership
    $plexGUIDs = @($script:AllPlexCollectionIds)
    $maintainerrGUIDs = $newState.Keys
    Janitor-Posters -mediaList $plexGUIDs -maintainerrGUIDs $maintainerrGUIDs -newState $newState -originalImagePath $ORIGINAL_IMAGE_PATH -collectionName "All Media"

    # Save updated state (string keys)
    $tempState = @{}
    foreach ($key in $newState.Keys) {
        $tempState["$key"] = $newState[$key]
    }
    Log-Message -Type "INF" -Message "Saving State: $(ConvertTo-Json $tempState -Depth 10)"
    Save-CollectionState -state $newState
}



if (-not (Test-Path -Path $IMAGE_SAVE_PATH)) {
    New-Item -ItemType Directory -Path $IMAGE_SAVE_PATH
}
if (-not (Test-Path -Path $ORIGINAL_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $ORIGINAL_IMAGE_PATH
}
if (-not (Test-Path -Path $TEMP_IMAGE_PATH)) {
    New-Item -ItemType Directory -Path $TEMP_IMAGE_PATH
}

function Set-PlexCollectionOrder {
    param(
        [Parameter(Mandatory = $true)][string]$MAINTAINERR_URL,
        [Parameter(Mandatory = $true)][string]$PLEX_TOKEN,
        [Parameter(Mandatory = $true)][string]$PLEX_URL,
        [Parameter(Mandatory = $true)][string]$LibrarySectionId,
        [Parameter(Mandatory = $true)][string]$CollectionName,
        [Parameter(Mandatory = $true)][array]$SortedPlexIds
    )

    # Determine order for THIS collection
    $order = Get-CollectionOrderOverride -CollectionName $CollectionName

    if (-not $order) {
        # Fall back to old/global logic
        $order = $env:PLEX_COLLECTION_ORDER
        if (-not $order) { $order = "asc" }
        $order = $order.ToLower()
        Log-Message -Type "INF" -Message "Using global order '$order' for collection '$CollectionName'."
    }
    else {
        Log-Message -Type "INF" -Message "Using per-collection order '$order' for collection '$CollectionName'."
    }

    switch ($order) {
        "asc" { $finalOrder = $SortedPlexIds }
        "desc" {
            $finalOrder = $SortedPlexIds.Clone()
            [Array]::Reverse($finalOrder)
        }
        default {
            Log-Message -Type "WRN" -Message "Unknown order '$order' for '$CollectionName', defaulting to ascending."
            $finalOrder = $SortedPlexIds
        }
    }

    # 1) Find collection (via Maintainerr proxy)
    $collectionsUrl = "$MAINTAINERR_URL/api/media-server/library/$LibrarySectionId/collections"
    try {
        $collectionsResponse = Invoke-RestMethod -Uri $collectionsUrl -ErrorAction Stop
        $foundCollection = $collectionsResponse | Where-Object { $_.title -ieq $CollectionName }
        if (-not $foundCollection) {
            Log-Message -Type "ERR" -Message "Could not find collection '$CollectionName' in library section $LibrarySectionId."
            return
        }
        $collectionId = $foundCollection.ratingKey
        if (-not $collectionId) {
            Log-Message -Type "WRN" -Message "Collection '$CollectionName' has no ratingKey in Maintainerr response; falling back to Plex API."
            try {
                $plexCollUrl = "$PLEX_URL/library/sections/$LibrarySectionId/collections"
                $plexCollResp = Invoke-RestMethod -Uri $plexCollUrl -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } -Method GET -ErrorAction Stop
                $plexColls = @()
                if ($plexCollResp.MediaContainer.Directory) { $plexColls += $plexCollResp.MediaContainer.Directory }
                if ($plexColls -and $plexColls.Count -gt 0) {
                    $plexFound = $plexColls | Where-Object { $_.title -ieq $CollectionName } | Select-Object -First 1
                    if ($plexFound -and $plexFound.ratingKey) {
                        $collectionId = $plexFound.ratingKey
                        Log-Message -Type "INF" -Message "Resolved collection '$CollectionName' via Plex API (ratingKey $collectionId)."
                    }
                }
            }
            catch {
                Log-Message -Type "WRN" -Message "Failed to resolve collection '$CollectionName' via Plex API: $_"
            }
        }

        if (-not $collectionId) {
            Log-Message -Type "ERR" -Message "Could not determine ratingKey for collection '$CollectionName'. Aborting reorder."
            return
        }

        Log-Message -Type "INF" -Message "Found collection '$CollectionName' (ratingKey $collectionId) in library section $LibrarySectionId."
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to retrieve collections from Maintainerr in section ${LibrarySectionId}: $_"
        return
    }

    # 2) Put collection into custom sort mode (collectionSort=2)
    $setCustomSortUrl = "$PLEX_URL/library/metadata/$collectionId/prefs"
    $body = "collectionSort=2"
    try {
        Invoke-RestMethod -Uri $setCustomSortUrl `
            -Method PUT `
            -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
            -Body $body `
            -ContentType "application/x-www-form-urlencoded" `
            -ErrorAction Stop
        Log-Message -Type "INF" -Message "Set collection '$CollectionName' to custom sort mode."
    }
    catch {
        Log-Message -Type "ERR" -Message "Failed to set collection '$CollectionName' to custom sort: $_"
        return
    }

    # 3) Move each item after the previous
    for ($i = 1; $i -lt $finalOrder.Count; $i++) {
        $itemId = $finalOrder[$i]
        $afterId = $finalOrder[$i - 1]
        $moveUrl = "$PLEX_URL/library/collections/$collectionId/items/$itemId/move?after=$afterId"
        try {
            Invoke-RestMethod -Uri $moveUrl `
                -Method PUT `
                -Headers @{ "X-Plex-Token" = $PLEX_TOKEN } `
                -ErrorAction Stop
            Log-Message -Type "INF" -Message "Moved item $itemId after $afterId in collection $collectionId."
        }
        catch {
            Log-Message -Type "ERR" -Message "Failed to move item $itemId after '$afterId': $_"
        }
    }

    Log-Message -Type "SUC" -Message "Finished reordering collection '$CollectionName' ($order) with custom sort."
}


if ($RESET_OVERLAY) {
    Log-Message -Type "INF" -Message "RESET_OVERLAY is enabled. Reverting all processed posters and clearing state..."
    Reset-AllOverlays
    
    exit 0
}

Process-MediaItems