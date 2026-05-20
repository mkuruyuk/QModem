# L850-GL Patch Summary

Final patches proven working on Fibocom L850-GL + removable eSIM:

1. `100-lpac-mbim-skip-slot-mapping-env.patch`
   - Adds `LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1` environment variable
   - Skips MBIM Device Slot Mapping which L850-GL rejects with `OperationNotAllowed`

2. `110-lpac-mbim-use-extended-class-byte.patch`
   - Changes `MBIM_UICC_CLASS_BYTE_TYPE_INTER_INDUSTRY` to `MBIM_UICC_CLASS_BYTE_TYPE_EXTENDED`
   - Matches successful manual `mbimcli classbyte-type=extended`

3. `120-lpac-mbim-open-channel-select-p2-0c.patch`
   - Changes open-channel `selectp2arg` from `0` to `12` (`0x0C`)
   - Matches successful manual `mbimcli selectp2arg=12`

4. `130-lpac-mbim-append-le00-to-envelope.patch`
   - Appends trailing `Le=00` to APDU envelope `E2`
   - Makes LPAC request match the successful manual APDU: `81E2910006BF3E035C015A00`
