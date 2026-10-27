#!/bin/bash
# Runs the sdspin wrapper embedded in usb-sleep.plg against stubbed
# sdspin.orig and smartctl, and checks every exit code emhttpd relies on.
set -u
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

sed -n '/<!\[CDATA\[/,/\]\]>/p' usb-sleep.plg | sed '1d;$d' > "$T/sdspin"
chmod +x "$T/sdspin"
printf '#!/bin/bash\nexit "$ORIG_RC"\n' > "$T/orig"
printf '#!/bin/bash\necho "$SMART_OUT"\n' > "$T/smartctl"
chmod +x "$T/orig" "$T/smartctl"
export USB_SLEEP_ORIG=$T/orig USB_SLEEP_SMARTCTL=$T/smartctl

ACTIVE='Power mode is:    ACTIVE or IDLE'
IDLE='Power mode was:   IDLE_A'
STANDBY='Device is in STANDBY mode, exit(2)'
fail=0
check() { # orig_rc smart_out command expected_rc
  ORIG_RC=$1 SMART_OUT=$2 "$T/sdspin" sda "$3"
  local rc=$?
  [[ $rc == "$4" ]] || { echo "FAIL: orig=$1 cmd=$3 smart='$2' got $rc want $4"; fail=1; }
}

# sdspin.orig result is passed through unless it is 1.
check 0 "" down 0
check 2 "" status 2
check 25 "" status 25
# Bridge reported failure: smartctl decides.
check 1 "$STANDBY" down 0
check 1 "$ACTIVE" down 1
check 1 "$ACTIVE" up 0
check 1 "$STANDBY" up 1
check 1 "$ACTIVE" status 0
check 1 "$IDLE" status 0
check 1 "$STANDBY" status 2
check 1 "Smartctl open device: /dev/sda failed" status 1

[[ $fail == 0 ]] && echo "all passed"
exit $fail
