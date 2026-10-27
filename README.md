# unraid-usb-sleep

An Unraid plugin that lets drives behind USB-SATA bridges spin down.

## The problem

Unraid spins drives down through `/usr/local/sbin/sdspin`, which calls `hdparm -y` and `hdparm -C`. Many USB-SATA bridges (for example the WD Elements Desktop, USB ID `1058:25a3`) carry out these commands correctly but answer with SCSI sense data `00/1d`, "ATA pass-through information available". `hdparm` then prints:

```
SG_IO: bad/missing sense data, sb[]:  f0 00 01 00 50 00 00 0a 00 00 00 00 00 1d ...
```

`sdspin` treats that message as a failure, so the syslog shows:

```
emhttpd: sdspin /dev/sda down: 1
```

After that failure, emhttpd stops trying to spin the drive down. It also keeps polling SMART attributes every `poll_attributes` seconds, because it believes the drive is still spinning. Those polls wake the drive if anything else puts it to sleep.

## What the plugin does

The plugin keeps Unraid's script as `/usr/local/sbin/sdspin.orig` and installs a small wrapper in its place. The wrapper runs the original first. Only when the original reports an error (exit code 1) does it check the actual power state with `smartctl -n standby`, which reads it correctly through these bridges without waking the drive. Exit codes stay the same as `sdspin`'s, so emhttpd and Unassigned Devices behave as they do for internal SATA drives.

Drives that already work are not affected: any result other than 1 from the original script is passed through unchanged.

## Installation

In the Unraid web UI, open **Plugins → Install Plugin** and paste:

```
https://raw.githubusercontent.com/andrebrait/unraid-usb-sleep/main/usb-sleep.plg
```

If emhttpd has already logged `sdspin /dev/sdX down: 1` for a drive, it will not retry until it detects the drive again. Reboot, or unmount and re-plug the drive.

Removing the plugin restores Unraid's original `sdspin`.

## Checking that it works

```
sdspin sdX down; echo $?     # 0
sdspin sdX status; echo $?   # 2 while spun down
```

## Other things that keep drives awake

The plugin only fixes the spin-down command. Periodic access will still wake the drive. One common example is the ZFS Master plugin's refresh interval, which writes to the pool history of every ZFS pool every 30 seconds while a web UI tab is open.

## Testing

`./test.sh` runs the wrapper embedded in `usb-sleep.plg` against stubbed `sdspin.orig` and `smartctl` and checks each exit code.
