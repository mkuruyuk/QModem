# Ringkasan patch L850GL

Patch final yang terbukti berhasil pada Fibocom L850GL + removable eSIM:

1. `100-lpac-mbim-skip-slot-mapping-env.patch`
   - Menambah `LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1`
   - Menghindari MBIM Device Slot Mapping yang ditolak L850GL dengan `OperationNotAllowed`

2. `110-lpac-mbim-use-extended-class-byte.patch`
   - Mengubah `MBIM_UICC_CLASS_BYTE_TYPE_INTER_INDUSTRY` menjadi `MBIM_UICC_CLASS_BYTE_TYPE_EXTENDED`
   - Sesuai manual `mbimcli classbyte-type=extended`

3. `120-lpac-mbim-open-channel-select-p2-0c.patch`
   - Mengubah open-channel `selectp2arg` dari `0` menjadi `12` (`0x0C`)
   - Sesuai manual `mbimcli selectp2arg=12`

4. `130-lpac-mbim-append-le00-to-envelope.patch`
   - Menambahkan trailing `Le=00` ke APDU envelope `E2`
   - Membuat request LPAC sama dengan manual APDU sukses: `81E2910006BF3E035C015A00`
