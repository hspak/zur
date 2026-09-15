#!/bin/bash
source /usr/share/makepkg/util/config.sh
load_makepkg_config "$TEST_MAKEPKG_CONF"
printf '%s\n' "$PKGDEST" "$SRCDEST" "$SRCPKGDEST" "$BUILDDIR" "$LOGDEST" "$PKGEXT" > "$TEST_REPORT"
if [[ $1 == --packagelist ]]; then cat "$TEST_REPORT"; fi
