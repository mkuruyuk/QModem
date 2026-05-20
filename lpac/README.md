# lpac for QModem — eSIM/eUICC Support

Custom **lpac 2.3.0** patched for removable eSIM on **Fibocom L850-GL** and **Foxconn T99W175** (USB mode) on OpenWrt.

## What's in This Directory

```
lpac/
├── README.md               ← This file
├── PATCHES.md              ← Patch summary (quick reference)
├── lpac-patch/             ← Full lpac 2.3.0 source with all patches applied
│   ├── driver/apdu/mbim.c  ← Key patched file
│   ├── euicc/              ← eUICC library (unmodified)
│   └── ...
└── openwrt-package/        ← OpenWrt build files
    ├── Makefile            ← Package Makefile for OpenWrt SDK
    ├── files/              ← Wrapper script + UCI config
    │   ├── lpac.sh         ← /usr/bin/lpac wrapper (reads UCI, sets env)
    │   └── lpac.uci        ← /etc/config/lpac defaults
    └── patches/            ← Patch files (apply to upstream lpac 2.3.0)
        ├── 100-lpac-mbim-skip-slot-mapping-env.patch
        ├── 110-lpac-mbim-use-extended-class-byte.patch
        ├── 120-lpac-mbim-open-channel-select-p2-0c.patch
        └── 130-lpac-mbim-append-le00-to-envelope.patch
```

## What Was Patched from Upstream lpac

Upstream: [estkme-group/lpac v2.3.0](https://github.com/estkme-group/lpac/tree/v2.3.0)

Only **one file** is modified: `driver/apdu/mbim.c` (the MBIM APDU backend).

The patches fix 4 issues that prevent lpac from communicating with removable eSIM cards on L850-GL and T99W175 modems:

### Patch 1: Skip MBIM Device Slot Mapping

| | |
|---|---|
| **File** | `driver/apdu/mbim.c` |
| **Patch** | `100-lpac-mbim-skip-slot-mapping-env.patch` |
| **Problem** | L850-GL rejects MBIM Device Slot Mapping with `OperationNotAllowed` |
| **Fix** | Add env `LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1` to skip slot mapping |
| **Why** | L850-GL is single-slot; slot mapping is unnecessary and causes init failure |

### Patch 2: Use Extended Class Byte Type

| | |
|---|---|
| **File** | `driver/apdu/mbim.c` |
| **Patch** | `110-lpac-mbim-use-extended-class-byte.patch` |
| **Problem** | Upstream uses `MBIM_UICC_CLASS_BYTE_TYPE_INTER_INDUSTRY` → L850-GL returns `SW 6E00` |
| **Fix** | Change to `MBIM_UICC_CLASS_BYTE_TYPE_EXTENDED` |
| **Why** | L850-GL requires extended class byte for UICC Low-Level Access APDU |

### Patch 3: Open Channel with selectp2arg=12

| | |
|---|---|
| **File** | `driver/apdu/mbim.c` |
| **Patch** | `120-lpac-mbim-open-channel-select-p2-0c.patch` |
| **Problem** | Upstream opens logical channel with `selectp2arg=0` → L850-GL fails to select ISD-R |
| **Fix** | Change to `selectp2arg=12` (0x0C = "No data returned") |
| **Why** | ISD-R applet on L850-GL requires P2=0x0C for SELECT command |

### Patch 4: Append Le=00 to Envelope APDU

| | |
|---|---|
| **File** | `driver/apdu/mbim.c` |
| **Patch** | `130-lpac-mbim-append-le00-to-envelope.patch` |
| **Problem** | Upstream sends STORE DATA (E2) without Le byte → L850-GL returns empty data |
| **Fix** | Append `Le=00` when APDU is case 4 (INS=E2, length = 5+Lc) |
| **Why** | Le=00 tells the card to return all available response bytes |

### What's NOT Patched

Everything else in lpac is unmodified:
- QMI backend — unchanged
- AT backend — unchanged
- HTTP/curl backend — unchanged
- euicc library (SGP.22 protocol) — unchanged
- CLI interface — unchanged
- All other MBIM logic (open/close device, proxy support) — unchanged

## QModem Integration

When used with QModem, lpac shares `/dev/cdc-wdm0` with quectel-CM via `mbim-proxy`:

```
/dev/cdc-wdm0
      │
      ▼
[mbim-proxy (libmbim)]
      │
      ├──► quectel-CM -p mbim-proxy  (internet)
      └──► lpac (USE_PROXY=1)         (eSIM APDU)
```

Non-disruptive operations (chip info, profile list) run without interrupting internet.

### Enable in QModem:

```sh
# Automatic for MBIM modems when esim_support=1 (default)
uci set qmodem.<section>.use_mbim_proxy='1'
uci commit qmodem
/etc/init.d/qmodem_network reload
```

## Building

```sh
# In OpenWrt SDK
cp openwrt-package/Makefile feeds/packages/utils/lpac/Makefile
cp openwrt-package/patches/* feeds/packages/utils/lpac/patches/

make menuconfig  # Enable: Utilities → lpac → LPAC_WITH_MBIM
make package/lpac/compile V=s
```

## Tested On

- OpenWrt 25.12.2 (ipq40xx/generic, arm_cortex-a7)
- Fibocom L850-GL (MBIM mode, removable 9eSIM)
- Foxconn T99W175 (MBIM mode USB, removable 9eSIM)
- EID successfully read, profiles listed and switched

## License

Upstream lpac license applies. See `lpac-patch/LICENSES/`.
Patches are MIT-licensed for L850-GL/T99W175 compatibility.
