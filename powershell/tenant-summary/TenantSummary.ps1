2e3\w<#
.SYNOPSIS
    Retrieve Fortify on Demand tenant summary via the FoD API.
.DESCRIPTION
    Retrieves a bearer token (client_credentials or password grant) and calls
    the /api/v3/tenant-summary endpoint. Outputs JSON to stdout.
.PARAMETER FodURL
    Base FoD API URL (defaults to https://api.ams.fortify.com)
.PARAMETER FodClientId
    Client ID for client_credentials token flow.
.PARAMETER FodClientSecret
    Client Secret for client_credentials token flow.
.PARAMETER FodUsername
    Username for password grant.
.PARAMETER FodPassword
    Password for password grant.
.PARAMETER FodTenant
    Tenant code (required for password grant; username is qualified as Tenant\Username)
#>

[CmdletBinding(DefaultParameterSetName='Auto')]
param(
    [string]$FodURL = 'https://api.ams.fortify.com',
    [string]$FodClientId,
    [string]$FodClientSecret,
    [string]$FodUsername,
    [string]$FodPassword,
    [string]$FodTenant,
    [ValidateSet('table','json','csv','excel')]
    [string]$Format = 'table',
    [string]$OutFile,
    [switch]$Graph,
    [string]$GraphOutFile,
    [string]$IgnoreFields = 'staticAnalysisDVIdx,dynamicAnalysisDVIdx,mobileAnalysisDVIdx,criticalUrl,highUrl,mediumUrl,lowUrl,oneStarRatingDVIdx,twoStarRatingDVIdx,threeStarRatingDVIdx,fourStarRatingDVIdx,fiveStarRatingDVIdx'
)

function Convert-FormHashToString {
    param(
        [hashtable]$Form
    )
    $pairs = @()
    foreach ($k in $Form.Keys) {
        $v = $Form[$k]
        $enc = [System.Net.WebUtility]::UrlEncode([string]$v)
        $pairs += "$k=$enc"
    }
    return ($pairs -join '&')
}

function Create-StackedHorizontalChart {
    param(
        [Parameter(Mandatory=$true)][string[]]$Categories,
        [Parameter(Mandatory=$true)][hashtable]$SeriesData, # key = series name, value = array of numeric values matching categories
        [Parameter(Mandatory=$true)][string]$OutFilePath,
        [int]$Width = 900,
        [int]$Height = 600
    )
    try {
        Add-Type -AssemblyName System.Drawing
    } catch {
        throw "System.Drawing not available: $($_.Exception.Message)"
    }

    $palette = @(
        [System.Drawing.Color]::FromArgb(0xE6,0x4C,0x3C),
        [System.Drawing.Color]::FromArgb(0xF1,0xA9,0x2C),
        [System.Drawing.Color]::FromArgb(0xF4,0xD0,0x3A),
        [System.Drawing.Color]::FromArgb(0x2E,0xCC,0x71),
        [System.Drawing.Color]::FromArgb(0x52,0x9A,0xD0),
        [System.Drawing.Color]::FromArgb(0x9B,0x59,0xB6)
    )
    # preferred color map for severity series
    $colorMap = @{
        'Critical' = [System.Drawing.Color]::Red
        'High'     = [System.Drawing.Color]::Orange
        'Medium'   = [System.Drawing.Color]::Yellow
        'Low'      = [System.Drawing.Color]::Gray
    }

    # sort series names by total count (ascending) so stacks render from smallest to largest
    $seriesNames = $SeriesData.Keys | Sort-Object {
        $vals = $SeriesData[$_]
        if ($null -eq $vals) { 0 } else { ($vals | ForEach-Object {[double]$_} | Measure-Object -Sum).Sum }
    }

    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $font = New-Object System.Drawing.Font 'Segoe UI',10
    $brush = [System.Drawing.Brushes]::Black

    $leftMargin = 180
    $rightMargin = 80
    $topMargin = 20
    $gap = 20
    $barAreaWidth = $Width - $leftMargin - $rightMargin
    $catCount = $Categories.Count
    $barHeight = [math]::Floor((($Height - $topMargin*2) - ($gap * ($catCount-1))) / $catCount)

    # compute max total across categories
    $maxTotal = 0
    for ($ci=0; $ci -lt $catCount; $ci++) {
        $sum = 0
        foreach ($sName in $SeriesData.Keys) {
            $vals = $SeriesData[$sName]
            $v = 0
            if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
            $sum += $v
        }
        if ($sum -gt $maxTotal) { $maxTotal = $sum }
    }
    if ($maxTotal -le 0) { $maxTotal = 1 }

    $seriesNames = $SeriesData.Keys
    $si = 0
    foreach ($ci in (0..($catCount-1))) {
        $y = $topMargin + ($ci * ($barHeight + $gap))
        # draw category label
        $catLabel = $Categories[$ci]
        $g.DrawString($catLabel, $font, $brush, 6, $y + ($barHeight/2) - 8)

        $x = $leftMargin
        $sIndex = 0
        foreach ($sName in $seriesNames) {
            $vals = $SeriesData[$sName]
            $v = 0
            if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
            $segWidth = [math]::Round(($v / $maxTotal) * $barAreaWidth)
            $rect = New-Object System.Drawing.Rectangle $x, $y, $segWidth, $barHeight
            if ($colorMap.ContainsKey($sName)) { $col = $colorMap[$sName] } else { $col = $palette[$sIndex % $palette.Count] }
            $brushSeg = New-Object System.Drawing.SolidBrush $col
            $g.FillRectangle($brushSeg, $rect)
            # label inside if space (skip zero values)
            if ($v -ne 0) {
                $label = $sName
                $labelSize = $g.MeasureString($label, $font)
                if ($segWidth -gt $labelSize.Width + 6) {
                    $g.DrawString($label, $font, [System.Drawing.Brushes]::White, $x + 4, $y + ($barHeight/2) - 8)
                } else {
                    # draw label to right of segment
                    $g.DrawString($label, $font, $brush, $x + $segWidth + 4, $y + ($barHeight/2) - 8)
                }
            }
            $x += $segWidth
            $sIndex++
        }
    }

    # draw legend on right (ensure it fits inside image)
    $legendX = $leftMargin + $barAreaWidth + 8
    $legendY = $topMargin
    $maxLegendStart = $Width - $rightMargin - 120
    if ($legendX -gt $maxLegendStart) { $legendX = $maxLegendStart }
    $idx = 0
    foreach ($sName in $seriesNames) {
        $col = $palette[$idx % $palette.Count]
        $brushSeg = New-Object System.Drawing.SolidBrush $col
        $g.FillRectangle($brushSeg, $legendX, $legendY + ($idx*20), 14, 14)
        $g.DrawString($sName, $font, $brush, $legendX + 18, $legendY + ($idx*20) - 2)
        $idx++
    }

    $bmp.Save($OutFilePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

function Create-StackedColumnChart {
    param(
        [Parameter(Mandatory=$true)][string[]]$Categories,
        [Parameter(Mandatory=$true)][hashtable]$SeriesData,
        [Parameter(Mandatory=$true)][string]$OutFilePath,
        [int]$Width = 900,
        [int]$Height = 600
    )
    try {
        Write-Verbose 'Create-StackedColumnChart (GDI): start'
        Add-Type -AssemblyName System.Drawing
    } catch {
        throw "System.Drawing not available: $($_.Exception.Message)"
    }

    $palette = @(
        [System.Drawing.Color]::FromArgb(0xE6,0x4C,0x3C),
        [System.Drawing.Color]::FromArgb(0xF1,0xA9,0x2C),
        [System.Drawing.Color]::FromArgb(0xF4,0xD0,0x3A),
        [System.Drawing.Color]::FromArgb(0x2E,0xCC,0x71),
        [System.Drawing.Color]::FromArgb(0x52,0x9A,0xD0),
        [System.Drawing.Color]::FromArgb(0x9B,0x59,0xB6)
    )

    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $font = New-Object System.Drawing.Font 'Segoe UI',10
    $brush = [System.Drawing.Brushes]::Black

    $leftMargin = 80
    $rightMargin = 120
    $topMargin = 40
    $bottomMargin = 100
    $gap = 20

    $barAreaWidth = $Width - $leftMargin - $rightMargin
    $barAreaHeight = $Height - $topMargin - $bottomMargin
    $catCount = $Categories.Count
    if ($catCount -le 0) { throw 'No categories provided' }

    $barWidth = [math]::Floor(($barAreaWidth - ($gap * ($catCount - 1))) / $catCount)
    if ($barWidth -le 0) { $barWidth = 10 }

    # compute max total across categories
    $maxTotal = 0
    for ($ci=0; $ci -lt $catCount; $ci++) {
        $sum = 0
        foreach ($sName in $SeriesData.Keys) {
            $vals = $SeriesData[$sName]
            $v = 0
            if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
            $sum += $v
        }
        if ($sum -gt $maxTotal) { $maxTotal = $sum }
    }
    if ($maxTotal -le 0) { $maxTotal = 1 }

    $seriesNames = $SeriesData.Keys
    try {
        for ($ci=0; $ci -lt $catCount; $ci++) {
        $x = $leftMargin + ($ci * ($barWidth + $gap))
        $yBase = $topMargin + $barAreaHeight
        $accum = 0
        $sIndex = 0
        foreach ($sName in $seriesNames) {
            $vals = $SeriesData[$sName]
            $v = 0
            if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
            $segHeight = [math]::Round(($v / $maxTotal) * $barAreaHeight)
            $rectY = $yBase - $accum - $segHeight
            $rect = New-Object System.Drawing.Rectangle $x, $rectY, $barWidth, $segHeight
            $col = $palette[$sIndex % $palette.Count]
            $brushSeg = New-Object System.Drawing.SolidBrush $col
            $g.FillRectangle($brushSeg, $rect)
            # label - use series name inside segment if space
            if ($v -ne 0) {
                $label = $sName
                $labelSize = $g.MeasureString($label, $font)
                if ($segHeight -gt $labelSize.Height + 6 -and $barWidth -gt $labelSize.Width + 6) {
                    $g.DrawString($label, $font, [System.Drawing.Brushes]::White, $x + 4, $rectY + 4)
                } else {
                    # draw label to the right of segment if space
                    if ($segHeight -gt 0) { $g.DrawString($label, $font, $brush, $x + $barWidth + 4, $rectY + ($segHeight/2) - ($labelSize.Height/2)) }
                }
            }
            $accum += $segHeight
            $sIndex++
        }
        # draw category label
        $catLabel = $Categories[$ci]
        $lblSize = $g.MeasureString($catLabel, $font)
        $g.DrawString($catLabel, $font, $brush, $x + (($barWidth - $lblSize.Width)/2), $topMargin + $barAreaHeight + 6)
    }

    } catch {
        Write-Error "Create-StackedColumnChart (GDI) failed: $($_.Exception.Message)"
        Write-Error ($_.Exception | Format-List * -Force | Out-String)
        throw
    }

    # draw legend on right (show name and total count)
    $legendX = $leftMargin + $barAreaWidth + 8
    $legendY = $topMargin
    $idx = 0
    foreach ($sName in $seriesNames) {
        if ($colorMap.ContainsKey($sName)) { $col = $colorMap[$sName] } else { $col = $palette[$idx % $palette.Count] }
        $brushSeg = New-Object System.Drawing.SolidBrush $col
        $g.FillRectangle($brushSeg, $legendX, $legendY + ($idx*20), 14, 14)
        $sum = 0
        if ($SeriesData.ContainsKey($sName) -and $null -ne $SeriesData[$sName]) { foreach ($val in $SeriesData[$sName]) { $sum += [double]$val } }
        $label = "$sName ($sum)"
        $g.DrawString($label, $font, $brush, $legendX + 18, $legendY + ($idx*20) - 2)
        $idx++
    }

    $bmp.Save($OutFilePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

function Create-StackedHorizontalChart_ChartControl {
    param(
        [Parameter(Mandatory=$true)][string[]]$Categories,
        [Parameter(Mandatory=$true)][hashtable]$SeriesData,
        [Parameter(Mandatory=$true)][string]$OutFilePath,
        [int]$Width = 900,
        [int]$Height = 600
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        Add-Type -AssemblyName System.Drawing
    } catch {
        throw "Charting assemblies not available: $($_.Exception.Message)"
    }

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Width
    $chart.Height = $Height

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea 'Main'
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisY.MajorGrid.Enabled = $false
    $area.AxisX.LabelStyle.Format = ''
    $chart.ChartAreas.Add($area)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend 'L'
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Right
    $legend.Alignment = [System.Drawing.StringAlignment]::Near
    $chart.Legends.Add($legend)

    $palette = @(
        [System.Drawing.Color]::FromArgb(0xE6,0x4C,0x3C),
        [System.Drawing.Color]::FromArgb(0xF1,0xA9,0x2C),
        [System.Drawing.Color]::FromArgb(0xF4,0xD0,0x3A),
        [System.Drawing.Color]::FromArgb(0x2E,0xCC,0x71),
        [System.Drawing.Color]::FromArgb(0x52,0x9A,0xD0),
        [System.Drawing.Color]::FromArgb(0x9B,0x59,0xB6)
    )

    $seriesNames = $SeriesData.Keys
    $sIndex = 0
    foreach ($sName in $seriesNames) {
        $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series $sName
        $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::StackedBar
        $s.IsValueShownAsLabel = $true
        # ensure categories are treated as indexed X-values so categories appear on Y axis for StackedBar
        $s.IsXValueIndexed = $true
        $s.Legend = $legend.Name
        $chart.Series.Add($s)
        $sIndex++
    }

    # add points per category (use indexed X values so categories become Y-axis labels with StackedBar)
    for ($ci=0; $ci -lt $Categories.Count; $ci++) {
        $cat = $Categories[$ci]
        foreach ($sName in $seriesNames) {
            $vals = $SeriesData[$sName]
            $v = 0
            if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
            $pt = $chart.Series[$sName].Points.AddXY($cat, $v)
            # set the axis label for the indexed point (helps ensure category labels show on Y axis)
            $chart.Series[$sName].Points[$pt].AxisLabel = $cat
            # hide label for zero values
                if ($v -eq 0) { $chart.Series[$sName].Points[$pt].Label = '' } else { $chart.Series[$sName].Points[$pt].Label = $sName }
        }
    }

    # configure axes for horizontal bars
    $area.AxisY.Interval = 1
    $area.AxisY.LabelStyle.Enabled = $true
    $area.AxisX.LabelStyle.Format = ''

    # apply palette colors
    $si = 0
    foreach ($sName in $seriesNames) {
        if ($colorMap.ContainsKey($sName)) { $col = $colorMap[$sName] } else { $col = $palette[$si % $palette.Count] }
        $chart.Series[$sName].Color = $col
        # set legend text to include the sum/count (guard against null SeriesData)
        $sum = 0
        if ($SeriesData.ContainsKey($sName) -and $null -ne $SeriesData[$sName]) {
            foreach ($val in $SeriesData[$sName]) { $sum += [double]$val }
        }
        $chart.Series[$sName].LegendText = "$sName ($sum)"
        $si++
    }

    $chart.SaveImage($OutFilePath, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Create-StackedColumnChart_ChartControl {
    param(
        [Parameter(Mandatory=$true)][string[]]$Categories,
        [Parameter(Mandatory=$true)][hashtable]$SeriesData,
        [Parameter(Mandatory=$true)][string]$OutFilePath,
        [int]$Width = 900,
        [int]$Height = 600
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        Add-Type -AssemblyName System.Drawing
    } catch {
        throw "Charting assemblies not available: $($_.Exception.Message)"
    }

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    try {
        Write-Verbose 'Create-StackedColumnChart_ChartControl: start'
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        Add-Type -AssemblyName System.Drawing

        $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
        $chart.Width = $Width
        $chart.Height = $Height

        $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea 'Main'
        $area.AxisX.MajorGrid.Enabled = $false
        $area.AxisY.MajorGrid.Enabled = $false
        $chart.ChartAreas.Add($area)

        $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend 'L'
        $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Right
        $chart.Legends.Add($legend) | Out-Null

        $palette = @(
            [System.Drawing.Color]::FromArgb(0xE6,0x4C,0x3C),
            [System.Drawing.Color]::FromArgb(0xF1,0xA9,0x2C),
            [System.Drawing.Color]::FromArgb(0xF4,0xD0,0x3A),
            [System.Drawing.Color]::FromArgb(0x2E,0xCC,0x71),
            [System.Drawing.Color]::FromArgb(0x52,0x9A,0xD0),
            [System.Drawing.Color]::FromArgb(0x9B,0x59,0xB6)
        )

        $colorMap = @{
            'Critical' = [System.Drawing.Color]::Red
            'High'     = [System.Drawing.Color]::Orange
            'Medium'   = [System.Drawing.Color]::Yellow
            'Low'      = [System.Drawing.Color]::Gray
        }

        # sort series names by total count (ascending)
        $seriesNames = $SeriesData.Keys | Sort-Object {
            $vals = $SeriesData[$_]
            if ($null -eq $vals) { 0 } else { ($vals | ForEach-Object {[double]$_} | Measure-Object -Sum).Sum }
        }
        foreach ($sName in $seriesNames) {
            $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series ($sName)
            $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::StackedColumn
            $s.IsValueShownAsLabel = $true
            $s.Legend = $legend.Name
            $chart.Series.Add($s) | Out-Null
        }

        for ($ci=0; $ci -lt $Categories.Count; $ci++) {
            $cat = $Categories[$ci]
            foreach ($sName in $seriesNames) {
                $vals = $SeriesData[$sName]
                $v = 0
                if ($ci -lt $vals.Count) { $v = [double]$vals[$ci] }
                $ptIndex = $chart.Series[$sName].Points.AddXY($cat, $v)
                if ($v -eq 0) { $chart.Series[$sName].Points[$ptIndex].Label = '' } else { $chart.Series[$sName].Points[$ptIndex].Label = $sName }
            }
        }

        $si = 0
        foreach ($sName in $seriesNames) {
            if ($colorMap.ContainsKey($sName)) { $col = $colorMap[$sName] } else { $col = $palette[$si % $palette.Count] }
            $chart.Series[$sName].Color = $col
            $sum = 0
            if ($SeriesData.ContainsKey($sName) -and $null -ne $SeriesData[$sName]) { foreach ($val in $SeriesData[$sName]) { $sum += [double]$val } }
            $chart.Series[$sName].LegendText = "$sName ($sum)"
            $si++
        }

        $chart.SaveImage($OutFilePath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Verbose 'Create-StackedColumnChart_ChartControl: done'
    } catch {
        Write-Error "Create-StackedColumnChart_ChartControl failed: $($_.Exception.Message)"
        Write-Error ($_.Exception | Format-List * -Force | Out-String)
        throw
    }
    }

    try {
    if ($FodClientId -and $FodClientSecret) {
        Write-Verbose 'Using client_credentials token flow.'
        $form = @{ 
            scope = 'api-tenant'
            grant_type = 'client_credentials'
            client_id = $FodClientId
            client_secret = $FodClientSecret
        }
        $body = Convert-FormHashToString -Form $form
        $tokenResp = Invoke-RestMethod -Uri "$FodURL/oauth/token" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } elseif ($FodUsername -and $FodPassword -and $FodTenant) {
        Write-Verbose 'Using password token flow (username/password).' 
        $qualifiedUser = "$FodTenant\$FodUsername"
        $form = @{
            scope = 'api-tenant'
            grant_type = 'password'
            username = $qualifiedUser
            password = $FodPassword
        }
        $body = Convert-FormHashToString -Form $form
        $tokenResp = Invoke-RestMethod -Uri "$FodURL/oauth/token" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    } else {
        throw 'Please supply either (FodClientId and FodClientSecret) OR (FodTenant, FodUsername and FodPassword).'
    }

    if (-not $tokenResp.access_token) {
        throw 'Token response did not contain an access_token.'
    }
    $accessToken = $tokenResp.access_token

    $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Accept' = 'application/json' }
    $uri = "$FodURL/api/v3/tenant-summary"
    Write-Verbose "Requesting $uri"
    $summary = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop

    # Prepare rows and apply IgnoreFields filtering so ignored fields are not printed/exported/used in charts
    $rows = if ($summary.items) { $summary.items } else { ,$summary }
    $ignore = @()
    if ($IgnoreFields) { $ignore = $IgnoreFields -split ',' | ForEach-Object { $_.Trim() } }
    $filteredRows = @()
    foreach ($r in $rows) {
        $props = $r | Get-Member -MemberType NoteProperty,Property | Select-Object -ExpandProperty Name
        $ht = @{}
        foreach ($p in $props) {
            if ($ignore -contains $p) { continue }
            $ht[$p] = $r.$p
        }
        $filteredRows += New-Object PSObject -Property $ht
    }

    $origFirst = $rows | Select-Object -First 1

    # Normalize OutFile and GraphOutFile: treat relative paths as relative to the script directory
    if ($OutFile) {
        if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path -Path $PSScriptRoot -ChildPath $OutFile }
        $OutFile = [System.IO.Path]::GetFullPath($OutFile)
    }
    if ($GraphOutFile) {
        if (-not [System.IO.Path]::IsPathRooted($GraphOutFile)) { $GraphOutFile = Join-Path -Path $PSScriptRoot -ChildPath $GraphOutFile }
        $GraphOutFile = [System.IO.Path]::GetFullPath($GraphOutFile)
    }

    # Determine output
    if ($Format -eq 'excel' -and -not $OutFile) {
        throw 'Excel output requires an OutFile to be specified.'
    }

    switch ($Format) {
        'json' {
            if ($summary.items) {
                $outSummary = $summary
                $outSummary.items = $filteredRows
                $out = $outSummary | ConvertTo-Json -Depth 10
            } else {
                $out = $filteredRows | ConvertTo-Json -Depth 10
            }
            if ($OutFile) { $out | Out-File -FilePath $OutFile -Encoding utf8 } else { $out }
        }
        'csv' {
            # Flatten items for CSV: take .items array if present
            $rowsToExport = $filteredRows
            if ($OutFile) { $rowsToExport | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8 } else { $rowsToExport | Format-Table -AutoSize }

            if ($Graph) {
                # Build stacked chart data from original numeric counts
                $firstOrig = $origFirst
                $static = 0; $dynamic = 0; $mobile = 0; $critical = 0; $high = 0; $medium = 0; $low = 0
                if ($firstOrig) {
                    if ($null -ne $firstOrig.staticAnalysisCount) { $static = [int]$firstOrig.staticAnalysisCount }
                    if ($null -ne $firstOrig.dynamicAnalysisCount) { $dynamic = [int]$firstOrig.dynamicAnalysisCount }
                    if ($null -ne $firstOrig.mobileAnalysisCount) { $mobile = [int]$firstOrig.mobileAnalysisCount }
                    if ($null -ne $firstOrig.criticalCount) { $critical = [int]$firstOrig.criticalCount }
                    if ($null -ne $firstOrig.highCount) { $high = [int]$firstOrig.highCount }
                    if ($null -ne $firstOrig.mediumCount) { $medium = [int]$firstOrig.mediumCount }
                    if ($null -ne $firstOrig.lowCount) { $low = [int]$firstOrig.lowCount }
                }
            # sort series names by total count (ascending)
            $seriesNames = $SeriesData.Keys | Sort-Object {
                $vals = $SeriesData[$_]
                if ($null -eq $vals) { 0 } else { ($vals | ForEach-Object {[double]$_} | Measure-Object -Sum).Sum }
            }
                # Only include Issues category (omit Analyses column which is tiny/unseen)
                $categories = @('Issues')
                $seriesData = [ordered]@{
                    'Critical' = @($critical)
                    'High'     = @($high)
                    'Medium'   = @($medium)
                    'Low'      = @($low)
                }

                $gout = $GraphOutFile
                if (-not $gout) {
                    if ($OutFile) { $gout = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($OutFile), '.png') } else { $gout = [System.IO.Path]::GetFullPath('tenant-summary.png') }
                } else {
                    $gout = [System.IO.Path]::GetFullPath($gout)
                }
                Write-Verbose "SeriesData keys: $($seriesData.Keys -join ', ')"
                Write-Verbose "Out PNG: $gout"
                # create chart (try chart control, fallback to GDI), log detailed errors
                try {
                    Write-Verbose 'Attempting chart-control renderer'
                    Create-StackedColumnChart_ChartControl -Categories $categories -SeriesData $seriesData -OutFilePath $gout
                    Write-Verbose 'Chart-control renderer succeeded'
                } catch {
                    Write-Verbose "Chart-control renderer failed: $($_.Exception.Message)"
                    try {
                        Write-Verbose 'Falling back to GDI renderer'
                        Create-StackedColumnChart -Categories $categories -SeriesData $seriesData -OutFilePath $gout
                        Write-Verbose 'GDI renderer succeeded'
                    } catch {
                        Write-Error "Chart render failed (GDI): $($_.Exception.Message)"
                        Write-Error ($_.Exception | Format-List * -Force | Out-String)
                        throw
                    }
                }
                Write-Verbose "Stacked graph written to $gout"
            }
        }
        'excel' {
            # Prefer ImportExcel module (Export-Excel). If not available, try COM automation.
            $rows = $filteredRows
            if (Get-Module -ListAvailable -Name ImportExcel) {
                try {
                    Import-Module ImportExcel -ErrorAction Stop
                    $exportRows = $filteredRows
                    $exportRows | Export-Excel -Path $OutFile -WorksheetName 'TenantSummary' -AutoSize -TableName 'TenantSummary'
                    if ($Graph) {
                        # Build small chart data table and add a stacked chart via COM
                        $fullPath = [System.IO.Path]::GetFullPath($OutFile)
                        $excel = New-Object -ComObject Excel.Application
                        $excel.Visible = $false
                        $wb = $excel.Workbooks.Open($fullPath)
                        $sheet = $wb.Worksheets.Item(1)
                        # Create ChartData sheet
                        $chartSheet = $null
                        try { $chartSheet = $wb.Worksheets.Item('ChartData') } catch { $chartSheet = $wb.Worksheets.Add(); $chartSheet.Name = 'ChartData' }
                        # Prepare chart table: header + two rows
                        $headers = @('Category','Static','Dynamic','Mobile','Critical','High','Medium','Low')
                        for ($c=0; $c -lt $headers.Count; $c++) { $chartSheet.Cells.Item(1,$c+1).Value2 = $headers[$c] }
                        $firstOrig = $origFirst
                        # Use original $rows for counts where available; fallback to 0
                        $static = 0; $dynamic = 0; $mobile = 0; $critical = 0; $high = 0; $medium = 0; $low = 0
                        if ($firstOrig) {
                            if ($null -ne $firstOrig.staticAnalysisCount) { $static = [int]$firstOrig.staticAnalysisCount }
                            if ($null -ne $firstOrig.dynamicAnalysisCount) { $dynamic = [int]$firstOrig.dynamicAnalysisCount }
                            if ($null -ne $firstOrig.mobileAnalysisCount) { $mobile = [int]$firstOrig.mobileAnalysisCount }
                            if ($null -ne $firstOrig.criticalCount) { $critical = [int]$firstOrig.criticalCount }
                            if ($null -ne $firstOrig.highCount) { $high = [int]$firstOrig.highCount }
                            if ($null -ne $firstOrig.mediumCount) { $medium = [int]$firstOrig.mediumCount }
                            if ($null -ne $firstOrig.lowCount) { $low = [int]$firstOrig.lowCount }
                        }
                        $chartSheet.Cells.Item(2,1).Value2 = 'Analyses'
                        $chartSheet.Cells.Item(2,2).Value2 = $static
                        $chartSheet.Cells.Item(2,3).Value2 = $dynamic
                        $chartSheet.Cells.Item(2,4).Value2 = $mobile
                        $chartSheet.Cells.Item(2,5).Value2 = 0
                        $chartSheet.Cells.Item(2,6).Value2 = 0
                        $chartSheet.Cells.Item(2,7).Value2 = 0
                        $chartSheet.Cells.Item(2,8).Value2 = 0
                        $chartSheet.Cells.Item(3,1).Value2 = 'Issues'
                        $chartSheet.Cells.Item(3,2).Value2 = 0
                        $chartSheet.Cells.Item(3,3).Value2 = 0
                        $chartSheet.Cells.Item(3,4).Value2 = 0
                        $chartSheet.Cells.Item(3,5).Value2 = $critical
                        $chartSheet.Cells.Item(3,6).Value2 = $high
                        $chartSheet.Cells.Item(3,7).Value2 = $medium
                        $chartSheet.Cells.Item(3,8).Value2 = $low
                        $rng = $chartSheet.Range($chartSheet.Cells.Item(1,1), $chartSheet.Cells.Item(3,8))
                        $chartObj = $sheet.ChartObjects().Add(300,10,500,300)
                        $chart = $chartObj.Chart
                        $chart.SetSourceData($rng)
                        $chart.ChartType = 57
                        $wb.Save()
                        $wb.Close($true)
                        $excel.Quit()
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($chartSheet) | Out-Null
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($sheet) | Out-Null
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
                    }
                } catch {
                    throw "Failed to export to Excel via ImportExcel: $($_.Exception.Message)"
                }
            } else {
                # COM fallback
                try {
                    $excel = New-Object -ComObject Excel.Application
                    $excel.Visible = $false
                    $workbook = $excel.Workbooks.Add()
                    $sheet = $workbook.Worksheets.Item(1)

                    # Build header row from property names
                    $exportRows = $filteredRows
                    $first = $rows | Select-Object -First 1
                    $cols = $first | Get-Member -MemberType NoteProperty,Property | Select-Object -ExpandProperty Name
                    for ($c=0; $c -lt $cols.Count; $c++) {
                        $sheet.Cells.Item(1, $c+1).Value2 = $cols[$c]
                    }
                    $rowIndex = 2
                    foreach ($r in $rows) {
                        for ($c=0; $c -lt $cols.Count; $c++) {
                            $val = $r.$($cols[$c])
                            $sheet.Cells.Item($rowIndex, $c+1).Value2 = if ($null -eq $val) { '' } else { [string]$val }
                        }
                        $rowIndex++
                    }
                    $fullPath = [System.IO.Path]::GetFullPath($OutFile)
                    $dir = Split-Path $fullPath -Parent
                    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
                    # If graph requested, add ChartData sheet and stacked chart before saving
                    if ($Graph) {
                        try {
                            $chartSheet = $workbook.Worksheets.Add()
                            $chartSheet.Name = 'ChartData'
                            $headers = @('Category','Static','Dynamic','Mobile','Critical','High','Medium','Low')
                            for ($c=0; $c -lt $headers.Count; $c++) { $chartSheet.Cells.Item(1,$c+1).Value2 = $headers[$c] }
                            $static = 0; $dynamic = 0; $mobile = 0; $critical = 0; $high = 0; $medium = 0; $low = 0
                            if ($first) {
                                if ($null -ne $first.staticAnalysisCount) { $static = [int]$first.staticAnalysisCount }
                                if ($null -ne $first.dynamicAnalysisCount) { $dynamic = [int]$first.dynamicAnalysisCount }
                                if ($null -ne $first.mobileAnalysisCount) { $mobile = [int]$first.mobileAnalysisCount }
                                if ($null -ne $first.criticalCount) { $critical = [int]$first.criticalCount }
                                if ($null -ne $first.highCount) { $high = [int]$first.highCount }
                                if ($null -ne $first.mediumCount) { $medium = [int]$first.mediumCount }
                                if ($null -ne $first.lowCount) { $low = [int]$first.lowCount }
                            }
                            $chartSheet.Cells.Item(2,1).Value2 = 'Analyses'
                            $chartSheet.Cells.Item(2,2).Value2 = $static
                            $chartSheet.Cells.Item(2,3).Value2 = $dynamic
                            $chartSheet.Cells.Item(2,4).Value2 = $mobile
                            $chartSheet.Cells.Item(2,5).Value2 = 0
                            $chartSheet.Cells.Item(2,6).Value2 = 0
                            $chartSheet.Cells.Item(2,7).Value2 = 0
                            $chartSheet.Cells.Item(2,8).Value2 = 0
                            $chartSheet.Cells.Item(3,1).Value2 = 'Issues'
                            $chartSheet.Cells.Item(3,2).Value2 = 0
                            $chartSheet.Cells.Item(3,3).Value2 = 0
                            $chartSheet.Cells.Item(3,4).Value2 = 0
                            $chartSheet.Cells.Item(3,5).Value2 = $critical
                            $chartSheet.Cells.Item(3,6).Value2 = $high
                            $chartSheet.Cells.Item(3,7).Value2 = $medium
                            $chartSheet.Cells.Item(3,8).Value2 = $low
                            $rng = $chartSheet.Range($chartSheet.Cells.Item(1,1), $chartSheet.Cells.Item(3,8))
                            $chartObj = $sheet.ChartObjects().Add(300,10,500,300)
                            $chart = $chartObj.Chart
                            $chart.SetSourceData($rng)
                            $chart.ChartType = 57
                        } catch { Write-Verbose "Failed to add chart to workbook before save: $($_.Exception.Message)" }
                    }
                    # 51 = xlOpenXMLWorkbook (xlsx)
                    $workbook.SaveAs($fullPath, 51)
                    $workbook.Close($false)
                    $excel.Quit()
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($sheet) | Out-Null
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
                } catch {
                    throw "Failed to export to Excel via COM: $($_.Exception.Message)"
                }
            }
        }
        default {
            # table (default) - choose to display items array if present
            if ($summary.items) {
                $outRows = $filteredRows
            } else {
                $outRows = $filteredRows
            }
            if ($OutFile) {
                # Write a textual table to file
                $outRows | Format-Table -AutoSize | Out-String | Out-File -FilePath $OutFile -Encoding utf8
            } else {
                $outRows | Format-Table -AutoSize
            }
            # If graph requested, build dataset from first row excluding ignore fields and create PNG
            if ($Graph) {
                # Build stacked chart with two categories: Analyses (static/dynamic/mobile) and Issues (critical/high/medium/low)
                $firstOrig = $origFirst
                $static = 0; $dynamic = 0; $mobile = 0; $critical = 0; $high = 0; $medium = 0; $low = 0
                if ($firstOrig) {
                    if ($null -ne $firstOrig.staticAnalysisCount) { $static = [int]$firstOrig.staticAnalysisCount }
                    if ($null -ne $firstOrig.dynamicAnalysisCount) { $dynamic = [int]$firstOrig.dynamicAnalysisCount }
                    if ($null -ne $firstOrig.mobileAnalysisCount) { $mobile = [int]$firstOrig.mobileAnalysisCount }
                    if ($null -ne $firstOrig.criticalCount) { $critical = [int]$firstOrig.criticalCount }
                    if ($null -ne $firstOrig.highCount) { $high = [int]$firstOrig.highCount }
                    if ($null -ne $firstOrig.mediumCount) { $medium = [int]$firstOrig.mediumCount }
                    if ($null -ne $firstOrig.lowCount) { $low = [int]$firstOrig.lowCount }
                }
                # Only include Issues column (use single-element arrays so index 0 maps to 'Issues')
                $categories = @('Issues')
                $seriesData = [ordered]@{
                    'Critical' = @($critical)
                    'High'     = @($high)
                    'Medium'   = @($medium)
                    'Low'      = @($low)
                }
                $gout = $GraphOutFile
                if (-not $gout) { $gout = [System.IO.Path]::GetFullPath('tenant-summary.png') } else { $gout = [System.IO.Path]::GetFullPath($gout) }
                Write-Verbose "SeriesData keys: $($seriesData.Keys -join ', ')"
                Write-Verbose "Out PNG: $gout"
                try {
                    Write-Verbose 'Attempting chart-control renderer'
                    Create-StackedColumnChart_ChartControl -Categories $categories -SeriesData $seriesData -OutFilePath $gout
                    Write-Verbose 'Chart-control renderer succeeded'
                } catch {
                    Write-Verbose "Chart-control renderer failed: $($_.Exception.Message)"
                    try {
                        Write-Verbose 'Falling back to GDI renderer'
                        Create-StackedColumnChart -Categories $categories -SeriesData $seriesData -OutFilePath $gout
                        Write-Verbose 'GDI renderer succeeded'
                    } catch {
                        Write-Error "Chart render failed (GDI): $($_.Exception.Message)"
                        Write-Error ($_.Exception | Format-List * -Force | Out-String)
                        throw
                    }
                }
                Write-Verbose "Stacked graph written to $gout"
            }
        }
    }
} catch {
    Write-Error "Failed: $($_.Exception.Message)"
    try { Write-Error ($_.Exception | Format-List * -Force | Out-String) } catch {}
    if ($_.Exception.Response) {
        try {
            $body = $_.Exception.Response | Select-Object -ExpandProperty Content -ErrorAction Stop
            Write-Error "Response: $body"
        } catch { }
    }
    exit 1
}
