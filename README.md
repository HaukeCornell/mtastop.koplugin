# MTA Bus Stop KOreader Plugin

A native Lua plugin for KOreader that displays real-time MTA bus arrivals and local weather. Optimized for Kindle e-ink displays.

## Features
- **Real-time SIRI API**: Live bus arrival data with "stops away" tracking.
- **Dynamic Weather**: Displays outside temperature (°C) in the top-right corner using Open-Meteo.
- **Orientation Independent**: Works in Portrait and Landscape (uses KOreader's system rotation).
- **Auto-Refresh**: Updates every 60 seconds.
- **Clean UI**: Minimalist design focused on readability.
- **Secure**: API key stored in a separate settings file.

## Installation
1. Copy the `mtastop.koplugin` folder to `koreader/plugins/`.
2. Restart KOreader.
3. Access via **Tools > MTA Bus Stops**.

## Configuration
### API Key (Required)
The API key is required for bus arrivals.
1. Run the plugin once to generate the settings file.
2. Open `koreader/settings/mtastop.lua` on your Kindle.
3. Edit the file:
```lua
return {
    ["api_key"] = "YOUR_MTA_API_KEY_HERE",
    ["latitude"] = 40.7128,  -- Optional: for weather
    ["longitude"] = -74.0060, -- Optional: for weather
}
```

### Stop IDs
Default stops are in `main.lua`.

## Interaction
- **Center Tap**: Close/Exit.
- **Rotation**: Use the system menu in KOreader to change orientation.

## Credits
- Based on the [Digital Clock Plugin](https://github.com/koreader/koreader/tree/master/plugins/digitalclock.koplugin).
- Logic ported from the [bustime-display](https://github.com/HueFlux/bustime-display) Python app.
