# lpac-l850gl-openwrt

Custom **lpac 2.3.0** for **Fibocom L850-GL** + removable eSIM on **OpenWrt 25.12.2**.

Also tested and working on **Foxconn T99W175** in USB mode.

This patch was created because L850-GL can communicate with removable eSIM via **MBIM Microsoft Low-Level UICC Access**, but standard `lpac` MBIM fails on several L850-GL implementation details.

## QModem Integration (Zero Conflict)

lpac integrates with QModem through **mbim-proxy** (libmbim). Architecture:

```
/dev/cdc-wdm0
      │
      ▼
[mbim-proxy (libmbim)]  ← shared access daemon
      │
      ├──► quectel-CM -p mbim-proxy  (QModem internet dial)
      │
      └──► lpac (LPAC_APDU_MBIM_USE_PROXY=1)  (eSIM management)
```

### Non-Disruptive Operations (internet stays up):
- `lpac chip info` — read EID
- `lpac profile list` — list profiles
- `lpac notification list` — list pending notifications

### Disruptive Operations (internet temporarily down, auto-reconnect):
- `lpac profile enable` — switch active profile
- `lpac profile disable` — disable profile
- `lpac profile delete` — delete profile

QModem automatically handles stop/restart of the connection for disruptive operations via `esim_ctrl.sh`.

### How to Enable in QModem:

```sh
# Automatically enabled when MBIM modem is detected and esim_support=1 (default)
# Manual override per-modem:
uci set qmodem.<modem_section>.use_mbim_proxy='1'
uci commit qmodem
/etc/init.d/qmodem_network reload
```

Test results on OpenWrt `25.12.2 ipq40xx/generic arm_cortex-a7_neon-vfpv4`:

- `lpac chip info` successfully reads EID.
- `lpac profile list` successfully reads profile list.
- Example EID: `89034011099300000025800001320291`.

## Repository Contents

```text
lpac-l850gl-2.3.0/          Full lpac 2.3.0 source with patches applied
openwrt-package/            Makefile + patches for OpenWrt package feed
openwrt-package/patches/    L850-GL patches for the lpac OpenWrt package
```

## Why Does Standard LPAC Fail on L850-GL?

From USBPcap on Windows and `mbimcli` testing, the correct path is not AT commands. Windows uses:

- MBIM service: `ms-uicc-low-level-access`
- UUID: `c2f6588e-f037-4bc9-8665-f4d44bd09367`
- ISD-R AID: `A0000005591010FFFFFFFF8900000100`
- APDU ES10x/SGP.22

Manual commands that successfully read EID:

```sh
mbimcli -d /dev/cdc-wdm0 --no-open=10 --no-close \
  --ms-set-uicc-open-channel='application-id=A0000005591010FFFFFFFF8900000100,selectp2arg=12,channel-group=1'

mbimcli -d /dev/cdc-wdm0 --no-open=10 --no-close \
  --ms-set-uicc-apdu='channel=1,secure-message=none,classbyte-type=extended,command=81E2910006BF3E035C015A00'
```

Standard LPAC differs on several points, requiring patches.

## Patches Applied

### 1. Skip MBIM Device Slot Mapping

File: `openwrt-package/patches/100-lpac-mbim-skip-slot-mapping-env.patch`

Standard LPAC calls MBIM **Device Slot Mapping** during init. L850-GL rejects this with `OperationNotAllowed`, even though low-level UICC APDU actually works.

Patch adds environment variable:

```sh
LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1
```

When active, LPAC skips slot mapping and proceeds directly to open-channel/APDU.

### 2. Use MBIM UICC class byte type `extended`

File: `openwrt-package/patches/110-lpac-mbim-use-extended-class-byte.patch`

The successful manual `mbimcli` command uses:

```text
classbyte-type=extended
```

Standard LPAC uses `MBIM_UICC_CLASS_BYTE_TYPE_INTER_INDUSTRY`, which on L850-GL causes `SW 6E00` or incorrect responses.

Patch changes APDU transmit to:

```c
MBIM_UICC_CLASS_BYTE_TYPE_EXTENDED
```

### 3. Open channel with `selectp2arg=12` / `0x0C`

File: `openwrt-package/patches/120-lpac-mbim-open-channel-select-p2-0c.patch`

The successful manual `mbimcli` opens channel with:

```text
selectp2arg=12
```

Patch changes:

```c
mbim_message_ms_uicc_low_level_access_open_channel_set_new(aid_len, aid, 0, 1, &error)
```

to:

```c
mbim_message_ms_uicc_low_level_access_open_channel_set_new(aid_len, aid, 12, 1, &error)
```

### 4. Append trailing `Le=00` to APDU ES10x envelope

File: `openwrt-package/patches/130-lpac-mbim-append-le00-to-envelope.patch`

Successful manual command:

```text
81 E2 91 00 06 BF 3E 03 5C 01 5A 00
```

Standard LPAC sends without the trailing `00`:

```text
81 E2 91 00 06 BF 3E 03 5C 01 5A
```

On L850-GL, without `Le=00`, the modem/eUICC may reply `SW 9000` but with empty data. This patch appends `Le=00` for `E2` APDU case 4 when APDU length equals `5 + Lc`.

## Usage on Router

Set LPAC configuration:

```sh
uci set lpac.global.apdu_backend='mbim'
uci set lpac.global.custom_isd_r_aid='A0000005591010FFFFFFFF8900000100'
uci set lpac.global.apdu_debug='0'
uci set lpac.mbim.device='/dev/cdc-wdm0'
uci set lpac.mbim.proxy='1'
uci commit lpac
```

Test:

```sh
lpac chip info
lpac profile list
```

Pretty output:

```sh
lpac chip info | jq
lpac profile list | jq
```

## Profile Management

List profiles:

```sh
lpac profile list | jq -r '.payload.data[] | "\(.profileState)  \(.iccid)  \(.profileNickname)"'
```

Enable profile by ICCID:

```sh
lpac profile enable <ICCID> 0
```

If successful but modem doesn't attach to network, try refresh flag `1`:

```sh
lpac profile enable <ICCID> 1
```

After enabling, wait 30-60 seconds. If modem doesn't switch network, restart the modem interface. Do not run `/etc/init.d/network stop` if your SSH session goes through the router.

Download profile (LPAC 2.3.0 format):

```sh
lpac profile download -a 'LPA:1$rsp.truphone.com$MATCHING-ID'
lpac profile download -s rsp.truphone.com -m 'MATCHING-ID'
```

Delete profile:

```sh
lpac profile delete <ICCID>
lpac notification process -a -r
```

Delete only removes the profile and creates a notification; notifications should be processed afterwards.

## Building OpenWrt Package

Tested target:

```text
OpenWrt 25.12.2
DISTRIB_TARGET=ipq40xx/generic
DISTRIB_ARCH=arm_cortex-a7_neon-vfpv4
```

Build steps:

```sh
cp /path/to/openwrt-package/Makefile feeds/packages/utils/lpac/Makefile
mkdir -p feeds/packages/utils/lpac/patches
cp /path/to/openwrt-package/patches/*.patch feeds/packages/utils/lpac/patches/

make menuconfig
# Utilities -> lpac -> Enable LPAC_WITH_MBIM

make package/lpac/compile V=s -j1
```

Install on router:

```sh
apk add --allow-untrusted --upgrade /tmp/lpac-2.3.0-r2.apk
```

## Security Notes

- Do not share EID/ICCID publicly unless necessary.
- Be careful with `profile delete` — it permanently removes the profile from eUICC.
- To switch profiles, use `profile enable`, not `delete`.

## License

Main source follows upstream LPAC license. See `lpac-l850gl-2.3.0/LICENSES/`.
L850-GL patches in `openwrt-package/patches/` are created for L850-GL/OpenWrt compatibility.
