#!/usr/bin/env bash
# Build the source RPM: one file containing the spec plus every input needed
# to rebuild the binary package on any RHEL-family host.
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/srpm.sh
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
TOP=${RPM_TOP:-/var/tmp/cribl-srpm}

rm -rf "$TOP"
mkdir -p "$TOP"/{SPECS,SOURCES,SRPMS}
cp "$SRC"/SPECS/cribl.spec "$TOP/SPECS/"
cp "$SRC"/SOURCES/* "$TOP/SOURCES/"

rpmbuild --define "_topdir $TOP" -bs "$TOP/SPECS/cribl.spec"

mkdir -p "$SRC/SRPMS"
cp -v "$TOP"/SRPMS/*.rpm "$SRC/SRPMS/"
ls -lh "$SRC"/SRPMS/*.rpm
