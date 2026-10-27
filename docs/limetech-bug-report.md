# Bug report for Limetech: sdspin and USB-SATA bridges

Draft of the report that asks Limetech to fix `sdspin` itself, which would make this plugin
unnecessary.

## How to file it

1. Sign in at <https://product.unraid.net/b/unraid-os-bugs> (Unraid's bug tracker; the forum bug
   sections moved there) and choose **Create New Bug**.
2. Title: the line under [Title](#title).
3. Body: everything under [Body](#body).
4. Custom field "Unraid version": `7.3.3`.
5. Attach the diagnostics zip: **Tools → Diagnostics → Download** (anonymized by default).

The report was written on Unraid 7.3.3 (kernel 6.18.54-Unraid), with this plugin installed. With the
plugin, Unraid's original script is `/usr/local/sbin/sdspin.orig`. Before filing on a newer release,
check that `md5sum /usr/local/sbin/sdspin.orig` still prints `23dd1173bb2996d629da2f2c9f2ff3e8`;
if it does not, Limetech has changed `sdspin` and the patch needs a fresh look.

## Title

```
[7.3.3] USB drives behind SAT bridges never spin down: sdspin reports fixed-format sense 00/1D as an error
```

## Body

### Description

Drives behind many USB-SATA bridges never get marked as spun down. Every spin-down attempt logs
`emhttpd: sdspin /dev/sdX down: 1`, although the drive does go into standby.

The bridge answers ATA pass-through commands (`hdparm -y`, `-C`, `-S`) with fixed-format sense data:
RECOVERED ERROR with ASC/ASCQ 00/1D, "ATA pass-through information available". SAT allows this. The
ATA registers are in the sense data, and the command completed. hdparm 9.65 decodes only
descriptor-format sense, so it prints `SG_IO: bad/missing sense data` and exits 0. `sdspin` turns
that message into exit code 1, for `down` and for `status` alike.

Because the spin-down "failed", emhttpd keeps the disk marked as spun up (`spundown="0"` in
`/var/local/emhttp/devs.ini`). It also keeps polling SMART attributes every `poll_attributes`
seconds with `smartctl -A`, which has no `-n standby`. That wakes the drive whenever it was put into
standby by other means.

### Environment

- Unraid 7.3.3 (kernel 6.18.54-Unraid), hdparm v9.65, smartctl 7.5, stock `/usr/local/sbin/sdspin`
  (MD5 `23dd1173bb2996d629da2f2c9f2ff3e8`)
- WD Elements Desktop 12 TB, USB ID `1058:25a3` (WDBWLG), used as an Unassigned Device (ZFS pool)
- `spindownDelay="30"`, `poll_attributes="30"`

### Steps to reproduce

1. Attach such a drive and let the spin-down delay expire, or spin it down from the GUI.
2. The syslog shows, each time:

   ```
   emhttpd: spinning down /dev/sda
   emhttpd: sdspin /dev/sda down: 1
   ```

3. Running the same commands by hand shows that the drive is in standby while `sdspin` reports an
   error:

   ```
   # hdparm -y /dev/sda; echo "rc=$?"
   SG_IO: bad/missing sense data, sb[]:  f0 00 01 00 50 00 00 0a 00 00 00 00 00 1d 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00

   /dev/sda:
    issuing standby command
   rc=0
   # sdspin sda down; echo $?
   1
   # smartctl -n standby -i /dev/sda
   Device is in STANDBY mode, exit(2)
   # hdparm -C /dev/sda
   SG_IO: bad/missing sense data, sb[]:  f0 00 01 00 50 00 00 0a 00 00 00 00 00 1d 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00

   /dev/sda:
    drive state is:  unknown
   # sdspin sda status; echo $?
   1
   ```

**Expected:** `sdspin sda down` returns 0, and `sdspin sda status` returns 2 while the drive is in
standby.

**Actual:** both return 1, and Unraid never marks the drive as spun down.

### Cause

The sense data is SAT fixed format (response code 70h with the VALID bit, shown as `f0`). For ATA
pass-through, SAT puts the ATA registers in its INFORMATION field:

| Byte | Value | Meaning |
|---|---|---|
| 0 | `f0` | fixed format, current error, VALID |
| 2 | `01` | sense key RECOVERED ERROR |
| 3 | `00` | ATA ERROR |
| 4 | `50` | ATA STATUS: DRDY and DSC set, ERR clear |
| 6 | `00` | ATA COUNT(7:0): `00h` after CHECK POWER MODE means standby |
| 12, 13 | `00 1d` | ASC/ASCQ: ATA PASS-THROUGH INFORMATION AVAILABLE |

hdparm 9.65 only parses descriptor-format sense (`72h` with an ATA Return descriptor). For anything
else it dumps the bytes, prints `drive state is: unknown` for `-C`, and still exits 0. smartmontools
decodes the fixed format, which is why `smartctl -n standby` reports the correct state through the
same bridge.

### Proposed fix

When hdparm flags bad/missing sense, `sdspin` decodes fixed-format sense itself. RECOVERED ERROR with
00/1D and the ATA ERR bit clear counts as success. For CHECK POWER MODE, COUNT `00h` maps to standby
(exit 2), and any other value to spun up (exit 0). All other sense data still returns 1, and output
without the hdparm warning (internal SATA drives) is handled exactly as before.

```diff
--- a/usr/local/sbin/sdspin
+++ b/usr/local/sbin/sdspin
@@ -18,7 +18,19 @@
 hdparm () {
   OUTPUT=$(/usr/sbin/hdparm $1 $RDEVNAME 2>&1)
   RET=$?
-  [[ $RET == 0 && ${OUTPUT,,} =~ "bad/missing sense" ]] && RET=1
+  if [[ $RET == 0 && ${OUTPUT,,} =~ "bad/missing sense" ]]; then
+    RET=1
+    # USB-SATA bridges may answer ATA pass-through with fixed-format sense data (70h/F0h):
+    # RECOVERED ERROR, ASC/ASCQ 00/1D "ATA pass-through information available", the ATA STATUS
+    # in byte 4 and COUNT(7:0) in byte 6 (SAT). hdparm only decodes descriptor-format sense,
+    # so it reports bad/missing sense although the command completed.
+    SB=($(sed -n 's/.*sb\[\]: *//p' <<< "$OUTPUT"))
+    if [[ ${SB[0]} =~ ^(70|f0)$ && ${SB[12]}${SB[13]} == 001d ]] &&
+       (( (0x${SB[2]} & 0x0f) == 1 && (0x${SB[4]} & 0x01) == 0 )); then
+      RET=0
+      [[ $1 == -C && ${SB[6]} == 00 ]] && OUTPUT="drive state is:  standby"   # CHECK POWER MODE: COUNT 00h
+    fi
+  fi
 }
 
 if [[ "$2" == "up" ]]; then
```

### Testing

On the system above, with the drive in standby:

| Command | Stock sdspin | Patched sdspin |
|---|---|---|
| `sdspin sda status` | 1 | 2 |
| `sdspin sda down` | 1 | 0 |
| `sdspin sdb status`, `sdspin sdc status` (internal SATA, spinning) | 0 | 0 |

`smartctl -n standby` confirmed that the drive stayed in standby throughout.

A stub test that feeds recorded hdparm output to the patched script also passes all 10 cases:

- bridge reporting standby, active (`ffh`) and idle (`80h`);
- bridge `down` and `up`;
- bridge with the ATA ERR bit set, which still returns 1;
- descriptor-format ILLEGAL REQUEST, which still returns 1;
- internal SATA drives in standby, active and `down`, all unchanged.

The `up` path (`hdparm -S0`) was tested only with recorded output, because running it wakes the
drive.

### Workaround

The [usb-sleep](https://github.com/andrebrait/unraid-usb-sleep) plugin wraps `sdspin`. When the stock
script returns 1, the wrapper reads the power state with `smartctl -n standby`. With it installed,
the drive above spins down normally (`emhttpd: spinning down /dev/sda`, no `down: 1`).

### Related reports

- [SATA disks are never spun down again after sdspin up hits hdparm's 15-second timeout on slow-spin-up drives](https://product.unraid.net/p/sata-disks-are-never-spun-down-again-after-sdspin-up-hits-hdparm-s-15-second-timeout-on-slow-spin-up-drives):
  another way an `sdspin` error leaves a disk awake.
- [Unraid 7.3.3: emhttpd SMART polling appears to wake sleeping HDDs](https://product.unraid.net/p/unraid-7-3-3-emhttpd-smart-polling-appears-to-wake-sleeping-hdds):
  the `smartctl -A` poll without `-n standby`.
