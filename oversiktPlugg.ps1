# DAGLIG OVERSIKT MED RIGGETIDER
# Viser arrangementer sortert etter riggetid, med tekniker, arrangør og arr.tid

$clientID = "45i054svbmkrvb8hijo5st2koh"
$clientSecret = "722e0kdr3govijh6trqjdjemk91us89il3368amhhmqc42sod24"

# === ENDRING 2: Smooth refresh ===
#$Host.UI.RawUI.CursorPosition = @{X=0;Y=0}

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

# Legg til riggetider til arrangementer og sorter basert på det
$arrangementerMedRigg = @()
foreach ($arr in $arrangementer) {
    # Finn rigg-funksjon som matcher eventName
    $riggInfo = $null
    foreach ($r in $rigg) {
        if ($r.eventName -eq $arr.eventName) {
            $riggInfo = @{
                StartTime = $r.startTime
                EndTime = $r.endTime
            }
            break
        }
    }
    
    # Legg til arrangement med sorteringstider
    $arrangementerMedRigg += [PSCustomObject]@{
        Arrangement = $arr
        RiggInfo = $riggInfo
        SortTimeEnd = if ($riggInfo) { $riggInfo.EndTime } else { $arr.endTime }
        SortTimeStart = if ($riggInfo) { $riggInfo.StartTime } else { $arr.startTime }
    }
}

# Sorter først på rigg SLUTTTID, deretter på rigg STARTTID
$arrangementerSortert = $arrangementerMedRigg | Sort-Object SortTimeEnd, SortTimeStart

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
    
    # Returner kombinert streng
    if ($teknikere.Count -eq 0) {
        return "-"
    } elseif ($teknikere.Count -eq 1) {
        return $teknikere[0]
    } else {
        # Hvis to teknikere, vis begge med /
        return "$($teknikere[0])/$($teknikere[1])"
    }
}

# Funksjon for å sjekke om arrangement pågår nå
function Is-EventActive {
    param($startTime, $endTime)
    
    $now = Get-Date
    $eventStart = Get-Date -Hour ([int]($startTime.Split(':')[0])) -Minute ([int]($startTime.Split(':')[1])) -Second 0
    $eventEnd = Get-Date -Hour ([int]($endTime.Split(':')[0])) -Minute ([int]($endTime.Split(':')[1])) -Second 0
    
    return ($now -ge $eventStart -and $now -le $eventEnd)
}

# === ENDRING 1: Funksjon for å sjekke om vi er mellom rigg og arrangement ===
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

# Vis header
#Write-Host ""
#Write-Host " ==============================================================" -ForegroundColor Yellow
#Write-Host "  DAGSOVERSIKT - $ukedag $todayNorsk" -ForegroundColor Yellow
#Write-Host " ==============================================================" -ForegroundColor Yellow
#Write-Host ""

# Vis arrangementer med riggetider
if ($arrangementerSortert.Count -gt 0) {
    # Header - oppdatert med arrangør og arr slutt
    Write-Host " Rigg        Rom   Teknikere   Arrangør           Arr.tid" -ForegroundColor Cyan
    Write-Host " ----------- ----- ----------- ------------------ -----------" -ForegroundColor DarkGray
    
    foreach ($item in $arrangementerSortert) {
        $arr = $item.Arrangement
        
        # Bruk riggetid for visning hvis den finnes
        if ($item.RiggInfo) {
            $tid = "$($item.RiggInfo.StartTime)-$($item.RiggInfo.EndTime)"
        } else {
            # Fallback til arrangement-tid hvis rigg ikke finnes
            $tid = "$($arr.startTime)-$($arr.endTime)"
        }
        
        # Sjekk om ARRANGEMENTET pågår
        $isEventActive = Is-EventActive -startTime $arr.startTime -endTime $arr.endTime
        
        # Sjekk om RIGGING pågår for dette arrangementet
        $isRiggingActive = $false
        if ($item.RiggInfo) {
            $isRiggingActive = Is-EventActive -startTime $item.RiggInfo.StartTime -endTime $item.RiggInfo.EndTime
        }
        
        # === ENDRING 1: Sjekk om vi er mellom rigg og arrangement ===
        $isBetweenRiggAndEvent = $false
        if ($item.RiggInfo) {
            $isBetweenRiggAndEvent = Is-BetweenRiggAndEvent -riggEndTime $item.RiggInfo.EndTime -eventStartTime $arr.startTime
        }
        
        $rom = Short-Room $arr.roomName
        
        # Hent teknikere basert på eventName OG roomId
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
            # === ENDRING 1: Mellom rigg og arrangement - GUL ===
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
        $linje = " {0,-11} {1,-6} {2,-10} {3,-18} {4,-11}" -f $tid, $rom, $tek, $arrangor, $arrTider
        
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
                $fornavn = $navneDeler[0]
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
        
        # === ENDRING 3: Morgenansatte er darkGray, lyser cyan når aktiv ===
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

#Write-Host ""
#Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkGray
#Write-Host ""
