<div align="center">

# 🌡️ ThermalBar

### Live CPU & GPU temperature in your macOS menu bar - color-coded, native, lightweight.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1--M5-black?logo=apple)](https://support.apple.com/en-us/116943)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![No sudo](https://img.shields.io/badge/sudo-not%20required-success)]()

</div>

---

## Why ThermalBar?

Apple hides chip temperature behind private APIs. Most monitors are heavy Electron apps or need `sudo` every launch. ThermalBar is a **tiny native Swift app** that reads sensors directly and shows them as **color-coded numbers** in your menu bar - nothing else running, no dock icon, no bloat.

- 🟢 **Color-coded at a glance** - green when cool, orange when warm, red when hot, dark red when critical. Each value colored independently.
- 🌡️ **CPU temp** read natively via IOKit - works with zero dependencies.
- 🎮 **GPU temp + power draw** via an optional lightweight helper.
- 🪶 **Featherweight** - pure Swift, no Electron, no background bloat, no dock icon.
- 🔧 **Fully configurable** - toggle any metric, set your own color thresholds.
- 🔐 **No sudo, ever** - reads sensors through a private API without root.
- 🚀 **Auto-starts on login**, stays out of your way.

<div align="center">
<img src="banner.png" alt="ThermalBar menu bar preview" width="600">
</div>

## Install

```bash
git clone https://github.com/evilork/thermalbar.git
cd thermalbar
./install.sh
```

That's it. The installer builds the app, drops it in `/Applications`, and sets up auto-start. The menu bar numbers appear in a few seconds.

> First launch is unsigned - if macOS blocks it, right-click `ThermalBar.app` in `/Applications` → **Open** (one time).

### Requirements

- Apple Silicon Mac (M1-M5), macOS 13+
- [Xcode Command Line Tools](https://developer.apple.com/) - `xcode-select --install`
- [Homebrew](https://brew.sh) *(optional, for GPU temp + power)* - the installer auto-installs [`macmon`](https://github.com/vladkens/macmon) if present

CPU temperature works out of the box. GPU temperature and power require `macmon` (handled automatically by the installer).

## Configuration

Click the menu bar item to toggle metrics on/off, or edit `~/.config/thermalbar/config.json`:

```jsonc
{
  "cpuTemp": { "enabled": true, "thresholds": { "normal": 60, "warn": 75, "high": 90 } },
  "gpuTemp": { "enabled": true, "thresholds": { "normal": 60, "warn": 75, "high": 90 } },
  "power":   { "enabled": true, "thresholds": { "normal": 30, "warn": 55, "high": 80 } },
  "intervalSeconds": 3,
  "showLabels": true
}
```

| Field | What it does |
|-------|--------------|
| `enabled` | show this metric in the bar |
| `thresholds.normal / warn / high` | color cutoffs (°C, or W for power) |
| `intervalSeconds` | how often to refresh |
| `showLabels` | prefix `C` / `G` before temperatures |

**Color rule:** `value < normal` → 🟢 · `< warn` → 🟠 · `< high` → 🔴 · `≥ high` → 🟥
After editing, pick **Reload config** from the menu.

## How it works

- **CPU** - reads `PMU tdie` die-sensors directly through IOKit's private HID interface (the same source `powermetrics` uses), no root needed.
- **GPU + power** - a background `macmon serve` process exposes these over a local HTTP endpoint; ThermalBar reads them on each refresh. If the helper isn't running, those metrics simply hide and CPU keeps working.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, both launch agents, and config. (Leaves `macmon` - remove with `brew uninstall macmon` if you want.)

## Support / Donate

ThermalBar is free and open source. If it earned a spot in your menu bar, a tip is hugely appreciated 🙏

| Coin | Address |
|------|---------|
| **BTC** | `bc1pd47ssznzl6afr94zdkyk3g504h4l5m9etfg83lnwlsradg7yrrysk2wlt7` |
| **LTC** | `M9hXcyfRfaXajtzNbVV6pJwC5RoFbijfys` |
| **ETH** | `0x6e5afc8583239da03bf3fd21dd7fafe5e65e1670` |
| **SOL** | `FZ6jUxZUpzneTGgv4X7KAXmxjLrVAfksBojnw6mkEuqQ` |
| **TRON** | `TNHjSq6kc4bmt7tX5QGxd1YsGFa2XN62uQ` |
| **TON** | `UQCCFCDL7fDf6WTcEtAluxL9oAN8sKb3awjH7U752Xkzl1XI` |

## License

[MIT](LICENSE) © evilork

---

<div align="center">
<sub>Built for Apple Silicon. Star ⭐ if it's useful - it helps others find it.</sub>
</div>
