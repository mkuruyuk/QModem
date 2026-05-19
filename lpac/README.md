# lpac-l850gl-openwrt

Custom **lpac 2.3.0** untuk modem **Fibocom L850GL** + removable eSIM di **OpenWrt 25.12.2**.

Patch ini dibuat karena L850GL dapat berkomunikasi dengan removable eSIM lewat **MBIM Microsoft Low-Level UICC Access**, tetapi `lpac` MBIM standar gagal pada beberapa detail implementasi L850GL.

Hasil test pada OpenWrt `25.12.2 ipq40xx/generic arm_cortex-a7_neon-vfpv4`:

- `lpac chip info` berhasil membaca EID.
- `lpac profile list` berhasil membaca daftar profile.
- Contoh EID sukses: `89034011099300000025800001320291`.

## Isi repo

```text
lpac-l850gl-2.3.0/          Full source lpac 2.3.0 yang sudah dipatch
openwrt-package/            Makefile + patches untuk OpenWrt package feed
openwrt-package/patches/    Patch L850GL yang bisa dipasang ke package lpac OpenWrt
tools/l850gl-esim-manager.sh Menu CLI sederhana untuk manage removable eSIM
```

## Kenapa LPAC standar gagal di L850GL?

Dari USBPcap Windows dan test `mbimcli`, jalur yang benar bukan AT command. Windows memakai:

- MBIM service: `ms-uicc-low-level-access`
- UUID: `c2f6588e-f037-4bc9-8665-f4d44bd09367`
- ISD-R AID: `A0000005591010FFFFFFFF8900000100`
- APDU ES10x/SGP.22

Manual command yang sukses membaca EID:

```sh
mbimcli -d /dev/cdc-wdm0 --no-open=10 --no-close \
  --ms-set-uicc-open-channel='application-id=A0000005591010FFFFFFFF8900000100,selectp2arg=12,channel-group=1'

mbimcli -d /dev/cdc-wdm0 --no-open=10 --no-close \
  --ms-set-uicc-apdu='channel=1,secure-message=none,classbyte-type=extended,command=81E2910006BF3E035C015A00'
```

LPAC standar berbeda pada beberapa titik, sehingga perlu patch.

## Patch yang dipakai

### 1. Skip MBIM Device Slot Mapping

File: `openwrt-package/patches/100-lpac-mbim-skip-slot-mapping-env.patch`

LPAC standar memanggil MBIM **Device Slot Mapping** ketika init. L850GL menolak operasi ini dengan `OperationNotAllowed`, walaupun low-level UICC APDU sebenarnya bisa jalan.

Patch menambah environment variable:

```sh
LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1
```

Jika aktif, LPAC langsung lanjut ke open-channel/APDU tanpa slot mapping.

### 2. Pakai MBIM UICC class byte type `extended`

File: `openwrt-package/patches/110-lpac-mbim-use-extended-class-byte.patch`

Manual `mbimcli` yang sukses memakai:

```text
classbyte-type=extended
```

LPAC standar memakai `MBIM_UICC_CLASS_BYTE_TYPE_INTER_INDUSTRY`, yang di L850GL menyebabkan `SW 6E00` atau response tidak sesuai.

Patch mengubah transmit APDU menjadi:

```c
MBIM_UICC_CLASS_BYTE_TYPE_EXTENDED
```

### 3. Open channel dengan `selectp2arg=12` / `0x0C`

File: `openwrt-package/patches/120-lpac-mbim-open-channel-select-p2-0c.patch`

Manual `mbimcli` sukses membuka channel dengan:

```text
selectp2arg=12
```

Patch mengubah:

```c
mbim_message_ms_uicc_low_level_access_open_channel_set_new(aid_len, aid, 0, 1, &error)
```

menjadi:

```c
mbim_message_ms_uicc_low_level_access_open_channel_set_new(aid_len, aid, 12, 1, &error)
```

### 4. Tambahkan trailing `Le=00` ke APDU ES10x envelope

File: `openwrt-package/patches/130-lpac-mbim-append-le00-to-envelope.patch`

Manual command sukses:

```text
81 E2 91 00 06 BF 3E 03 5C 01 5A 00
```

LPAC standar mengirim tanpa byte terakhir `00`:

```text
81 E2 91 00 06 BF 3E 03 5C 01 5A
```

Di L850GL, tanpa `Le=00`, modem/eUICC dapat membalas `SW 9000` tetapi data kosong. Patch ini menambahkan `Le=00` untuk APDU `E2` case 4 ketika panjang APDU sama dengan `5 + Lc`.

## Cara pakai di router

Set konfigurasi LPAC:

```sh
uci set lpac.global.apdu_backend='mbim'
uci set lpac.global.custom_isd_r_aid='A0000005591010FFFFFFFF8900000100'
uci set lpac.global.apdu_debug='0'
uci set lpac.mbim.device='/dev/cdc-wdm0'
uci set lpac.mbim.proxy='0'
uci commit lpac
```

Buat environment L850GL permanen:

```sh
cat > /etc/profile.d/lpac-l850gl.sh <<'EOF2'
export LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1
export LPAC_APDU_MBIM_USE_PROXY=0
export LPAC_APDU_MBIM_DEVICE=/dev/cdc-wdm0
EOF2
chmod +x /etc/profile.d/lpac-l850gl.sh
. /etc/profile.d/lpac-l850gl.sh
```

Test:

```sh
lpac chip info
lpac profile list
```

Output rapi:

```sh
apk add jq
lpac chip info | jq
lpac profile list | jq
```

## Menu CLI L850GL

Source ini juga menyertakan script menu:

```sh
tools/l850gl-esim-manager.sh
```

Jika script sudah terinstall di router:

```sh
esim
# atau:
l850gl-esim-manager
```

Menu utama:

```text
1. INFO EID
2. Profile List (Switch/Del)
3. Download eSIM
4. Process Pending Notification
5. LPAC Version
6. Recovery SIM missing
0. Exit
```

Mode normal menampilkan output ringkas yang mudah dibaca. Untuk melihat output JSON asli LPAC dan stderr:

```sh
esim --debug
```

Script ini tetap memakai wrapper `/usr/bin/lpac`, bukan `/usr/lib/lpac` langsung. Jadi UCI berikut tetap dipakai otomatis:

```sh
uci set lpac.global.apdu_backend='mbim'
uci set lpac.mbim.device='/dev/cdc-wdm0'
uci set lpac.mbim.proxy='1'
uci set lpac.mbim.skip_slot_mapping='1'
uci commit lpac
```

Download profile memakai format LPAC 2.3.0:

```sh
lpac profile download -a 'LPA:1$rsp.truphone.com$MATCHING-ID'
lpac profile download -s rsp.truphone.com -m 'MATCHING-ID'
```

Jangan jalankan `lpac profile download LPA:1$...` tanpa `-a`, karena LPAC 2.3.0 membaca activation code QR lewat opsi `-a`.

Delete profile:

```sh
lpac profile delete <ICCID atau AID>
lpac notification process -a -r
```

Delete hanya menghapus profile dan membuat notification; notification sebaiknya diproses setelahnya.

## Enable / ganti profile eSIM

Lihat daftar profile ringkas:

```sh
lpac profile list | jq -r '.payload.data[] | "\(.profileState)  \(.iccid)  \(.profileNickname)"'
```

Enable profile berdasarkan ICCID:

```sh
lpac profile enable <ICCID> 0
```

Contoh:

```sh
lpac profile enable 8962112181019773866 0
```

Jika sukses tetapi modem tidak langsung attach jaringan, coba refresh flag `1`:

```sh
lpac profile enable <ICCID> 1
```

Bisa juga enable berdasarkan AID:

```sh
lpac profile enable a0000005591010ffffffff8900001100 0
```

Setelah enable, tunggu 30-60 detik. Jika modem tidak pindah jaringan, restart interface modem atau cabut-colok modem. Jangan menjalankan `/etc/init.d/network stop` jika SSH Anda lewat router tersebut.

## Cara build OpenWrt APK

Target yang sudah dites:

```text
OpenWrt 25.12.2
DISTRIB_TARGET=ipq40xx/generic
DISTRIB_ARCH=arm_cortex-a7_neon-vfpv4
SDK=openwrt-sdk-25.12.2-ipq40xx-generic_gcc-14.3.0_musl_eabi.Linux-x86_64
```

Langkah umum:

```sh
# di mesin build Linux x86_64
wget https://downloads.openwrt.org/releases/25.12.2/targets/ipq40xx/generic/openwrt-sdk-25.12.2-ipq40xx-generic_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-25.12.2-ipq40xx-generic_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst
cd openwrt-sdk-25.12.2-ipq40xx-generic_gcc-14.3.0_musl_eabi.Linux-x86_64
```

Copy package files:

```sh
cp /path/to/openwrt-package/Makefile feeds/packages/utils/lpac/Makefile
mkdir -p feeds/packages/utils/lpac/patches
cp /path/to/openwrt-package/patches/*.patch feeds/packages/utils/lpac/patches/
```

Pastikan config LPAC MBIM aktif:

```sh
make menuconfig
# Utilities -> lpac
# Enable LPAC_WITH_MBIM
```

Build:

```sh
make package/lpac/clean V=s
make package/lpac/compile V=s -j1
```

Output APK biasanya ada di:

```text
bin/packages/arm_cortex-a7_neon-vfpv4/packages/lpac-2.3.0-r1.apk
```

Install di router:

```sh
apk add --allow-untrusted --upgrade /tmp/lpac-2.3.0-r1.apk
```

## Catatan keamanan

- Jangan bagikan EID/ICCID publik jika tidak perlu.
- Hati-hati dengan `profile delete`, karena menghapus profile dari eUICC.
- Untuk ganti profile, gunakan `profile enable`, bukan `delete`.

## Lisensi

Source utama mengikuti lisensi upstream LPAC. Lihat `lpac-l850gl-2.3.0/LICENSES/`.
Patch L850GL di folder `openwrt-package/patches/` dibuat untuk kompatibilitas L850GL/OpenWrt.
