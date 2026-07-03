<#
.SYNOPSIS
    Interaktives Steuerungsskript für Worx Landroid.
.DESCRIPTION
    Steuert einen Worx Landroid Mäher über die offizielle Worx Cloud API.
    Anmeldedaten werden verschlüsselt lokal gespeichert. Das Zugriffstoken
    wird automatisch erneuert, sodass lange Sitzungen möglich sind.
#>

$ConfigFile = Join-Path $env:LOCALAPPDATA "Landroid_Config.xml"

# ==============================================================================
# KONFIGURATION  (aktualisiert gemäß pyworxcloud v6 / Worx Cloud API v2)
# ==============================================================================
$AuthUrl   = "https://id.worx.com/oauth/token"          # Positec Identity Server
# WICHTIG: ClientId muss vom Benutzer in die Konfiguration eingetragen werden.
# Siehe Kommentar unten zur Einrichtung.
$ClientId  = ""  # Wird von Load-ClientId() geladen
$DeviceUrl = "https://api.worxlandroid.com/api/v2/product-items"

$global:Headers        = @{}
$global:DeviceId       = ""   # numerische ID – nur zum Filtern der Liste
$global:SerialNumber   = ""   # Seriennummer – wird in API-URLs verwendet
$global:MowerName      = ""
$global:RefreshToken     = ""
$global:TokenExpiry      = 0
$global:MqttEndpoint     = ""   # MQTT-Broker-Hostname (aus Geraetedaten)
$global:MqttTopicIn      = ""   # MQTT-Eingabetopic fuer Befehle an den Maeher
$global:MqttTopicOut     = ""   # MQTT-Ausgabetopic fuer Antworten vom Maeher
$global:UserId           = ""   # Worx-Account-ID
$global:DeviceUuid       = ""   # Geraete-UUID (Protokoll 1 / Vision-Serie)
$global:DeviceProtocol   = 0    # 0 = Legacy Landroid, 1 = Vision-Serie
$global:DeviceOnline     = $false
$global:PendingCfgValues = @{}   # zuletzt gesendete, aber noch nicht via API bestaetigte cfg-Werte
$global:HeaderStatusText = "Status: n/v"
$global:HeaderStatusColor = "DarkGray"

# ==============================================================================
# KONFIGURATION: ClientId laden
# ==============================================================================
# Die OAuth2 Client-ID muss vom Benutzer bereitgestellt werden.
# Optionen zur Einrichtung:
#   1. Umgebungsvariable setzen:
#      [Environment]::SetEnvironmentVariable("LANDROID_CLIENT_ID", "your-client-id", "User")
#   2. In einem lokalen secrets.ps1 definieren:
#      $env:LANDROID_CLIENT_ID = "your-client-id"
#   3. Manuell in diesem Script eintragen (NICHT in Git posten!)
function Load-ClientId {
    if (-not [string]::IsNullOrWhiteSpace($env:LANDROID_CLIENT_ID)) {
        return $env:LANDROID_CLIENT_ID
    }
    
    $SecretsFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "secrets.ps1"
    if (Test-Path $SecretsFile) {
        . $SecretsFile
        if (-not [string]::IsNullOrWhiteSpace($LANDROID_CLIENT_ID)) {
            return $LANDROID_CLIENT_ID
        }
    }
    
    throw @"
Die OAuth2 Client-ID konnte nicht geladen werden.
Bitte eine der folgenden Optionen wählen:

1. Umgebungsvariable setzen:
   [Environment]::SetEnvironmentVariable("LANDROID_CLIENT_ID", "your-client-id", "User")

2. Datei 'secrets.ps1' neben diesem Script erstellen mit:
   `$LANDROID_CLIENT_ID = "your-client-id"

3. Diese Variable im Script direkt setzen (NICHT in Git committen!)
   `$ClientId = "your-client-id"

Besorge deine Client-ID von der Worx API-Dokumentation oder dem Worx Entwickler-Portal.
"@
}

# Lade ClientId beim Script-Start
try {
    $ClientId = Load-ClientId
} catch {
    Write-Host "FEHLER beim Laden der ClientId: $_" -ForegroundColor Red
    Read-Host "Drücke Enter zum Beenden"
    exit
}

# ==============================================================================
# UI-HILFSFUNKTIONEN
# ==============================================================================
function Write-Banner {
    Clear-Host
    $HeaderInfo = if ([string]::IsNullOrWhiteSpace($global:HeaderStatusText)) { "Status: n/v" } else { $global:HeaderStatusText }
    $HeaderLine = " $HeaderInfo"
    if ($HeaderLine.Length -gt 42) { $HeaderLine = $HeaderLine.Substring(0, 42) }

    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |     Landroid Interactive Controller      |" -ForegroundColor Cyan
    Write-Host ("  |" + $HeaderLine.PadRight(42) + "|") -ForegroundColor $global:HeaderStatusColor
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-OK   ([string]$Msg) { Write-Host "  [OK]    " -ForegroundColor Green  -NoNewline; Write-Host $Msg }
function Write-Fail ([string]$Msg) { Write-Host "  [FEHLER]" -ForegroundColor Red    -NoNewline; Write-Host $Msg }
function Write-Warn ([string]$Msg) { Write-Host "  [WARN]  " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Step ([string]$Msg) { Write-Host "  [...]   " -ForegroundColor DarkCyan -NoNewline; Write-Host $Msg -ForegroundColor Gray }

function Get-BatteryBar ([int]$Percent) {
    $Percent  = [math]::Max(0, [math]::Min(100, $Percent))
    $Filled   = [math]::Round($Percent / 10)
    $Empty    = 10 - $Filled
    $Bar      = ('#' * $Filled) + ('-' * $Empty)
    $Color    = if ($Percent -ge 50) { 'Green' } elseif ($Percent -ge 20) { 'Yellow' } else { 'Red' }
    return [PSCustomObject]@{ Bar = $Bar; Color = $Color }
}

function Update-HeaderStatusCache {
    # Standardwert, falls keine frischen Daten gelesen werden koennen
    $global:HeaderStatusText = "Status: n/v"
    $global:HeaderStatusColor = "DarkGray"

    if ([string]::IsNullOrWhiteSpace($global:DeviceId)) { return }
    if ($null -eq $global:Headers -or -not $global:Headers.ContainsKey('Authorization')) { return }

    try {
        if (-not (Invoke-TokenRefresh)) {
            $global:HeaderStatusText = "Status: Token abgelaufen"
            $global:HeaderStatusColor = "DarkYellow"
            return
        }

        $AllDevices = Invoke-RestMethod -Uri "${DeviceUrl}?status=1" -Method Get -Headers $global:Headers
        $Mower = $AllDevices | Where-Object { $_.id -eq $global:DeviceId } | Select-Object -First 1
        if ($null -eq $Mower) {
            $global:HeaderStatusText = "Status: Gerät nicht gefunden"
            $global:HeaderStatusColor = "DarkYellow"
            return
        }

        $IsOnline = [bool]$Mower.online
        $Payload  = $Mower.last_status.payload
        $Di       = if ($null -ne $Payload.dat) { $Payload.dat } else { $Payload.datainfo }

        $StateCode = if ($null -ne $Di -and $null -ne $Di.ls) { [int]$Di.ls } elseif ($null -ne $Di -and $null -ne $Di.state) { [int]$Di.state } else { $null }
        $BattPct   = if ($null -ne $Di -and $null -ne $Di.bt) { [int]$Di.bt.p } elseif ($null -ne $Di -and $null -ne $Di.battery -and $null -ne $Di.battery.percent) { [int]$Di.battery.percent } else { $null }

        $StateMap = @{
            0='Wartet';            1='In Ladestation';     2='Startsequenz'
            3='Verlaesst Station';  4='Folgt Grenzkabel';   5='Sucht Ladestation'
            6='Sucht Grenzkabel';  7='Maehen';             8='Maehen'
            9='Festgefahren';      10='Messer blockiert';  11='Debug'
            12='Fernsteuerung';    30='Faehrt nach Hause'; 31='Zonierung'
            32='Kantenschnitt';    33='Sucht Bereich';     34='Pausiert'
            103='Sucht Zone';      104='Sucht Ladestation'; 110='Grenzueberschreitung'
            111='Erkundet Rasen'
        }

        $StatusText = if ($null -eq $StateCode) { 'n/v' } elseif ($StateMap.ContainsKey($StateCode)) { $StateMap[$StateCode] } else { "Code $StateCode" }
        if (-not $IsOnline) { $StatusText = "Offline (letzter: $StatusText)" }

        $BattText = if ($null -ne $BattPct) { "$BattPct%" } else { "n/v" }
        $global:HeaderStatusText = "Status: $StatusText | Akku: $BattText"

        $global:HeaderStatusColor = if (-not $IsOnline) {
            'Red'
        } else {
            switch ($StateCode) {
                { $_ -in @(7, 8) }       { 'Green'  }
                { $_ -in @(1, 34, 30) }  { 'Cyan'   }
                { $_ -in @(9, 10, 11) }  { 'Red'    }
                default                   { 'White'  }
            }
        }
    } catch {
        $global:HeaderStatusText = "Status: Abruf fehlgeschlagen"
        $global:HeaderStatusColor = "DarkYellow"
    }
}

# ==============================================================================
# TOKEN-VERWALTUNG
# ==============================================================================
function Invoke-TokenRefresh {
    $Now = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    if ($Now -lt ($global:TokenExpiry - 300)) { return $true }   # Token noch gültig

    Write-Step "Access-Token läuft ab – wird automatisch erneuert..."
    $Body = @{
        grant_type    = "refresh_token"
        client_id     = $ClientId
        scope         = "*"
        refresh_token = $global:RefreshToken
    } | ConvertTo-Json

    $ReceivedReplyPayload = $null

    try {
        $Resp = Invoke-RestMethod -Uri $AuthUrl -Method Post -Body $Body -ContentType "application/json"
        $global:Headers      = @{ "Authorization" = "Bearer $($Resp.access_token)"; "Accept" = "application/json" }
        $global:RefreshToken = $Resp.refresh_token
        $global:TokenExpiry  = $Now + [int]$Resp.expires_in
        Write-OK "Token erneuert."
        return $true
    } catch {
        Write-Fail "Token-Erneuerung fehlgeschlagen: $($_.Exception.Message)"
        return $false
    }
}

# ==============================================================================
# LOGIN
# ==============================================================================
function Invoke-WorxLogin {
    Write-Banner

    if (Test-Path $ConfigFile) {
        Write-Step "Lade gespeicherte Konfiguration..."
        $ConfigData  = Import-Clixml -Path $ConfigFile
        $Cred        = $ConfigData.Credential
        $TargetMower = $ConfigData.MowerName
    } else {
        Write-Host "  Erster Start – bitte Zugangsdaten eingeben:" -ForegroundColor Yellow
        Write-Host ""
        $UserEmail      = Read-Host "  Worx E-Mail-Adresse"
        $SecurePassword = Read-Host "  Worx Passwort" -AsSecureString
        $Cred           = New-Object System.Management.Automation.PSCredential ($UserEmail, $SecurePassword)
        $TargetMower    = Read-Host "  Mähername (leer = erster im Account)"

        $ConfigData = [PSCustomObject]@{ Credential = $Cred; MowerName = $TargetMower }
        $ConfigData | Export-Clixml -Path $ConfigFile
        Write-OK "Zugangsdaten verschlüsselt gespeichert."
        Write-Host ""
    }

    $AuthBody = @{
        client_id  = $ClientId
        grant_type = "password"
        username   = $Cred.UserName
        password   = $Cred.GetNetworkCredential().Password
        scope      = "*"
    } | ConvertTo-Json

    try {
        Write-Step "Verbinde mit id.worx.com..."
        $AuthResp = Invoke-RestMethod -Uri $AuthUrl -Method Post -Body $AuthBody -ContentType "application/json"

        $Now                 = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $global:Headers      = @{ "Authorization" = "Bearer $($AuthResp.access_token)"; "Accept" = "application/json" }
        $global:RefreshToken = $AuthResp.refresh_token
        $global:TokenExpiry  = $Now + [int]$AuthResp.expires_in
        Write-OK "Login erfolgreich! (Token gültig für $([math]::Round($AuthResp.expires_in / 3600, 1)) Std)"

        Write-Step "Suche Mäher im Account..."
        $Devices = Invoke-RestMethod -Uri "${DeviceUrl}?status=1" -Method Get -Headers $global:Headers

        if ($Devices.Count -eq 0) {
            Write-Fail "Keine Mäher im Account gefunden."
            Read-Host "  Drücke Enter zum Beenden"
            exit
        }

        if (-not [string]::IsNullOrWhiteSpace($TargetMower)) {
            $Match          = $Devices | Where-Object { $_.name -match $TargetMower }
            $SelectedDevice = if ($Match) { $Match[0] } else { $Devices[0] }
        } else {
            $SelectedDevice = $Devices[0]
        }

        $global:DeviceId       = $SelectedDevice.id
        $global:SerialNumber   = $SelectedDevice.serial_number
        $global:MowerName      = $SelectedDevice.name
        $global:MqttEndpoint   = $SelectedDevice.mqtt_endpoint
        $global:MqttTopicIn    = $SelectedDevice.mqtt_topics.command_in
        $global:MqttTopicOut   = $SelectedDevice.mqtt_topics.command_out
        $global:UserId         = $SelectedDevice.user_id
        $global:DeviceUuid     = $SelectedDevice.uuid
        $global:DeviceOnline   = [bool]$SelectedDevice.online

        # Wichtig: Protokoll aus API-Feld lesen (pyworxcloud), NICHT nur aus uuid ableiten.
        if ($null -ne $SelectedDevice.protocol) {
            $global:DeviceProtocol = [int]$SelectedDevice.protocol
        } else {
            # Fallback fuer alte API-Payloads ohne protocol-Feld
            $global:DeviceProtocol = if ([string]::IsNullOrEmpty($SelectedDevice.uuid)) { 0 } else { 1 }
        }

        if ($global:DeviceProtocol -eq 1 -and [string]::IsNullOrWhiteSpace($global:DeviceUuid)) {
            Write-Warn "API meldet Protokoll 1, aber uuid ist leer. Befehle koennen fehlschlagen."
        }
        Write-OK "Verbunden mit: $global:MowerName  (S/N: $global:SerialNumber, Protokoll: $global:DeviceProtocol)"

        if ($TargetMower -and -not ($Devices | Where-Object { $_.name -match $TargetMower })) {
            Write-Warn "Mäher '$TargetMower' nicht gefunden – ersten Mäher im Account verwendet."
        }

        Start-Sleep -Seconds 1
        return $true

    } catch {
        Write-Fail "Login fehlgeschlagen: $($_.Exception.Message)"
        if ($_.ErrorDetails) { Write-Fail "API-Antwort: $($_.ErrorDetails.Message)" }

        if (Test-Path $ConfigFile) {
            Remove-Item $ConfigFile -Force
            Write-Warn "Gespeicherte Konfiguration wurde bereinigt."
        }
        Read-Host "  Drücke Enter zum Beenden"
        exit
    }
}

# ==============================================================================
# STATUS
# ==============================================================================
function Get-MowerStatus {
    if (-not (Invoke-TokenRefresh)) { return }

    Write-Banner
    Write-Step "Lade aktuellen Status für '$global:MowerName'..."

    # Die Worx API v2 hat keinen Einzelgerät-Endpunkt mehr.
    # Stattdessen wird die Gesamtliste mit ?status=1 abgerufen und gefiltert.
    try {
        $AllDevices = Invoke-RestMethod -Uri "${DeviceUrl}?status=1" -Method Get -Headers $global:Headers
        $Mower = $AllDevices | Where-Object { $_.id -eq $global:DeviceId } | Select-Object -First 1
        if ($null -eq $Mower) {
            Write-Fail "Mäher mit ID '$global:DeviceId' nicht in der Geräteliste gefunden."
            Read-Host "  Drücke Enter..."
            return
        }
    } catch {
        Write-Fail "Status-Abruf fehlgeschlagen: $($_.Exception.Message)"
        if ($_.ErrorDetails) { Write-Fail "API-Antwort: $($_.ErrorDetails.Message)" }
        Read-Host "  Drücke Enter..."
        return
    }

    # Top-level Online-Flag der API (Live-Erreichbarkeit in der Cloud)
    $IsOnline = [bool]$Mower.online

    # API v2 liefert Daten unter 'dat'; ältere Firmware unter 'datainfo'
    $Payload = $Mower.last_status.payload
    $Di      = if ($null -ne $Payload.dat)      { $Payload.dat      } else { $Payload.datainfo }
    $Cfg     = $Payload.cfg

    # Statusfelder: neue API = ls/le/bt.p/bt.v/st.b  |  alte API = state/error/battery.percent
    $StateCode  = if ($null -ne $Di.ls)         { [int]$Di.ls               } else { [int]$Di.state   }
    $ErrorCode  = if ($null -ne $Di.le)         { [int]$Di.le               } else { [int]$Di.error   }
    $BattPct    = if ($null -ne $Di.bt)         { [int]$Di.bt.p             } else { [int]$Di.battery.percent }
    $BattVolt   = if ($null -ne $Di.bt)         { $Di.bt.v                  } else { $Di.battery.volt  }
    $BladeHours = if ($null -ne $Di.st)         { [math]::Round($Di.st.b / 3600, 1) } `
                  else                          { [math]::Round($Di.statistic.blade / 60, 1) }

    # API liefert cfg-Werte oft verzoegert. Bis zur Bestaetigung zeigen wir zuletzt
    # gesendete Werte mit '*' als pending overlay an.
    $TorqueDisplay = if ($global:PendingCfgValues.ContainsKey('tq')) {
        if ($null -ne $Cfg -and $null -ne $Cfg.tq -and [int]$Cfg.tq -eq [int]$global:PendingCfgValues['tq']) {
            $global:PendingCfgValues.Remove('tq') | Out-Null
            "$($Cfg.tq)%"
        } else {
            "$($global:PendingCfgValues['tq'])*%"
        }
    } elseif ($null -ne $Cfg -and $null -ne $Cfg.tq) {
        "$($Cfg.tq)%"
    } else {
        "n/v"
    }

    $RainDelayDisplay = if ($global:PendingCfgValues.ContainsKey('rd')) {
        if ($null -ne $Cfg -and $null -ne $Cfg.rd -and [int]$Cfg.rd -eq [int]$global:PendingCfgValues['rd']) {
            $global:PendingCfgValues.Remove('rd') | Out-Null
            "$($Cfg.rd) Min"
        } else {
            "$($global:PendingCfgValues['rd'])* Min"
        }
    } elseif ($null -ne $Cfg -and $null -ne $Cfg.rd) {
        "$($Cfg.rd) Min"
    } else {
        "n/v"
    }

    # Vollstaendige Zustands- und Fehlercodes aus pyworxcloud state.py
    $StateMap = @{
        0='Wartet';            1='In Ladestation';     2='Startsequenz'
        3='Verlaesst Station';  4='Folgt Grenzkabel';   5='Sucht Ladestation'
        6='Sucht Grenzkabel';  7='Maehen';             8='Maehen'
        9='Festgefahren';      10='Messer blockiert';  11='Debug'
        12='Fernsteuerung';    30='Faehrt nach Hause'; 31='Zonierung'
        32='Kantenschnitt';    33='Sucht Bereich';     34='Pausiert'
        103='Sucht Zone';      104='Sucht Ladestation'; 110='Grenzueberschreitung'
        111='Erkundet Rasen'
    }
    $ErrorMap = @{
        0='Kein Fehler';             1='Gefangen';                   2='Angehoben'
        3='Grenzkabel fehlt';        4='Ausserhalb Grenzkabel';      5='Regen-Verzoegerung'
        6='Tuer schliessen (Maehen)'; 7='Tuer schliessen (Heimweg)'; 8='Maehmotor blockiert'
        9='Radmotor blockiert';      10='Gefangen (Timeout)';        11='Auf dem Kopf'
        12='Akku leer';              13='Grenzkabel umgekehrt';      14='Ladefehler'
        15='Heimweg-Timeout';        16='Gesperrt';                  17='Akku-Temperatur'
        100='Docking-Fehler';        101='HBI-Fehler';               102='OTA-Fehler'
        103='Kartenfehler';          104='Zu starke Neigung'
    }

    $StatusText = if ($StateMap.ContainsKey($StateCode)) { $StateMap[$StateCode] } else { "Code $StateCode" }
    $ErrorText  = if ($ErrorMap.ContainsKey($ErrorCode)) { $ErrorMap[$ErrorCode] } else { "Code $ErrorCode" }

    # Wenn online=false, ist der oben gezeigte Status nur der letzte bekannte Zustand.
    if (-not $IsOnline) {
        $StatusText = "Offline (letzter: $StatusText)"
    }

    # Zustandsfarbe: Status 8 = Maehen (nicht Fehler!)
    $StateColor = switch ($StateCode) {
        { $_ -in @(7, 8) }       { 'Green'  }   # Maehen
        { $_ -in @(1, 34) }      { 'Cyan'   }   # Ladestation / Pause
        30                        { 'Cyan'   }   # Faehrt nach Hause
        { $_ -in @(9, 10, 11) }  { 'Red'    }   # Fehler/Blockiert
        default                   { 'White'  }
    }

    # le = "letzter Fehler" – er bleibt bestehen, auch wenn der Maeher wieder normal laeuft.
    # Nur als aktiv anzeigen wenn der Zustand selbst auf ein Problem hindeutet.
    $NormalStates  = @(0, 1, 7, 8, 30, 31, 32, 34)
    $ErrorIsActive = ($ErrorCode -ne 0) -and ($StateCode -notin $NormalStates)
    $ErrorColor    = if ($ErrorCode -eq 0) { 'Green' } elseif ($ErrorIsActive) { 'Red' } else { 'DarkYellow' }
    $ErrorDisplay  = if ($ErrorCode -eq 0) { $ErrorText } `
                     elseif ($ErrorIsActive) { $ErrorText } `
                     else { "(Letzt.) $ErrorText" }
    $BatBar     = Get-BatteryBar $BattPct

    # Jede Zeile: "  |" (3) + 42 Zeichen Inhalt + "|" (1) = 46 Zeichen gesamt
    # Label-Spalte: 12 Zeichen  |  Wert-Spalte: 30 Zeichen  |  Summe = 42
    $Sep = "  +$('-' * 42)+"

    Write-Host ""
    Write-Host $Sep -ForegroundColor Cyan
    Write-Host "  |  STATUS: $($global:MowerName.PadRight(32))|" -ForegroundColor White
    Write-Host $Sep -ForegroundColor Cyan

    # Status  (" Status   : " = 12 Zeichen innen, Wert padded auf 30)
    Write-Host "  | Status   : " -ForegroundColor Gray -NoNewline
    Write-Host "$($StatusText.PadRight(30))" -ForegroundColor $StateColor -NoNewline
    Write-Host "|" -ForegroundColor Cyan

    # Online-Flag explizit anzeigen
    $OnlineText  = if ($IsOnline) { 'Online' } else { 'Offline' }
    $OnlineColor = if ($IsOnline) { 'Green' } else { 'Red' }
    Write-Host "  | Verb.    : " -ForegroundColor Gray -NoNewline
    Write-Host "$($OnlineText.PadRight(30))" -ForegroundColor $OnlineColor -NoNewline
    Write-Host "|" -ForegroundColor Cyan

    # Fehler
    Write-Host "  | Fehler   : " -ForegroundColor Gray -NoNewline
    Write-Host "$($ErrorDisplay.PadRight(30))" -ForegroundColor $ErrorColor -NoNewline
    Write-Host "|" -ForegroundColor Cyan

    # Akku: " Akku     : [" = 13 innen  +  Bar(10)  +  Suffix padded auf 19  = 42
    $BattSuffix = "] $($BattPct.ToString().PadLeft(3))% ($($BattVolt)V)"
    Write-Host "  | Akku     : [" -ForegroundColor Gray -NoNewline
    Write-Host "$($BatBar.Bar)" -ForegroundColor $BatBar.Color -NoNewline
    Write-Host "$($BattSuffix.PadRight(19))|" -ForegroundColor Gray

    # Torque / Regen-Delay (1 fuehrendes Leerzeichen + Inhalt, PadRight auf 42)
    $Line5 = " Torque: $($TorqueDisplay.PadRight(7)) Regen-Delay: $RainDelayDisplay"
    Write-Host "  |$($Line5.PadRight(42))|" -ForegroundColor Gray

    # Maehdauer
    $Line6 = " Maehdauer gesamt: $BladeHours Std"
    Write-Host "  |$($Line6.PadRight(42))|" -ForegroundColor Gray

    Write-Host $Sep -ForegroundColor Cyan
    if ($global:PendingCfgValues.Count -gt 0) {
        Write-Host "  * = zuletzt gesendet, aber noch nicht durch API bestaetigt" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# Rest of the script continues as before...
# [MQTT functions, command sending, firmware upgrade functions, etc.]
