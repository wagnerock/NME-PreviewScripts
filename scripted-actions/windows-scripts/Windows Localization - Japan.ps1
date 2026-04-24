#description: Configures system localization settings for Japan: installs ja-JP language pack, sets system locale, timezone, culture, preferred UI language, home location, user language list, and copies settings to the Welcome screen.
#tags: Localization

# Install language pack
Install-Language ja-JP

# Set system locale
Set-WinSystemLocale -SystemLocale ja-JP

# Set timezone
Set-TimeZone -Id "Tokyo Standard Time"

# Set culture
Set-Culture -CultureInfo ja-JP

# Set preferred UI language
Set-SystemPreferredUILanguage ja-JP

# Set home location to Japan
Set-WinHomeLocation -GeoId 0x7a

# Set user language list
$langList = New-WinUserLanguageList -Language "ja-JP"
Set-WinUserLanguageList $langList -Force

# Copy language settings to Welcome screen and new user accounts
Install-Language ja-JP -CopyToSettings

### End Script ###
