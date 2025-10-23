# DAGLIG OVERSIKT MED RIGGETIDER
# Viser arrangementer sortert etter riggetid, med tekniker, arrangør og arr.tid
# Hvert event kan ha flere rigg-funksjoner som vises på egne linjer

$clientID = "45i054svbmkrvb8hijo5st2koh"
$clientSecret = "722e0kdr3govijh6trqjdjemk91us89il3368amhhmqc42sod24"

$tokenResponse = Invoke-RestMethod -Uri 'https://auth-api.eu-venueops.com/token' -Method Post -Body (@{
    clientSecret = $clientSecret
    clientId = $clientID
} | ConvertTo-Json) -ContentType "application/json"

$headers = @{
    Authorization = "Bearer $($tokenResponse.accessToken)"
}

# Dagens dato og tid
$today = (Get-Date).ToString("yyyy-MM-dd")
$todayNorsk = (Get-Date).ToString("dd.MM.yyyy")
$ukedag = (Get-Date).ToString("dddd", [System.Globalization.CultureInfo]::GetCultureInfo("nb-NO"))
$currentTime = Get-Date

# Hent funksjoner
$functions = Invoke-RestMethod -Uri "https://api.eu-venueops.com/v1/functions?startDate=$today&endDate=$today" -Method Get -Headers $headers

# Filtrer og forbered data med riggetider
$arrangementer = $functions | Where-Object {$_.functionTypeName -eq 'Arrangement' -and $_.functionStatus -ne "canceled"}
$rigg = $functions | Where-Object {$_.functionTypeName -eq 'Rigg' -and $_.functionStatus -ne "canceled"}
$verter = $functions | Where-Object {$_.functionTypeName -eq 'Vert'} | Sort-Object startTime

# Hent ALLE tekniker-funksjoner
$alleTeknikere = $functions | Where-Object {$_.functionTypeName -eq 'Tekniker' -and $_.functionStatus -ne "canceled"}

# Prøv å finne tekniker-info fra functions
$teknikere1 = @()
$teknikere2 = @()

foreach ($tek in $alleTeknikere) {
    # Hver tekniker-funksjon kan ha flere staff assignments
    if ($tek.staffAssignments -and $tek.staffAssignments.Count -gt 0) {
        foreach ($staff in $tek.staffAssignments) {
            # Sjekk om dette er FTekniker1
            if ($staff.staffAssignmentName -like "*FTekniker*1*" -or 
                $staff.staffAssignmentId -eq "e4d0b7e4a9e043f496f44544dc46e33a") {
                
                # Lag en kopi av funksjonen for FTekniker1
                $tek1 = $tek | Select-Object -Property *
                $tek1 | Add-Member -NotePropertyName "assignedStaffName" -NotePropertyValue $staff.staffMemberName -Force
                $tek1 | Add-Member -NotePropertyName "assignedStaffId" -NotePropertyValue $staff.staffMemberId -Force
                $tek1 | Add-Member -NotePropertyName "assignmentType" -NotePropertyValue "FTekniker1" -Force
                $teknikere1 += $tek1
            }
            # Sjekk om dette er FTekniker2
            elseif ($staff.staffAssignmentName -like "*FTekniker*2*" -or 
                    $staff.staffAssignmentId -eq "db0b05695ae84f9fa2d599c9892ad036") {
                
                # Lag en kopi av funksjonen for FTekniker2
                $tek2 = $tek | Select-Object -Property *
                $tek2 | Add-Member -NotePropertyName "assignedStaffName" -NotePropertyValue $staff.staffMemberName -Force
                $tek2 | Add-Member -NotePropertyName "assignedStaffId" -NotePropertyValue $staff.staffMemberId -Force
                $tek2 | Add-Member -NotePropertyName "assignmentType" -NotePropertyValue "FTekniker2" -Force
                $teknikere2 += $tek2
            }
        }
    }
    # Fallback: Hvis ingen staffAssignments, prøv å parse navnet
    elseif ($tek.name -match "Tekniker\s+(.+)") {
        # Dette er sannsynligvis en FTekniker1 basert på navn
        $tek | Add-Member -NotePropertyName "assignedStaffName" -NotePropertyValue $Matches[1].Trim() -Force
        $tek | Add-Member -NotePropertyName "assignmentType" -NotePropertyValue "FTekniker1" -Force
        $teknikere1 += $tek
    }
}

# Hent event-detaljer for å få accountName
$eventCache = @{}
foreach ($arr in $arrangementer) {
    if ($arr.eventId -and -not $eventCache.ContainsKey($arr.eventId)) {
        try {
            $eventDetails = Invoke-RestMethod -Uri "https://api.eu-venueops.com/v1/events/$($arr.eventId)" -Method Get -Headers $headers
            $eventCache[$arr.eventId] = $eventDetails
        } catch {
            $eventCache[$arr.eventId] = $null
        }
    }
}

# NYE LOGIKK: Én linje per arrangement-funksjon, med kombinert rigg-info for samme rom
$arrangementerMedRigg = @()
foreach ($arr in $arrangementer) {
    # Finn ALLE rigg-funksjoner som matcher eventName OG roomId (samme rom som arrangementet)
    $riggFunksjoner = $rigg | Where-Object { $_.eventName -eq $arr.eventName -and $_.roomId -eq $arr.roomId }
    
    $riggInfo = $null
    $riggCount = 0
    
    if ($riggFunksjoner -and $riggFunksjoner.Count -gt 0) {
        # Bruk tidligste start og siste slutt hvis det er flere rigg-funksjoner
        $earliestStart = ($riggFunksjoner | Sort-Object startTime | Select-Object -First 1).startTime
        $latestEnd = ($riggFunksjoner | Sort-Object endTime -Descending | Select-Object -First 1).endTime
        $riggCount = $riggFunksjoner.Count
        
        $riggInfo = @{
            StartTime = $earliestStart
            EndTime = $latestEnd
            Count = $riggCount
        }
    }
    
    # Lag én linje per arrangement-funksjon
    $arrangementerMedRigg += [PSCustomObject]@{
        Arrangement = $arr
        RiggInfo = $riggInfo
        SortTimeStart = if ($riggInfo) { $riggInfo.StartTime } else { $arr.startTime }
        ArrStartTime = $arr.startTime
    }
}

# Sorter først på rigg STARTTID, deretter på arrangement STARTTID
$arrangementerSortert = $arrangementerMedRigg | Sort-Object SortTimeStart, ArrStartTime

# Funksjon for å forkorte romnavn
function Short-Room {
    param([string]$room)
    $room = $room -replace "^room-", ""
    $room = $room -replace "\s*\([^)]*\)", ""
    
    # Returner full navn med padding for alignment
    switch ($room.ToLower()) {
        "wergeland" { return "Werge" }
        "skram" { return "Skram" }
        "berner" { return "Berne" }
        "nedjma" { return "Nedjm" }
        "kverneland" { return "Kvern" }
        "riverton" { return "River" }
        "vestly" { return "Vestl" }
        default { 
            if ($room.Length -gt 10) {
                return $room.Substring(0, 10)
            } else {
                return $room.PadRight(10)
            }
        }
    }
}

# Funksjon for å hente teknikere basert på eventName OG roomId
function Get-TechnicianNames {
    param($eventName, $roomId)
    
    $teknikere = @()
    
    # Sjekk FTekniker1
    foreach ($t in $teknikere1) {
        if ($t.eventName -eq $eventName -and $t.roomId -eq $roomId) {
            $navn = $null
            
            # Bruk assignedStaffName som vi la til
            if ($t.assignedStaffName) {
                $navn = $t.assignedStaffName
            } elseif ($t.name -match "Tekniker\s+(.+)") {
                $navn = $Matches[1].Trim()
            }
            
            if ($navn) {
                # Få kun fornavn
                if ($navn -match " ") {
                    $navn = ($navn -split ' ')[0]
                }
                if ($navn.Length -gt 6) {
                    $navn = $navn.Substring(0, 6)
                }
                if ($navn -ne "Trenger" -and $navn -ne "Trengs") {
                    $teknikere += $navn
                }
            }
        }
    }
    
    # Sjekk FTekniker2
    foreach ($t in $teknikere2) {
        if ($t.eventName -eq $eventName -and $t.roomId -eq $roomId) {
            $navn = $null
            
            # Bruk assignedStaffName som vi la til
            if ($t.assignedStaffName) {
                $navn = $t.assignedStaffName
            } elseif ($t.name -match "Tekniker\s+(.+)") {
                $navn = $Matches[1].Trim()
            }
            
            if ($navn) {
                # Få kun fornavn
                if ($navn -match " ") {
                    $navn = ($navn -split ' ')[0]
                }
                if ($navn.Length -gt 6) {
                    $navn = $navn.Substring(0, 6)
                }
                if ($navn -ne "Trenger" -and $navn -ne "Trengs") {
                    $teknikere += $navn
                }
            }
        }
    }
    
    # Returner teknikernavn eller standardverdier
    if ($teknikere.Count -eq 0) {
        return "-"
    } elseif ($teknikere.Count -eq 1) {
        return $teknikere[0]
    } else {
        return $teknikere -join ","
    }
}

# Funksjon for å sjekke om et event pågår nå
function Is-EventActive {
    param($startTime, $endTime)
    
    $now = Get-Date
    $eventStart = Get-Date -Hour ([int]($startTime.Split(':')[0])) -Minute ([int]($startTime.Split(':')[1])) -Second 0
    $eventEnd = Get-Date -Hour ([int]($endTime.Split(':')[0])) -Minute ([int]($endTime.Split(':')[1])) -Second 0
    
    return ($now -ge $eventStart -and $now -le $eventEnd)
}

# Funksjon for å sjekke om vi er mellom rigg og arrangement
function Is-BetweenRiggAndEvent {
    param($riggEndTime, $eventStartTime)
    
    if (-not $riggEndTime) { return $false }
    
    $now = Get-Date
    $riggEnd = Get-Date -Hour ([int]($riggEndTime.Split(':')[0])) -Minute ([int]($riggEndTime.Split(':')[1])) -Second 0
    $eventStart = Get-Date -Hour ([int]($eventStartTime.Split(':')[0])) -Minute ([int]($eventStartTime.Split(':')[1])) -Second 0
    
    return ($now -ge $riggEnd -and $now -lt $eventStart)
}

# Funksjon for å forkorte tekst
function Truncate([string]$text, [int]$length) {
    if ($null -eq $text) { return "" }
    if ($text.Length -le $length) { return $text }
    return $text.Substring(0, $length - 2) + ".."
}

# Sjekk om det er aktive arrangementer akkurat nå
$hasActiveEvents = $false
foreach ($arr in $arrangementer) {
    if (Is-EventActive -startTime $arr.startTime -endTime $arr.endTime) {
        $hasActiveEvents = $true
        break
    }
}

# Vis arrangementer med riggetider
if ($arrangementerSortert.Count -gt 0) {
    # Header
    Write-Host " Rigg        Rom   Teknikere   Arrangør           Arr.tid" -ForegroundColor Cyan
    Write-Host " ----------- ----- ----------- ------------------ -----------" -ForegroundColor DarkGray
    
    foreach ($item in $arrangementerSortert) {
        $arr = $item.Arrangement
        $riggInfo = $item.RiggInfo
        
        # Bruk riggetid for visning hvis den finnes
        if ($riggInfo) {
            $tid = "$($riggInfo.StartTime)-$($riggInfo.EndTime)"
        } else {
            # Fallback til arrangement-tid hvis rigg ikke finnes
            $tid = "$($arr.startTime)-$($arr.endTime)"
        }
        
        # Alltid bruk arrangementets rom
        $rom = Short-Room $arr.roomName
        
        # Legg til ikon hvis det er flere rigg-funksjoner
        if ($riggInfo -and $riggInfo.Count -gt 1) {
            $rom = $rom + "⚙" * $riggInfo.Count
        }
        
        # Sjekk om ARRANGEMENTET pågår
        $isEventActive = Is-EventActive -startTime $arr.startTime -endTime $arr.endTime
        
        # Sjekk om RIGGING pågår for dette arrangementet
        $isRiggingActive = $false
        if ($riggInfo) {
            $isRiggingActive = Is-EventActive -startTime $riggInfo.StartTime -endTime $riggInfo.EndTime
        }
        
        # Sjekk om vi er mellom rigg og arrangement
        $isBetweenRiggAndEvent = $false
        if ($riggInfo) {
            $isBetweenRiggAndEvent = Is-BetweenRiggAndEvent -riggEndTime $riggInfo.EndTime -eventStartTime $arr.startTime
        }
        
        # Hent teknikere basert på eventName OG roomId (arrangementets rom)
        $tek = Get-TechnicianNames -eventName $arr.eventName -roomId $arr.roomId
        if ($tek -eq "-") {
            $tek = "     -       "
        } elseif ($tek -like "*Trengs*" -or $tek -eq "TBD") {
            $tek = "   Trengs    "
        } else {
            # Pad til 13 tegn for alignment
            if ($tek.Length -gt 13) {
                $tek = $tek.Substring(0, 13)
            } else {
                $tek = $tek.PadRight(13)
            }
        }
        
        # Hent arrangør (accountName) fra cache
        $arrangor = "(ingen)"
        if ($arr.eventId -and $eventCache.ContainsKey($arr.eventId)) {
            $eventDetail = $eventCache[$arr.eventId]
            if ($eventDetail -and $eventDetail.accountName) {
                $arrangor = $eventDetail.accountName
                if ($arrangor.Length -gt 22) {
                    $arrangor = $arrangor.Substring(0, 20) + ".."
                }
            }
        }
        
        # Arrangementets start og slutt tid
        $arrTider = "$($arr.startTime)-$($arr.endTime)"
        
        # Bestem farge basert på status
        if ($isEventActive) {
            # Arrangementet pågår akkurat nå - cyan
            $farge = "Cyan"
        } elseif ($isBetweenRiggAndEvent) {
            # Mellom rigg og arrangement - GUL
            $farge = "Yellow"
        } elseif ($isRiggingActive) {
            # Rigging pågår for dette arrangementet - hvit
            $farge = "White"
        } else {
            # Default - utenfor både rigg og arrangement - grå
            $farge = "DarkGray"
        }
        
        # Hvis tekniker mangler, overstyr med rød (unntatt hvis arrangement pågår)
        if ($tek.Trim() -like "*Trengs*" -and -not $isEventActive) {
            $farge = "Red"
        }
        
        # Forkort feltene først
        $tid      = Truncate $tid 11
        $rom      = Truncate $rom 6
        $tek      = Truncate $tek 10
        $arrangor = Truncate $arrangor 18
        $arrTider = Truncate $arrTider 11

        # Strammere linje
        $arrangorPadded = $arrangor.PadRight(18)
        $arrangorMedLenke = "`e]8;;https://meetings.eu-venueops.com/events/$($arr.eventId)/detailing/functions`e\$arrangorPadded`e]8;;`e\"
        $linje = " {0,-11} {1,-6} {2,-10} {3} {4,-11}" -f $tid, $rom, $tek, $arrangorMedLenke, $arrTider
        
        # Hvis ARRANGEMENTET pågår, legg til en indikator
        if ($isEventActive) {
            Write-Host "$linje ◄" -ForegroundColor $farge
        } else {
            Write-Host $linje -ForegroundColor $farge
        }
    }
} else {
    Write-Host " Ingen arrangementer i dag" -ForegroundColor DarkGray
}

# VERTER
Write-Host ""
Write-Host " VERTER" -ForegroundColor Cyan
if ($verter) {
    foreach ($v in $verter) {
        # Hent navn fra name-feltet (ikke staffAssignments for verter)
        $fornavn = $null
        
        if (-not [string]::IsNullOrWhiteSpace($v.name)) {
            # Trim først for å fjerne leading/trailing spaces
            $cleanName = $v.name.Trim()
            # Split på mellomrom og ta første ord
            $navneDeler = $cleanName -split '\s+'
            if ($navneDeler.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($navneDeler[0])) {
                $fornavn = "$($navneDeler[0]) $($navneDeler[1]) $($navneDeler[2]) $($navneDeler[3])"
            }
        }
        
        # Hvis fortsatt tomt, sett ukjent
        if ([string]::IsNullOrWhiteSpace($fornavn)) {
            $fornavn = "(ukjent)"
        }
        
        $tid = "$($v.startTime)-$($v.endTime)"
        
        # Sjekk om verten er på jobb nå
        $isVertActive = Is-EventActive -startTime $v.startTime -endTime $v.endTime
        
        $linje = " {0,-11} {1}" -f $tid, $fornavn
        
        # Morgenansatte er darkGray, lyser cyan når aktiv
        if ($fornavn -eq "Pål" -or $fornavn -eq "Mads" -or $fornavn -eq "Johan") {
            # Morgenansatte - darkGray når inaktiv, cyan når aktiv
            if ($isVertActive) {
                Write-Host "$linje ◄" -ForegroundColor Cyan
            } else {
                Write-Host $linje -ForegroundColor DarkGray
            }
        } else {
            # Vanlige verter - cyan hvis på jobb nå
            if ($isVertActive) {
                Write-Host "$linje ◄" -ForegroundColor Cyan
            } else {
                Write-Host $linje -ForegroundColor DarkGray
            }
        }
    }
} else {
    Write-Host " -ingen-" -ForegroundColor Red
}
