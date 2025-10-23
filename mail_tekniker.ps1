# Dette scriptet tar eventID fra URL og oppretter mail i Outlook 

#............................................................................
# Set up variables for authentication
$clientID = "45i054svbmkrvb8hijo5st2koh"
$clientSecret = "722e0kdr3govijh6trqjdjemk91us89il3368amhhmqc42sod24"
$tokenURL = 'https://auth-api.eu-venueops.com/token'

# Construct payload for authentication
$payload = @{
    clientSecret = $clientSecret
    clientId = $clientID
    } | ConvertTo-Json

# Send POST request to obtain JWT token
$tokenResponse = Invoke-RestMethod -Uri $tokenURL -Method Post -Body $payload -ContentType "application/json"

# Extract JWT token from the response
$jwtToken = $tokenResponse.accessToken  # Assuming 'access_token' is the property containing the JWT

# Set up headers with JWT token for authentication
$headers2 = @{
    Authorization = "Bearer $jwtToken"
}

#------------
$venUrl = Get-Clipboard
$urlformail = $venUrl -split "/" | where {$_ -like '*event-*'}
#------------
$url = "https://api.eu-venueops.com/v1/events/$urlformail"
$function = "https://api.eu-venueops.com/v1/functions/event/$urlformail"
# Make the GET request with JWT token in the headers
$response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers2 
$functionResponse = Invoke-RestMethod -Uri $function -Method Get -Headers $headers2 

# Hent morgendagens dato
$tomorrow = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")

# Filtrer for arrangement funksjoner som er i morgen
$allArrFunc = $functionResponse | where {
    $_.functionTypeName -eq "Arrangement" -and 
    $_.startDate -eq $tomorrow
}

# Hvis det finnes flere arrangement funksjoner, la brukeren velge
if ($allArrFunc.Count -gt 1) {
    Write-Host "`nFant $($allArrFunc.Count) arrangement funksjoner for i morgen:" -ForegroundColor Yellow
    Write-Host "="*60
    
    for ($i = 0; $i -lt $allArrFunc.Count; $i++) {
        $func = $allArrFunc[$i]
        Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Cyan
        Write-Host "$($func.roomName) | " -NoNewline -ForegroundColor Green
        Write-Host "$($func.startTime) - $($func.endTime) | " -NoNewline
        Write-Host "$($func.functionStatus)" -ForegroundColor Magenta
    }
    
    Write-Host "="*60
    $choice = Read-Host "`nVelg arrangement SLUTT (1-$($allArrFunc.Count))"
    $arrFunc = $allArrFunc[$choice - 1]
    
} elseif ($allArrFunc.Count -eq 1) {
    $arrFunc = $allArrFunc
    Write-Host "`nBruker arrangement funksjon: $($arrFunc.roomName) $($arrFunc.startTime)-$($arrFunc.endTime)" -ForegroundColor Green
} else {
    Write-Host "`nFANT INGEN ARRANGEMENT FUNKSJONER FOR I MORGEN!" -ForegroundColor Red
    exit
}

#echo $arrFunc
#Tekniker delen - hvis det finnes flere tekniker funksjoner, bruk den fra morgendagen

$allTekniker = $functionResponse | where {
    $_.functionTypeName -eq "Tekniker" -and 
    $_.functionStatus -ne "canceled"
}

# Hvis det bare er 1 tekniker funksjon, bruk den. Hvis flere, bruk morgendagens
if ($allTekniker.Count -eq 1) {
    $tekniker = $allTekniker
} else {
    $tekniker = $allTekniker | where { $_.startDate -eq $tomorrow }
}
$staff1 = $tekniker.staffAssignments | where {$_.staffAssignmentName -eq "FTekniker 1"}
$staff2 = $tekniker.staffAssignments | where {$_.staffAssignmentName -eq "FTekniker 2"}
#echo $tekniker
$staff1Mail = $staff1.staffMemberEmail
$staff2Mail = $staff2.staffMemberEmail

$staff1Name = $staff1.staffMemberName
$staff2Name = $staff2.staffMemberName

#echo $staff1Mail

# Format Date - bruk morgendagens dato siden det er den vi behandler
$dateObject = (Get-Date).AddDays(1)
$formatDate = $dateObject.ToString("dd.MM.yyyy")

# Beregn "Teknikk klart" - 1 time før arrangementsstart
$arrStartTime = [DateTime]::Parse($arrFunc.startTime)
$teknikkKlart = $arrStartTime.AddHours(-1).ToString("HH:mm")

# Create mail
#$outlook = [System.Runtime.Interopservices.Marshal]::GetActiveObject('Outlook.Application')
#if (-not $outlook){
$outlook = New-Object -ComObject Outlook.Application

$mailmessage = $outlook.CreateItem(0)

#$mailMessage.From = "pal@litteraturhuset.no"
#$mailMessage.From = "pal@litteraturhuset.no"
$boomName = if ($staff2Name) {" og $($staff2Name)"}
$mailMessage.To = "$staff1Mail; $staff2Mail"

$mailMessage.BodyFormat = 2
#$mailMessage.CC.Add("ccrecipient@example.com")
#$mailMessage.Bcc.Add("bccrecipient@example.com")

$mailMessage.Subject = "Teknikerjobb for $($formatDate), '$($response.Name)'"

$htmlBody = @"
<html>
<head>
    <style>
        /* Add your CSS styles here */
        body {
            line-height: 0,5;
            margin: 0;
            padding: 0;
        }
        .signatur {
            color: #385623;
        }
        a {
            color: #538135;
        }
        .bestilling {
            color: #1a3f00;
            font-size: 10px;
        }
        .logo {
            width: 10px; /* Set your desired width */
            height: auto;
        }
    </style>
</head>
<body>
<p>Hei $($staff1Name) $($boomName)</p> 
<p>Her kommer info om teknikerjobben $($formatDate).</p>
Sted: $($arrFunc.roomName)
<br>
Hva: $($response.Name)
<br>
Arrangementsstart: $($arrFunc.startTime), ferdig $($arrFunc.endTime)
<br>
Teknikk klart: $teknikkKlart
<br>
<p>Ser det greit ut?</p>
<div class="signatur">
<p>Vennlig hilsen</p>
Pål Bredrup
<br>
Teknisk Produsent
<br>
Litteraturhuset <br>
------------------------------- <br>
Tlf: 99038200
<br>
<a href="mailto:pal@litteraturhuset.no">pal@litteraturhuset.no</a></p>
-------------------------------<br>
<img class="logo" src="C:\Users\PålBredrup\OneDrive - Stiftelsen Litteraturhuset\Bilder\Skjermbilder\resssise.jpeg">
</div>
<n>
</body>
</html>
"@

$mailMessage.HTMLBody = $htmlBody


$mailMessage.Display()
