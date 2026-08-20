#!/usr/bin/env bash
# Inspect a built cribl RPM without installing it.
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/verify.sh
set -euo pipefail
RPM=${1:-$(ls -1 "$(cd "$(dirname "$0")" && pwd)"/RPMS/*.rpm | head -1)}
echo "== $RPM"
rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}  size=%{SIZE}\n' "$RPM"
echo; echo "== Requires";  rpm -qpR "$RPM"
echo; echo "== Provides";  rpm -qp --provides "$RPM"
echo; echo "== Config";    rpm -qpc "$RPM"
echo; echo "== File count"; rpm -qpl "$RPM" | wc -l
echo; echo "== Key files"
rpm -qp --qf '[%{FILEMODES:perms} %{FILEUSERNAME}:%{FILEGROUPNAME} %{FILENAMES}\n]' "$RPM" \
  | grep -E '(/usr/bin/cribl|/opt/cribl$|/opt/cribl/bin/cribl$|/opt/cribl/(local|log|pid|groups)$|cribl.service|sysconfig/cribl)'
echo; echo "== Scriptlets"; rpm -qp --scripts "$RPM"
