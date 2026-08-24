#!/usr/bin/env bash
# Build the cribl RPM, once per target distribution.
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/build.sh
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/build.sh .el9      # just one
#
# The build host is Debian/Ubuntu, which has no %dist macro, so it must be
# defined explicitly - otherwise Release comes out as a bare "2" with no
# distribution tag.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
TOP=${RPM_TOP:-/var/tmp/cribl-rpmbuild}
DISTS=("$@")
[ ${#DISTS[@]} -eq 0 ] && DISTS=(.el8 .el9)

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

mkdir -p "$SRC/RPMS" "$SRC/SRPMS"

for dist in "${DISTS[@]}"; do
    echo
    echo "############ building for dist=${dist} ############"
    # xz -2 rather than the default -9: the payload is already gzip-compressed,
    # so the extra CPU buys almost nothing. xz keeps rpm >= 4.8 compatibility
    # (zstd would exclude RHEL 7).
    rpmbuild \
        --define "_topdir $TOP" \
        --define "dist ${dist}" \
        --define "_binary_payload w2.xzdio" \
        -bb "$TOP/SPECS/cribl.spec"

    # Source RPM carrying the same dist tag, so the pair stays matched.
    rpmbuild \
        --define "_topdir $TOP" \
        --define "dist ${dist}" \
        -bs "$TOP/SPECS/cribl.spec"
done

find "$TOP/RPMS"  -name '*.rpm' -exec cp -v {} "$SRC/RPMS/"  \;
find "$TOP/SRPMS" -name '*.rpm' -exec cp -v {} "$SRC/SRPMS/" \;

echo
echo "Built:"
ls -lh "$SRC"/RPMS/*.rpm "$SRC"/SRPMS/*.rpm

# Smoke test each: unpack into a throwaway root and confirm the payload
# survived the repack, and that Release carries the dist tag.
for dist in "${DISTS[@]}"; do
    RPMFILE=$(ls -1 "$TOP"/RPMS/*/cribl-*-2${dist}.x86_64.rpm 2>/dev/null | head -1)
    [ -n "$RPMFILE" ] || { echo "FAIL: no rpm produced for ${dist}"; exit 1; }
    rel=$(rpm -qp --qf '%{RELEASE}' "$RPMFILE" 2>/dev/null)
    [ "$rel" = "2${dist}" ] || { echo "FAIL: Release is '$rel', expected '2${dist}'"; exit 1; }

    TESTROOT=$(mktemp -d)
    rpm --root "$TESTROOT" --dbpath /tmp/rpmdb-${dist} -i --nodeps --noscripts --ignorearch "$RPMFILE"
    test -x "$TESTROOT/opt/cribl/bin/cribl" || { echo "FAIL(${dist}): cribl not executable"; exit 1; }
    test -L "$TESTROOT/usr/bin/cribl"       || { echo "FAIL(${dist}): symlink missing"; exit 1; }
    grep -qx "User=ta2crib" "$TESTROOT/usr/lib/systemd/system/cribl.service" \
        || { echo "FAIL(${dist}): unit User= wrong"; exit 1; }
    head -c4 "$TESTROOT/opt/cribl/bin/cribl" | grep -q ELF \
        || { echo "FAIL(${dist}): payload is not an ELF image"; exit 1; }
    echo "SMOKE TEST OK  Release=${rel}  ($(du -sh "$TESTROOT" | cut -f1) unpacked)"
    rm -rf "$TESTROOT" /tmp/rpmdb-${dist}
done
