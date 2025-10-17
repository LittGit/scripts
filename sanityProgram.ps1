# ============================================
# SANITY EVENTS - INTERAKTIV MENY
# ============================================

$projectId = "4bjarlop"
$dataset = "production"
$token = ""  # SETT INN TOKEN HER HVIS NØDVENDIG

Add-Type -AssemblyName System.Web

# Farger
$colors = @{
    Success = 'Green'
    Warning = 'Yellow'
    Error = 'Red'
    Info = 'Cyan'
    Header = 'White'
    Menu = 'Yellow'
}

# Headers
$headers = @{}
if ($token) {
    $headers["Authorization"] = "Bearer $token"
}

# Global entity lookup
$script:entityLookup = @{}

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
# HENT EVENTS
# =====================================
function Get-Events {
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
    
    Write-Host "DATO & TID          INFO" -ForegroundColor $colors.Menu
    Write-Host "-----------------------------------------------------------------" -ForegroundColor $colors.Menu
    
    foreach ($event in $Events) {
        try {
            $eventDateTime = [DateTime]::Parse($event.dato, [System.Globalization.CultureInfo]::InvariantCulture)
            $datoStr = $eventDateTime.ToLocalTime().ToString("dd.MM.yyyy HH:mm")
            
            # Maks 45 tegn tilgjengelig etter dato (65 - 20 for dato)
            $maxInfoLength = 45
            
            # Bygg info-delen
            $infoParts = @()
            
            # Tittel (maks 20 tegn)
            $tittel = if ($event.tittel) { $event.tittel } else { "Ingen tittel" }
            if ($tittel.Length -gt 20) {
                $tittel = $tittel.Substring(0, 17) + "..."
            }
            
            # Gjør tittelen klikkbar
            $tittelLink = if ($event.eventUrl) {
                "`e]8;;$($event.eventUrl)`e\$tittel`e]8;;`e\"
            } else {
                $tittel
            }
            $infoParts += $tittelLink
            
            # Bilde (lenke)
            if ($event.bildeUrl) {
                $bildeLink = "`e]8;;$($event.bildeUrl)`e\Img`e]8;;`e\"
                $infoParts += $bildeLink
            }
            
            # Rom (maks 10 tegn)
            if ($event.rom) {
                $romTekst = $event.rom
                if ($romTekst.Length -gt 10) {
                    $romTekst = $romTekst.Substring(0, 8) + ".."
                }
                $infoParts += $romTekst
            }
            
            # Varighet (kompakt format)
            if ($event.varighet) {
                $timer = [Math]::Floor($event.varighet / 60)
                $minutter = $event.varighet % 60
                
                if ($timer -gt 0 -and $minutter -gt 0) {
                    $varighetText = "$($timer)t$($minutter)m"
                } elseif ($timer -gt 0) {
                    $varighetText = "$($timer)t"
                } else {
                    $varighetText = "$($minutter)m"
                }
                
                $infoParts += $varighetText
            }
            
            # Pris (maks 12 tegn)
            if ($event.billettpris) {
                $prisTekst = $event.billettpris
                if ($prisTekst.Length -gt 12) {
                    $prisTekst = $prisTekst.Substring(0, 10) + ".."
                }
                $infoParts += $prisTekst
            }
            
            # Kombiner med separator
            $infoLinje = $infoParts -join "|"
            
            Write-Host ("{0,-19} {1}" -f $datoStr, $infoLinje) -ForegroundColor White
            
            # Arrangør på neste linje (hvis plass)
            if ($event.organizerRef -and $script:entityLookup.ContainsKey($event.organizerRef)) {
                $entityNavn = $script:entityLookup[$event.organizerRef]
                
                # Bygg Sanity Studio lenke
                $sanityUrl = "https://studio.litteraturhuset.no/web/structure/events;allEvents;$($event.eventId)?perspective=draft"
                $sanityLink = "`e]8;;$sanityUrl`e\Sanity`e]8;;`e\"
                
                # Legg til Stream-lenke hvis streaming URL finnes
                $streamIndikator = ""
                if ($event.streamingUrl) {
                    $streamLink = "`e]8;;$($event.streamingUrl)`e\Stream`e]8;;`e\"
                    $streamIndikator = " | $streamLink"
                }
                
                # Maks 44 tegn totalt (inkludert sanity og stream)
                # Reserver plass for " | Sanity | Stream" (ca 20 tegn)
                $maxNavn = 24
                if ($entityNavn.Length -gt $maxNavn) {
                    $entityNavn = $entityNavn.Substring(0, $maxNavn - 3) + "..."
                }
                
                Write-Host "                    " -NoNewline
                Write-Host $entityNavn -NoNewline -ForegroundColor Cyan
                Write-Host " | " -NoNewline -ForegroundColor DarkGray
                Write-Host $sanityLink -NoNewline -ForegroundColor DarkGray
                if ($event.streamingUrl) {
                    Write-Host " | " -NoNewline -ForegroundColor DarkGray
                    Write-Host $streamLink -ForegroundColor Green
                } else {
                    Write-Host ""
                }
            }
            
            Write-Host ""
        }
        catch {
            Write-Host "⚠ Kunne ikke vise event" -ForegroundColor $colors.Warning
        }
    }
    
    Write-Host "-----------------------------------------------------------------" -ForegroundColor $colors.Menu
    Write-Host "Totalt: $($Events.Count) events" -ForegroundColor $colors.Info
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
# HOVEDPROGRAM
# =====================================

Clear-Host

Write-Host ""
Write-Host "╔════════════════════════════════════════╗" -ForegroundColor $colors.Header
Write-Host "║   SANITY EVENTS - INTERAKTIV MENY      ║" -ForegroundColor $colors.Header
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor $colors.Header
Write-Host ""

# Last entities først
Load-Entities

# Hovedløkke
$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "Velg et alternativ (0-8)"
    
    switch ($choice) {
        "1" {
            # Dagens events
            $today = Get-Date
            $startDate = $today.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $endDate = $today.Date.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $events = Get-Events -StartDate $startDate -EndDate $endDate
            Show-Events -Events $events -Title "DAGENS EVENTS - $($today.ToString('dd.MM.yyyy'))"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "2" {
            # Morgendagens events
            $tomorrow = (Get-Date).AddDays(1)
            $startDate = $tomorrow.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $endDate = $tomorrow.Date.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $events = Get-Events -StartDate $startDate -EndDate $endDate
            Show-Events -Events $events -Title "MORGENDAGENS EVENTS - $($tomorrow.ToString('dd.MM.yyyy'))"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "3" {
            # Denne uken
            $today = Get-Date
            $startDate = $today.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $endDate = $today.Date.AddDays(7).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $events = Get-Events -StartDate $startDate -EndDate $endDate
            Show-Events -Events $events -Title "DENNE UKEN"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "4" {
            # Denne måneden
            $today = Get-Date
            $startDate = $today.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $lastDayOfMonth = New-Object DateTime($today.Year, $today.Month, [DateTime]::DaysInMonth($today.Year, $today.Month))
            $endDate = $lastDayOfMonth.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $events = Get-Events -StartDate $startDate -EndDate $endDate
            Show-Events -Events $events -Title "DENNE MÅNEDEN - $($today.ToString('MMMM yyyy'))"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "5" {
            # Neste 31 dager
            $today = Get-Date
            $startDate = $today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $endDate = $today.AddDays(31).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $events = Get-Events -StartDate $startDate -EndDate $endDate
            Show-Events -Events $events -Title "NESTE 31 DAGER"
            
            Write-Host ""
            Read-Host "Trykk Enter for å fortsette"
        }
        
        "6" {
            # Søk
            Write-Host ""
            $searchTerm = Read-Host "Søk på tittel, arrangør eller rom"
            
            if ($searchTerm) {
                $today = Get-Date
                $startDate = $today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $endDate = $today.AddDays(365).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                
                $events = Get-Events -StartDate $startDate -EndDate $endDate -SearchTerm $searchTerm
                Show-Events -Events $events -Title "SØKERESULTAT: '$searchTerm'"
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
                
                $startDate = $startParsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $endDate = $endParsed.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                
                $events = Get-Events -StartDate $startDate -EndDate $endDate
                Show-Events -Events $events -Title "PERIODE: $startInput - $endInput"
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
            
            Load-Entities
            
            Write-Host ""
            Write-Host "✓ Data oppdatert!" -ForegroundColor $colors.Success
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
    
    # Clear screen mellom menyer (valgfritt - kommenter ut hvis du vil beholde historikk)
    # Clear-Host
}

Write-Host ""
Write-Host "Ha en fin dag! 👋" -ForegroundColor $colors.Success
Write-Host ""
