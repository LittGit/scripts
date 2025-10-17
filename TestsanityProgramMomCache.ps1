# ============================================
# SANITY EVENTS - INTERAKTIV MENY
# ============================================

$projectId = "4bjarlop"
$dataset = "production"
$token = ""  # SETT INN TOKEN HER HVIS NØDVENDIG

# Momentus credentials
$momentusBaseUrl = "https://meetings.eu-venueops.com"
$ClientID = "45i054svbmkrvb8hijo5st2koh"
$clientSecret = "722e0kdr3govijh6trqjdjemk91us89il3368amhhmqc42sod24"
$script:momentusToken = $null

Add-Type -AssemblyName System.Web

# Farger
$colors = @{
    Success = 'Green'
    Warning = 'Yellow'
    Error = 'Red'
    Info = 'Cyan'
    Header = 'White'
    Menu = 'Yellow'
    TimeMatch = 'Green'
    TimeMismatch = 'Red'
}

# Headers
$headers = @{}
if ($token) {
    $headers["Authorization"] = "Bearer $token"
}

# Global entity lookup
$script:entityLookup = @{}

# Global Momentus events cache
$script:momentusEventsCache = @()

# Global Momentus event details cache (for å unngå repeterte API-kall)
$script:eventDetailsCache = @{}

# Global merged events cache (pre-loaded for rask visning)
$script:mergedEventsCache = @()
$script:cacheLoadTime = $null

# =====================================
# MOMENTUS AUTHENTICATION
# =====================================
function Get-MomentusToken {
    if (-not $ClientID -or -not $clientSecret) {
        Write-Host "⚠ Momentus credentials ikke satt. Hopper over Momentus-integrasjon." -ForegroundColor $colors.Warning
        return $null
    }

    try {
        $authUrl = "https://auth-api.eu-venueops.com/token"
        $authBody = @{
            clientSecret = $clientSecret
            clientId = $ClientID
        } | ConvertTo-Json

        $authHeaders = @{
            "Content-Type" = "application/json"
        }

        $response = Invoke-RestMethod -Uri $authUrl -Method Post -Body $authBody -Headers $authHeaders -ErrorAction Stop
        Write-Host "✓ Autentisert mot Momentus" -ForegroundColor $colors.Success
        return $response.accessToken
    }
    catch {
        Write-Host "✗ Kunne ikke autentisere mot Momentus: $($_.Exception.Message)" -ForegroundColor $colors.Error
        return $null
    }
}

# =====================================
# HENT MOMENTUS EVENTS
# =====================================
function Get-MomentusEvents {
    param(
        [DateTime]$StartDate,
        [DateTime]$EndDate
    )

    if (-not $script:momentusToken) {
        return @()
    }

    try {
        $startStr = $StartDate.ToString("yyyy-MM-dd")
        $endStr = $EndDate.ToString("yyyy-MM-dd")
        
        # Hent funksjoner for perioden (som i oversiktPlugg.ps1)
        $functionsUrl = "https://api.eu-venueops.com/v1/functions?startDate=$startStr&endDate=$endStr"
        
        $momentusHeaders = @{
            "Authorization" = "Bearer $script:momentusToken"
            "Content-Type" = "application/json"
        }

        $functions = Invoke-RestMethod -Uri $functionsUrl -Method Get -Headers $momentusHeaders -ErrorAction Stop
        
        # Filtrer til kun arrangement-funksjoner
        $arrangementer = $functions | Where-Object {
            $_.functionTypeName -eq 'Arrangement' -and $_.functionStatus -ne "canceled"
        }
        
        # Grupper funksjoner per event for å få unike events
        # VIKTIG: Et event kan ha flere arrangement-funksjoner (f.eks. i forskjellige rom)
        $uniqueEvents = @{}
        
        foreach ($arr in $arrangementer) {
            if ($arr.eventId) {
                # Hvis vi allerede har sett dette eventet, ta tidligste starttid
                if ($uniqueEvents.ContainsKey($arr.eventId)) {
                    $existing = $uniqueEvents[$arr.eventId]
                    $existingStart = [DateTime]::Parse($existing.start)
                    $newStart = [DateTime]::Parse("$($arr.startDate)T$($arr.startTime):00")
                    
                    # Bruk tidligste starttid
                    if ($newStart -lt $existingStart) {
                        $uniqueEvents[$arr.eventId].start = "$($arr.startDate)T$($arr.startTime):00"
                        $uniqueEvents[$arr.eventId].end = "$($arr.endDate)T$($arr.endTime):00"
                    }
                }
                else {
                    # Første gang vi ser dette eventet
                    # Sjekk cache først
                    $accountName = ""
                    if ($script:eventDetailsCache.ContainsKey($arr.eventId)) {
                        $accountName = $script:eventDetailsCache[$arr.eventId]
                    }
                    else {
                        # Hent event-detaljer og cache dem
                        try {
                            $eventDetails = Invoke-RestMethod -Uri "https://api.eu-venueops.com/v1/events/$($arr.eventId)" -Method Get -Headers $momentusHeaders -ErrorAction Stop
                            $accountName = $eventDetails.accountName
                            $script:eventDetailsCache[$arr.eventId] = $accountName
                        }
                        catch {
                            $accountName = ""
                            $script:eventDetailsCache[$arr.eventId] = ""
                        }
                    }
                    
                    # Lag et event-objekt
                    $eventObj = [PSCustomObject]@{
                        id = $arr.eventId
                        name = $arr.eventName
                        accountName = $accountName
                        start = "$($arr.startDate)T$($arr.startTime):00"
                        end = "$($arr.endDate)T$($arr.endTime):00"
                        roomName = $arr.roomName
                    }
                    
                    $uniqueEvents[$arr.eventId] = $eventObj
                }
            }
        }
        
        $eventList = $uniqueEvents.Values
        return $eventList
    }
    catch {
        Write-Host "⚠ Kunne ikke hente Momentus events: $($_.Exception.Message)" -ForegroundColor $colors.Warning
        return @()
    }
}

# =====================================
# MATCH SANITY EVENT MED MOMENTUS
# =====================================
function Find-MomentusMatch {
    param(
        [DateTime]$EventDateTime,
        [string]$Rom
    )

    if ($script:momentusEventsCache.Count -eq 0) {
        return $null
    }

    try {
        # Søk etter match i Momentus events
        foreach ($momEvent in $script:momentusEventsCache) {
            # Parse Momentus event tid
            $momStartTime = [DateTime]::Parse($momEvent.start)
            
            # Sammenlign dato (ignorerer sekunder)
            $timeDiff = [Math]::Abs(($EventDateTime - $momStartTime).TotalMinutes)
            
            # Match hvis tiden er innenfor 15 minutter
            if ($timeDiff -le 15) {
                # Sjekk rom hvis vi har romnavn
                if ($momEvent.roomName -and $Rom) {
                    $momRoomName = $momEvent.roomName.ToLower()
                    $sanityRoomName = $Rom.ToLower()
                    
                    # Fjern "room-" prefix og parenteser for sammenligning
                    $momRoomName = $momRoomName -replace "^room-", "" -replace "\s*\([^)]*\)", ""
                    $sanityRoomName = $sanityRoomName -replace "^room-", "" -replace "\s*\([^)]*\)", ""
                    
                    # Match hvis romnavnene overlapper
                    if ($momRoomName -like "*$sanityRoomName*" -or $sanityRoomName -like "*$momRoomName*") {
                        return @{
                            Event = $momEvent
                            TimeMatch = ($timeDiff -le 1)  # Perfekt match hvis innenfor 1 minutt
                        }
                    }
                }
                elseif (-not $Rom -or -not $momEvent.roomName) {
                    # Hvis ingen rom å sammenligne, match kun på tid
                    return @{
                        Event = $momEvent
                        TimeMatch = ($timeDiff -le 1)
                    }
                }
            }
        }
    }
    catch {
        # Ignorer feil i matching
    }

    return $null
}

# =====================================
# LAST ENTITIES
# =====================================
function Load-Entities {
    Write-Host "Laster entities..." -ForegroundColor $colors.Info
    
    $entitiesGroq = "*[_type == 'entity'] { _id, title }"
    $encodedEntitiesQuery = [System.Web.HttpUtility]::UrlEncode($entitiesGroq)
    $entitiesUrl = "https://$projectId.api.sanity.io/v2021-10-21/data/query/$dataset`?query=$encodedEntitiesQuery"
    
    try {
        $entitiesResponse = Invoke-RestMethod -Uri $entitiesUrl -Headers $headers -Method Get -ErrorAction Stop
        
        foreach ($entity in $entitiesResponse.result) {
            if ($entity._id -and $entity.title) {
                $cleanId = $entity._id -replace '^drafts\.', ''
                $script:entityLookup[$entity._id] = $entity.title
                $script:entityLookup[$cleanId] = $entity.title
            }
        }
        
        Write-Host "✓ Lastet $($entitiesResponse.result.Count) entities" -ForegroundColor $colors.Success
    } catch {
        Write-Host "⚠ Kunne ikke laste entities: $($_.Exception.Message)" -ForegroundColor $colors.Warning
    }
}

# =====================================
# LAST ALLE EVENTS TIL CACHE
# =====================================
function Load-AllEventsToCache {
    Write-Host ""
    Write-Host "════════════════════════════════════════" -ForegroundColor $colors.Info
    Write-Host "   LASTER ALLE EVENTS TIL CACHE...     " -ForegroundColor $colors.Info
    Write-Host "════════════════════════════════════════" -ForegroundColor $colors.Info
    Write-Host ""
    
    # Last neste 60 dager
    $today = Get-Date
    $startDate = $today
    $endDate = $today.AddDays(60)
    
    Write-Host "Laster events fra $($startDate.ToString('dd.MM.yyyy')) til $($endDate.ToString('dd.MM.yyyy'))..." -ForegroundColor $colors.Info
    
    # Hent alle events
    $script:mergedEventsCache = Get-MergedEvents -StartDate $startDate -EndDate $endDate
    $script:cacheLoadTime = Get-Date
    
    Write-Host ""
    Write-Host "✓ Cache lastet med $($script:mergedEventsCache.Count) events" -ForegroundColor $colors.Success
    Write-Host "  (Lastet: $($script:cacheLoadTime.ToString('HH:mm:ss')))" -ForegroundColor DarkGray
    Write-Host ""
    
    Start-Sleep -Seconds 2
}

# =====================================
# HENT SANITY EVENTS
# =====================================
function Get-SanityEvents {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [string]$SearchTerm = ""
    )
    
    $groq = "*[_type == 'event' && defined(dates[0].eventStart) && dates[0].eventStart >= '$StartDate' && dates[0].eventStart <= '$EndDate'] | order(dates[0].eventStart asc) {
      'tittel': title.nb,
      'dato': dates[0].eventStart,
      'varighet': dates[0].eventDuration,
      'rom': venues[0].room->title,
      'slug': slug.current,
      'eventUrl': 'https://litteraturhuset.no/arrangement/' + slug.current,
      'organizerRef': organizers[0]._ref,
      'billettpris': admission.ticket.cost,
      'billetturl': admission.ticket.url,
      'billettstatus': admission.status,
      'bildeUrl': image.asset->url,
      'streamingUrl': streaming,
      'eventId': _id
    }"
    
    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($groq)
    $apiUrl = "https://$projectId.api.sanity.io/v2021-10-21/data/query/$dataset`?query=$encodedQuery&perspective=published"
    
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
        
        $events = $response.result
        
        # Filtrer på søkeord hvis angitt
        if ($SearchTerm) {
            $events = $events | Where-Object {
                $arrangor = if ($_.organizerRef -and $script:entityLookup.ContainsKey($_.organizerRef)) { 
                    $script:entityLookup[$_.organizerRef] 
                } else { "" }
                
                $_.tittel -like "*$SearchTerm*" -or 
                $arrangor -like "*$SearchTerm*" -or
                $_.rom -like "*$SearchTerm*"
            }
        }
        
        return $events
    } catch {
        Write-Host "✗ Feil ved henting av events: $($_.Exception.Message)" -ForegroundColor $colors.Error
        return @()
    }
}

# =====================================
# MERGE SANITY OG MOMENTUS EVENTS
# =====================================
function Merge-Events {
    param(
        [array]$SanityEvents,
        [array]$MomentusEvents,
        [string]$SearchTerm = ""
    )

    $mergedEvents = @()
    $matchedMomentusIds = @()

    # Først: Legg til alle Sanity events med Momentus matching
    foreach ($sanityEvent in $SanityEvents) {
        try {
            $eventDateTime = [DateTime]::Parse($sanityEvent.dato, [System.Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
            
            # Finn arrangørnavn
            $arrangorNavn = ""
            if ($sanityEvent.organizerRef -and $script:entityLookup.ContainsKey($sanityEvent.organizerRef)) {
                $arrangorNavn = $script:entityLookup[$sanityEvent.organizerRef]
            }
            
            # Finn Momentus match basert på rom og tid
            $momentusMatch = Find-MomentusMatch -EventDateTime $eventDateTime -Rom $sanityEvent.rom
            
            # Lag merged event object
            $mergedEvent = @{
                Source = 'Sanity'
                DateTime = $eventDateTime
                Tittel = $sanityEvent.tittel
                Rom = $sanityEvent.rom
                Varighet = $sanityEvent.varighet
                Billettpris = $sanityEvent.billettpris
                BildeUrl = $sanityEvent.bildeUrl
                EventUrl = $sanityEvent.eventUrl
                EventId = $sanityEvent.eventId
                Arrangor = $arrangorNavn
                StreamingUrl = $sanityEvent.streamingUrl
                MomentusMatch = $momentusMatch
            }
            
            # Marker Momentus event som matched hvis funnet
            if ($momentusMatch) {
                $matchedMomentusIds += $momentusMatch.Event.id
            }
            
            $mergedEvents += $mergedEvent
        }
        catch {
            Write-Host "⚠ Kunne ikke prosessere Sanity event: $($_.Exception.Message)" -ForegroundColor $colors.Warning
        }
    }

    # Deretter: Legg til Momentus-only events (ikke publisert på nett)
    # VIKTIG: Hvis SearchTerm er angitt, IKKE inkluder Momentus-only events
    if (-not $SearchTerm) {
        foreach ($momEvent in $MomentusEvents) {
            if ($matchedMomentusIds -notcontains $momEvent.id) {
                try {
                    $momStartTime = [DateTime]::Parse($momEvent.start)
                    
                    # Hent arrangørnavn fra Momentus
                    $arrangorNavn = if ($momEvent.accountName) {
                        $momEvent.accountName
                    } else {
                        "Ukjent arrangør"
                    }
                    
                    # Hent rom fra Momentus event
                    $romNavn = if ($momEvent.roomName) {
                        $momEvent.roomName
                    } else {
                        ""
                    }
                    
                    # Beregn varighet i minutter
                    $varighet = $null
                    if ($momEvent.start -and $momEvent.end) {
                        $momEndTime = [DateTime]::Parse($momEvent.end)
                        $varighet = ($momEndTime - $momStartTime).TotalMinutes
                    }
                    
                    $mergedEvent = @{
                        Source = 'Momentus'
                        DateTime = $momStartTime
                        Tittel = $momEvent.name
                        Rom = $romNavn
                        Varighet = $varighet
                        Billettpris = $null
                        BildeUrl = $null
                        EventUrl = $null
                        EventId = $null
                        Arrangor = $arrangorNavn
                        MomentusEvent = $momEvent
                        MomentusMatch = $null
                    }
                    
                    $mergedEvents += $mergedEvent
                }
                catch {
                    Write-Host "⚠ Kunne ikke prosessere Momentus event: $($_.Exception.Message)" -ForegroundColor $colors.Warning
                }
            }
        }
    }

    # Sorter alle events etter tidspunkt
    $mergedEvents = $mergedEvents | Sort-Object -Property DateTime

    return $mergedEvents
}

# =====================================
# VIS EVENTS
# =====================================
function Show-Events {
    param(
        [array]$Events,
        [string]$Title
    )
    clear
    Write-Host ""
    Write-Host "========================================" -ForegroundColor $colors.Header
    Write-Host "   $Title" -ForegroundColor $colors.Header
    Write-Host "========================================" -ForegroundColor $colors.Header
    Write-Host ""
    
    if ($Events.Count -eq 0) {
        Write-Host "Ingen events funnet" -ForegroundColor $colors.Warning
        return
    }
    
    foreach ($event in $Events) {
        try {
            # === LINJE 1: Dato, Start, Slutt, Tittel, Img, Varighet, Pris ===
            
            # Dato (dd.MM.yyyy)
            $dato = $event.DateTime.ToString("dd.MM.yyyy")
            
            # Start tid (HH:mm) - farget basert på match
            $startTid = $event.DateTime.ToString("HH:mm")
            
            # Slutt tid (HH:mm) - beregn fra varighet eller bruk Momentus end time
            $sluttTid = ""
            if ($event.Varighet) {
                $sluttDateTime = $event.DateTime.AddMinutes($event.Varighet)
                $sluttTid = $sluttDateTime.ToString("HH:mm")
            }
            
            # Bestem farge på start/slutt tid basert på match
            $timeColor = 'White'  # Standard hvit
            if ($event.MomentusMatch) {
                $timeColor = if ($event.MomentusMatch.TimeMatch) { $colors.TimeMatch } else { $colors.TimeMismatch }
            }
            
            # Tittel (maks 30 tegn)
            $tittel = if ($event.Tittel) { $event.Tittel } else { "Ingen tittel" }
            if ($tittel.Length -gt 30) {
                $tittel = $tittel.Substring(0, 27) + "..."
            }
            
            # Gjør tittelen klikkbar hvis Sanity event
            $tittelLink = if ($event.EventUrl) {
                "`e]8;;$($event.EventUrl)`e\$tittel`e]8;;`e\"
            } else {
                $tittel
            }
            
            # Bygg linje 1 (uten tid først - vi legger til tid med farge etterpå)
            Write-Host -NoNewline "$dato " -ForegroundColor White
            Write-Host -NoNewline "$startTid" -ForegroundColor $timeColor
            Write-Host -NoNewline "-" -ForegroundColor White
            Write-Host -NoNewline "$sluttTid " -ForegroundColor $timeColor
            Write-Host -NoNewline "$tittelLink " -ForegroundColor White
            
            # Bilde lenke (kun for Sanity events)
            if ($event.BildeUrl) {
                $bildeLink = "`e]8;;$($event.BildeUrl)`e\[Img]`e]8;;`e\"
                Write-Host -NoNewline "$bildeLink " -ForegroundColor White
            }
            
            Write-Host ""  # Newline etter linje 1
            
            # === LINJE 2: Arrangør, sanity|momen, stream ===
            
            if ($event.Arrangor) {
                $arrangorNavn = $event.Arrangor
                if ($arrangorNavn.Length -gt 35) {
                    $arrangorNavn = $arrangorNavn.Substring(0, 32) + "..."
                }
                
                Write-Host -NoNewline "  → $arrangorNavn " -ForegroundColor DarkGray
                
                # Bygg lenker
                $lenker = @()
                
                # Sanity Studio lenke (kun for Sanity events)
                if ($event.Source -eq 'Sanity' -and $event.EventId) {
                    $sanityUrl = "https://studio.litteraturhuset.no/web/structure/events;allEvents;$($event.EventId)?perspective=draft"
                    $sanityLink = "`e]8;;$sanityUrl`e\sanity`e]8;;`e\"
                    $lenker += $sanityLink
                }
                
                # Momentus lenke (hvis event matcher eller er Momentus-only)
                if ($event.MomentusMatch) {
                    $momentusUrl = "https://meetings.eu-venueops.com/events/$($event.MomentusMatch.Event.id)/detailing/functions"
                    $momentusLink = "`e]8;;$momentusUrl`e\momen`e]8;;`e\"
                    $lenker += $momentusLink
                }
                elseif ($event.Source -eq 'Momentus' -and $event.MomentusEvent) {
                    $momentusUrl = "https://meetings.eu-venueops.com/events/$($event.MomentusEvent.id)/detailing/functions"
                    $momentusLink = "`e]8;;$momentusUrl`e\momen`e]8;;`e\"
                    $lenker += $momentusLink
                }
                
                if ($lenker.Count -gt 0) {
                    Write-Host -NoNewline "[$($lenker -join '|')] " -ForegroundColor DarkGray
                }
                
                # Stream lenke (kun for Sanity events med streaming URL) - GRØNN
                if ($event.StreamingUrl) {
                    $streamLink = "`e]8;;$($event.StreamingUrl)`e\[stream]`e]8;;`e\"
                    Write-Host -NoNewline "$streamLink " -ForegroundColor Green
                }
                
                Write-Host ""  # Newline etter linje 2
            }
            
            Write-Host ""  # Blank linje mellom events
        }
        catch {
            Write-Host "⚠ Kunne ikke vise event: $($_.Exception.Message)" -ForegroundColor $colors.Warning
        }
    }
    
    Write-Host "-----------------------------------------------------------------" -ForegroundColor $colors.Menu
    
    # Tell antall fra hver kilde
    $sanityCount = ($Events | Where-Object { $_.Source -eq 'Sanity' }).Count
    $momentusOnlyCount = ($Events | Where-Object { $_.Source -eq 'Momentus' }).Count
    $matchedCount = ($Events | Where-Object { $_.MomentusMatch -ne $null }).Count
    
    Write-Host "Totalt: $($Events.Count) events " -ForegroundColor $colors.Info -NoNewline
    Write-Host "($sanityCount fra nett, $momentusOnlyCount kun Momentus, $matchedCount matchet)" -ForegroundColor DarkGray
}

# =====================================
# HOVEDMENY
# =====================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "========================================" -ForegroundColor $colors.Menu
    Write-Host "        SANITY EVENTS MENY              " -ForegroundColor $colors.Menu
    Write-Host "========================================" -ForegroundColor $colors.Menu
    Write-Host ""
    Write-Host "  1. Vis dagens events" -ForegroundColor White
    Write-Host "  2. Vis morgendagens events" -ForegroundColor White
    Write-Host "  3. Vis denne uken" -ForegroundColor White
    Write-Host "  4. Vis denne måneden" -ForegroundColor White
    Write-Host "  5. Vis neste 31 dager" -ForegroundColor White
    Write-Host "  6. Søk på tittel/arrangør/rom" -ForegroundColor White
    Write-Host "  7. Egendefinert periode" -ForegroundColor White
    Write-Host "  8. Oppdater data (last på nytt)" -ForegroundColor Yellow
    Write-Host "  0. Avslutt" -ForegroundColor White
    Write-Host ""
    Write-Host "========================================" -ForegroundColor $colors.Menu
    Write-Host ""
}

# =====================================
# HENT OG MERGE EVENTS
# =====================================
function Get-MergedEvents {
    param(
        [DateTime]$StartDate,
        [DateTime]$EndDate,
        [string]$SearchTerm = ""
    )

    # Hent Sanity events
    $startDateStr = $StartDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endDateStr = $EndDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $sanityEvents = Get-SanityEvents -StartDate $startDateStr -EndDate $endDateStr -SearchTerm $SearchTerm

    # Hent Momentus events (cache dem)
    $script:momentusEventsCache = Get-MomentusEvents -StartDate $StartDate -EndDate $EndDate

    # Merge events (send med SearchTerm for å filtrere Momentus-only events)
    $mergedEvents = Merge-Events -SanityEvents $sanityEvents -MomentusEvents $script:momentusEventsCache -SearchTerm $SearchTerm

    return $mergedEvents
}

# =====================================
# FILTRER FRA CACHE
# =====================================
function Get-EventsFromCache {
    param(
        [DateTime]$StartDate,
        [DateTime]$EndDate,
        [string]$SearchTerm = ""
    )
    
    # Filtrer cached events basert på dato
    $filteredEvents = $script:mergedEventsCache | Where-Object {
        $_.DateTime -ge $StartDate -and $_.DateTime -le $EndDate
    }
    
    # Filtrer på søkeord hvis angitt
    if ($SearchTerm) {
        $filteredEvents = $filteredEvents | Where-Object {
            ($_.Tittel -like "*$SearchTerm*") -or
            ($_.Arrangor -like "*$SearchTerm*") -or
            ($_.Rom -like "*$SearchTerm*")
        }
    }
    
    return $filteredEvents
}

# =====================================
# HOVEDPROGRAM
# =====================================

Clear-Host

Write-Host ""
Write-Host "╔════════════════════════════════════════╗" -ForegroundColor $colors.Header
Write-Host "║   SANITY EVENTS - INTERAKTIV MENY      ║" -ForegroundColor $colors.Header
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor $colors.Header
Write-Host ""

# Autentiser mot Momentus
$script:momentusToken = Get-MomentusToken

# Last entities
Load-Entities

# Last alle events til cache
Load-AllEventsToCache

# Hovedløkke
$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "Velg et alternativ (0-8)"
    
    switch ($choice) {
        "1" {
            # Dagens events
            $today = Get-Date
            $startDate = $today.Date
            $endDate = $today.Date.AddDays(1).AddSeconds(-1)
            
            $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
            
            $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
            Show-Events -Events $events -Title "DAGENS EVENTS - $($today.ToString('dd.MM.yyyy'))$cacheTime"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "2" {
            # Morgendagens events
            $tomorrow = (Get-Date).AddDays(1)
            $startDate = $tomorrow.Date
            $endDate = $tomorrow.Date.AddDays(1).AddSeconds(-1)
            
            $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
            
            $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
            Show-Events -Events $events -Title "MORGENDAGENS EVENTS - $($tomorrow.ToString('dd.MM.yyyy'))$cacheTime"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "3" {
            # Denne uken
            $today = Get-Date
            $startDate = $today.Date
            $endDate = $today.Date.AddDays(7)
            
            $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
            
            $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
            Show-Events -Events $events -Title "DENNE UKEN$cacheTime"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "4" {
            # Denne måneden
            $today = Get-Date
            $startDate = $today.Date
            $lastDayOfMonth = New-Object DateTime($today.Year, $today.Month, [DateTime]::DaysInMonth($today.Year, $today.Month))
            $endDate = $lastDayOfMonth.AddDays(1).AddSeconds(-1)
            
            $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
            
            $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
            Show-Events -Events $events -Title "DENNE MÅNEDEN - $($today.ToString('MMMM yyyy'))$cacheTime"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "5" {
            # Neste 31 dager
            $today = Get-Date
            $startDate = $today
            $endDate = $today.AddDays(31)
            
            $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
            
            $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
            Show-Events -Events $events -Title "NESTE 31 DAGER$cacheTime"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "6" {
            # Søk
            Write-Host ""
            $searchTerm = Read-Host "Søk på tittel, arrangør eller rom"
            
            if ($searchTerm) {
                $today = Get-Date
                $startDate = $today
                $endDate = $today.AddDays(60)
                
                $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate -SearchTerm $searchTerm
                
                $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
                Show-Events -Events $events -Title "SØKERESULTAT: '$searchTerm'$cacheTime"
            }
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "7" {
            # Egendefinert periode
            Write-Host ""
            Write-Host "Egendefinert periode" -ForegroundColor $colors.Info
            Write-Host "-------------------" -ForegroundColor $colors.Info
            
            $startInput = Read-Host "Fra dato (dd.MM.yyyy)"
            $endInput = Read-Host "Til dato (dd.MM.yyyy)"
            
            try {
                $startParsed = [DateTime]::ParseExact($startInput, "dd.MM.yyyy", $null)
                $endParsed = [DateTime]::ParseExact($endInput, "dd.MM.yyyy", $null)
                
                $startDate = $startParsed
                $endDate = $endParsed.AddDays(1).AddSeconds(-1)
                
                $events = Get-EventsFromCache -StartDate $startDate -EndDate $endDate
                
                $cacheTime = if ($script:cacheLoadTime) { " (cache: $($script:cacheLoadTime.ToString('HH:mm')))" } else { "" }
                Show-Events -Events $events -Title "PERIODE: $startInput - $endInput$cacheTime"
            }
            catch {
                Write-Host "✗ Ugyldig datoformat. Bruk dd.MM.yyyy (f.eks. 15.10.2025)" -ForegroundColor $colors.Error
            }
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "8" {
            # Oppdater data
            Clear-Host
            Write-Host ""
            Write-Host "========================================" -ForegroundColor $colors.Info
            Write-Host "   OPPDATERER DATA                     " -ForegroundColor $colors.Info
            Write-Host "========================================" -ForegroundColor $colors.Info
            Write-Host ""
            
            # Re-autentiser mot Momentus
            $script:momentusToken = Get-MomentusToken
            
            # Tøm alle cacher
            $script:eventDetailsCache = @{}
            $script:mergedEventsCache = @()
            $script:cacheLoadTime = $null
            
            # Last entities
            Load-Entities
            
            # Last alle events til cache
            Load-AllEventsToCache
            
            Write-Host "✓ Alle data oppdatert!" -ForegroundColor $colors.Success
            Write-Host ""
            Start-Sleep -Seconds 2
        }
        
        "0" {
            Write-Host ""
            Write-Host "Avslutter..." -ForegroundColor $colors.Success
            $running = $false
        }
        
        default {
            Write-Host ""
            Write-Host "Ugyldig valg. Velg 0-8." -ForegroundColor $colors.Warning
            Start-Sleep -Seconds 1
        }
    }
}

Write-Host ""
Write-Host "Ha en fin dag! 👋" -ForegroundColor $colors.Success
Write-Host ""
