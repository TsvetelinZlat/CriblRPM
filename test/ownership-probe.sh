#!/bin/bash
# Determines the MINIMUM set of directories that must be owned by the service
# account for Cribl to run, so everything else can stay root-owned.
#
#   docker exec cribl-probe bash /test/ownership-probe.sh
set -uo pipefail
RPM=$(ls -1 /rpms/*.rpm | head -1)
U=ta2crib

groupadd -r domainusers 2>/dev/null
useradd -r -g domainusers -d /opt/cribl -s /sbin/nologin "$U" 2>/dev/null
dnf install -y "$RPM" >/tmp/i.log 2>&1 || { echo "install failed"; tail -5 /tmp/i.log; exit 1; }

mkdir -p /etc/systemd/system/cribl.service.d
printf '[Service]\nUser=%s\nGroup=\n' "$U" > /etc/systemd/system/cribl.service.d/override.conf
systemctl daemon-reload

attempt() {
    local label="$1"; shift
    systemctl stop cribl >/dev/null 2>&1
    rm -rf /opt/cribl/local/* /opt/cribl/log/* /opt/cribl/pid/* 2>/dev/null
    # Reset everything to root, then hand over only the named dirs.
    chown -R root:root /opt/cribl
    chmod -R u=rwX,go=rX /opt/cribl
    for d in "$@"; do chown -R "$U": "/opt/cribl/$d"; done

    systemctl start cribl >/dev/null 2>&1
    for i in $(seq 1 40); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
    if [ "$(systemctl is-active cribl)" = active ] && \
       [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:9000/ 2>/dev/null)" = 200 ]; then
        printf '  \033[32mWORKS\033[0m  %s\n' "$label"
        return 0
    else
        printf '  \033[31mFAILS\033[0m  %s\n' "$label"
        journalctl -u cribl --no-pager -n 6 2>/dev/null | grep -iE "permission|denied|EACCES|error" | head -3 | sed 's/^/           /'
        return 1
    fi
}

echo "=== Probing minimum writable set (service runs as $U) ==="
attempt "root owns EVERYTHING, nothing handed to $U"
attempt "$U owns: local log pid groups"                 local log pid groups
attempt "$U owns: local log pid groups state data"      local log pid groups state data

echo
echo "=== Final ownership of the working configuration ==="
for d in bin data default state thirdparty local log pid groups; do
    printf '  %-12s %s\n' "$d" "$(stat -c '%U:%G %a' /opt/cribl/$d)"
done
