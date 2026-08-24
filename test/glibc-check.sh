#!/usr/bin/env bash
# Determine the minimum glibc (and therefore minimum RHEL) the Cribl payload
# needs, by reading the versioned symbol requirements out of its ELF binaries.
#   wsl -d Ubuntu -u root -- /mnt/c/work/cribl-rpm/test/glibc-check.sh
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
RPM=${1:-$SRC/RPMS/cribl-4.19.1-2.x86_64.rpm}
WORK=$(mktemp -d)
cp "$RPM" "$WORK/c.rpm"          # local disk: reading rpms off /mnt/c is unreliable
cd "$WORK" && rpm2cpio c.rpm | cpio -idm --quiet 2>/dev/null

echo "=== ELF objects in the payload ==="
mapfile -t elves < <(find "$WORK/opt/cribl" -type f \( -name 'cribl' -o -name '*.so*' -o -name '*.node' \) 2>/dev/null)
echo "${#elves[@]} binaries/shared objects"

echo
echo "=== highest GLIBC_* symbol version required, per object ==="
for f in "${elves[@]}"; do
    v=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -uV | tail -1)
    [ -n "$v" ] && printf '%-10s %s\n' "$v" "${f#$WORK/opt/cribl/}"
done | sort -Vr | head -12

echo
echo "=== overall maximum ==="
# Guard: an empty MAX would make the comparisons below silently pass.
MAX=$(for f in "${elves[@]}"; do objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//'; done | sort -uV | tail -1)
[ -n "$MAX" ] || { echo "ERROR: no versioned GLIBC symbols found - extraction failed, not a compatibility result"; exit 1; }
echo "needs glibc >= $MAX"
echo
echo "  RHEL 8 ships glibc 2.28  ->  $(printf '%s\n2.28\n' "$MAX" | sort -V | tail -1 | grep -qx 2.28 && echo COMPATIBLE || echo "TOO OLD (needs $MAX)")"
echo "  RHEL 9 ships glibc 2.34  ->  $(printf '%s\n2.34\n' "$MAX" | sort -V | tail -1 | grep -qx 2.34 && echo COMPATIBLE || echo "TOO OLD (needs $MAX)")"

echo
echo "=== other versioned deps (libstdc++ / GCC) ==="
for f in "${elves[@]}"; do objdump -T "$f" 2>/dev/null | grep -oE '(GLIBCXX|CXXABI|GCC)_[0-9.]+'; done | sort -uV | tail -6

rm -rf "$WORK"
