# MTA Bus Stop KOreader Plugin

A native Lua plugin for KOreader that displays real-time MTA bus arrivals. Optimized for Kindle e-ink displays.

## Features
- **Real-time SIRI API**: Live bus arrival data.
- **Orientation Support**: Tap the **top-right corner** (ROT area) to manually toggle between Portrait and Landscape.
- **Detailed Arrivals**: Shows bus lines, destinations, estimated minutes, and **how many stops away** the bus is.
- **Auto-Refresh**: Updates every 60 seconds with a clean timestamp.
- **Secure**: API key is stored in a separate settings file to prevent accidental leaks.

## Installation
1. Copy the `mtastop.koplugin` folder to `koreader/plugins/`.
2. Restart KOreader.
3. Access via **Tools > MTA Bus Stops**.

## Configuration
### API Key (Required)
For security, the API key is **not** included in the source code. To set it up:
1. Run the plugin once; it will create a template settings file.
2. Locate `koreader/settings/mtastop.lua` on your Kindle.
3. Edit the file and add your key:
```lua
return {
    ["api_key"] = "YOUR_MTA_API_KEY_HERE",
}
```
You can get a free key from the [MTA Bus Time API portal](https://new.mta.info/developers).

### Stop IDs
Default stops are in `main.lua`. Find your stop numbers [here](https://bustime-beta.mta.info/?search=505277&uuid=1e32f782-6f39-4290-8ed5-e259f6c51089).

## Interaction
- **Top-Right**: Toggle Rotation.
- **Center**: Close/Exit.

## Credits
- Based on the [Digital Clock Plugin](https://github.com/koreader/koreader/tree/master/plugins/digitalclock.koplugin).
- Logic ported from the [bustime-display](https://github.com/HueFlux/bustime-display) Python app.
