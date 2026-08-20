#!/usr/bin/env bash
# Build the cribl RPM. Run inside a Linux environment that has rpmbuild.
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/build.sh
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
TOP=${RPM_TOP:-/var/tmp/cribl-rpmbuild}

command -v rpmbuild >/dev/null || {
    echo "rpmbuild not found. Debian/Ubuntu: apt-get install -y rpm" >&2
    exit 1
}

# Build on the native filesystem: unpacking ~1 GB onto a 9p/DrvFs mount is
# an order of magnitude slower.
rm -rf "$TOP"
mkdir -p "$TOP"/{SPECS,SOURCES,BUILD,BUILDROOT,RPMS,SRPMS}
cp "$SRC"/SPECS/cribl.spec "$TOP/SPECS/"
cp "$SRC"/SOURCES/* "$TOP/SOURCES/"

# xz -2 rather than the default -9: the payload is already gzip-compressed, so
# the extra hours of CPU buy almost nothing. xz keeps rpm >= 4.8 compatibility
# (zstd would exclude RHEL 7).
rpmbuild \
    --define "_topdir $TOP" \
    --define "_binary_payload w2.xzdio" \
    -bb "$TOP/SPECS/cribl.spec"

mkdir -p "$SRC/RPMS"
find "$TOP/RPMS" -name '*.rpm' -exec cp -v {} "$SRC/RPMS/" \;
echo
echo "Built:"
ls -lh "$SRC/RPMS"/*.rpm

# Smoke test: unpack the package into a throwaway root and confirm the payload
# survived the repack intact (scriptlets skipped -- this is not a RHEL host).
TESTROOT=$(mktemp -d)
RPMFILE=$(ls -1 "$TOP"/RPMS/*/*.rpm | head -1)
rpm --root "$TESTROOT" --dbpath /tmp/rpmdb -i --nodeps --noscripts --ignorearch "$RPMFILE"
test -x "$TESTROOT/opt/cribl/bin/cribl"        || { echo "FAIL: cribl binary not executable"; exit 1; }
test -L "$TESTROOT/usr/bin/cribl"              || { echo "FAIL: /usr/bin/cribl symlink missing"; exit 1; }
test -f "$TESTROOT/etc/sysconfig/cribl"        || { echo "FAIL: sysconfig missing"; exit 1; }
test -f "$TESTROOT/usr/lib/systemd/system/cribl.service" || { echo "FAIL: unit missing"; exit 1; }
head -c4 "$TESTROOT/opt/cribl/bin/cribl" | grep -q ELF || { echo "FAIL: cribl binary is not an ELF image"; exit 1; }
systemd-analyze verify "$TESTROOT/usr/lib/systemd/system/cribl.service" 2>&1 | grep -v 'Unit .* not found' || true
echo "SMOKE TEST OK ($(du -sh "$TESTROOT" | cut -f1) unpacked)"
rm -rf "$TESTROOT" /tmp/rpmdb
