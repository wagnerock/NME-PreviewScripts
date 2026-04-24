#description: Installs a language pack and configures system locale, culture, UI language, and home location for the selected country. Optionally sets the most common time zone.
#tags: Localization

<# Notes:
Installs the language pack for the selected country and applies system locale, culture,
preferred UI language, home location, and user language list settings. Optionally sets
the most common time zone for that country.

A reboot is required for all locale changes to take effect. Users must sign out and
back in for per-user settings (culture, language list) to apply.

If multiple countries are selected, all language packs will be installed and locale
settings will be applied in order — the last selected country wins for system-level
settings (system locale, culture, UI language, time zone).
#>

<# Variables:
{
  "Country": {
    "DisplayName": "Country / Language",
    "Description": "The country/language localization to apply.",
    "IsRequired": true,
    "Type": "string[]",
    "OptionsSet": [
      { "Value": "en-GB", "Label": "British English (United Kingdom)" },
      { "Value": "nl-NL", "Label": "Dutch (Netherlands)" },
      { "Value": "fr-FR", "Label": "French (France)" },
      { "Value": "de-DE", "Label": "German (Germany)" },
      { "Value": "it-IT", "Label": "Italian (Italy)" },
      { "Value": "ja-JP", "Label": "Japanese (Japan)" },
      { "Value": "nb-NO", "Label": "Norwegian Bokmål (Norway)" },
      { "Value": "pt-PT", "Label": "Portuguese (Portugal)" },
      { "Value": "es-ES", "Label": "Spanish (Spain)" },
      { "Value": "sv-SE", "Label": "Swedish (Sweden)" }
    ]
  },
  "SetTimeZone": {
    "DisplayName": "Set Time Zone",
    "Description": "Set the most common time zone for the selected country.",
    "IsRequired": false,
    "Type": "string",
    "OptionsSet": [
      { "Value": "true",  "Label": "Yes" },
      { "Value": "false", "Label": "No" }
    ]
  }
}
#>

param(
    [string[]]$Country,
    [string]$SetTimeZone = 'false'
)

$ScriptName = 'Windows Localization'
$LogDir = "C:\Windows\Temp\NMWLogs\ScriptedActions\$ScriptName"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path "$LogDir\$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" -Force

$localeMap = @{
    'en-GB' = @{ GeoId = 242; TimeZone = 'GMT Standard Time' }
    'nl-NL' = @{ GeoId = 176; TimeZone = 'W. Europe Standard Time' }
    'fr-FR' = @{ GeoId = 84;  TimeZone = 'Romance Standard Time' }
    'de-DE' = @{ GeoId = 94;  TimeZone = 'W. Europe Standard Time' }
    'it-IT' = @{ GeoId = 118; TimeZone = 'W. Europe Standard Time' }
    'ja-JP' = @{ GeoId = 122; TimeZone = 'Tokyo Standard Time' }
    'nb-NO' = @{ GeoId = 177; TimeZone = 'W. Europe Standard Time' }
    'pt-PT' = @{ GeoId = 193; TimeZone = 'GMT Standard Time' }
    'es-ES' = @{ GeoId = 217; TimeZone = 'Romance Standard Time' }
    'sv-SE' = @{ GeoId = 221; TimeZone = 'W. Europe Standard Time' }
}

foreach ($locale in $Country) {
    if (-not $localeMap.ContainsKey($locale)) {
        Write-Warning "Unknown locale '$locale' — skipping"
        continue
    }

    $settings = $localeMap[$locale]
    Write-Host "Applying localization for $locale..."

    Install-Language $locale
    Set-WinSystemLocale -SystemLocale $locale
    Set-Culture -CultureInfo $locale
    Set-SystemPreferredUILanguage $locale
    Set-WinHomeLocation -GeoId $settings.GeoId

    $langList = New-WinUserLanguageList -Language $locale
    Set-WinUserLanguageList $langList -Force

    Install-Language $locale -CopyToSettings

    if ($SetTimeZone -eq 'true') {
        Write-Host "Setting time zone to '$($settings.TimeZone)'..."
        Set-TimeZone -Id $settings.TimeZone
    }

    Write-Host "Localization for $locale applied successfully."
}

Stop-Transcript

### End Script ###
