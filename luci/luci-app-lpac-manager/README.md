# luci-app-lpac-manager — eSIM Profile Manager for OpenWrt

## What is this?

**luci-app-lpac-manager** is a LuCI web interface and CLI tool for managing eSIM profiles on OpenWrt routers via **lpac 2.3.0**.

Adapted for **OpenWrt 24.10.x / 25.x** with three APDU backends:

- **MBIM** — primary, for modems in MBIM mode (recommended for QModem)
- **QMI** — for modems in QMI mode (PID 9025, etc.)
- **AT** — fallback, via modem AT port

Primary use case: external removable eSIM cards (9eSIM, eSIM.me) in LTE/5G modem SIM slots. Also works with embedded eUICC when accessible via supported backend.

## QModem Integration

This package is the official eSIM web UI for QModem. When installed with QModem:

- Appears as a tab inside QModem: **Modem → QModem → eSIM Manager**
- Uses `mbim-proxy` for conflict-free shared access with quectel-CM
- Non-disruptive operations (chip info, profile list) don't interrupt internet
- Disruptive operations (profile switch) are coordinated via `esim_ctrl.sh`
- Includes Telegram bot for remote management

## Features

### Web Interface (6 tabs)

| Tab | Functions |
|-----|-----------|
| **eSIM Info** | EID, eUICC firmware, free memory, SM-DP+/SM-DS addresses, modem status |
| **Profiles** | Profile table (name, ICCID, provider, status). Switch, Delete, Rename buttons |
| **Download** | Download new eSIM: QR code scan, LPA string, or SM-DP+ / Matching ID |
| **Notifications** | eUICC notifications. Process & Remove All, Clear All |
| **Config** | Backend type, device paths, MBIM proxy, SIM slot |
| **Telegram Bot** | Configure and manage Telegram bot for remote eSIM control |

### CLI Mode (SSH)

```sh
lpac-esim --api chip          # eUICC info (JSON)
lpac-esim --api profiles      # profile list (JSON)
lpac-esim --api modem-status  # modem status (JSON)
lpac-esim                     # interactive TUI menu
```

## Tested Hardware

| Component | Version / Model |
|-----------|----------------|
| OpenWrt | 24.10.x / 25.12.2 |
| Modems | Foxconn T99W175, Fibocom L850-GL |
| eSIM | 9eSIM removable eUICC v2.3.1 |
| lpac | 2.3.0 (patched for L850-GL/T99W175) |

## Requirements

| Package | Purpose |
|---------|---------|
| `lpac` 2.3.0+ | eUICC management binary |
| `libmbim` | MBIM protocol + mbim-proxy |
| `jq` | JSON parsing |
| `curl` / `libcurl` | HTTP for SM-DP+ communication |
| `luci-base` | LuCI framework |
| `luci-compat` | Lua compatibility (OpenWrt 25.x) |

## Installation

When using QModem, enable eSIM support in `make menuconfig`:

```
Utilities → qmodem → [*] Add eSIM/eUICC management (lpac) SUPPORT
```

This automatically installs `lpac`, `luci-app-lpac-manager`, and `qmodem-esim-bot`.

### Manual installation:

```sh
# OpenWrt 25.x (apk)
apk add --allow-untrusted /tmp/lpac-2.3.0-r2.apk
apk add --allow-untrusted /tmp/luci-app-lpac-manager.apk

# OpenWrt 24.x (opkg)
opkg install /tmp/lpac_2.3.0.ipk
opkg install /tmp/luci-app-lpac-manager.ipk
```

## Configuration

Default config (`/etc/config/lpac-esim`):

```
config lpac-esim 'main'
    option apdu_backend 'mbim'
    option mbim_device '/dev/cdc-wdm0'
    option mbim_proxy '1'
    option skip_slot_mapping '1'
```

For QModem users, this works out-of-box. The web UI Configuration tab allows changing all settings.

## Architecture

```
Browser → LuCI → lpac_esim.lua → lpac-esim --api → lpac binary → eUICC
                                       ↓
                              mbim-proxy (shared with quectel-CM)
```

## Credits

- [estkme-group/lpac](https://github.com/estkme-group/lpac) — lpac eUICC LPA
- [stich86/luci-app-epm](https://github.com/stich86/luci-app-epm) — original epm WebUI skeleton
- [afadillo-a11y/luci-app-lpac-manager](https://github.com/afadillo-a11y/luci-app-lpac-manager) — upstream fork
- [FUjr/QModem](https://github.com/FUjr/QModem) — QModem modem management

## License

MIT
