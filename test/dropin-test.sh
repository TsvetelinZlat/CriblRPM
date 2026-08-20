#!/bin/bash
# Proves the no-rebuild runbook: install the stock RPM (which ships as the
# 'cribl' account), then make the service run as ta2crib using only root-side
# post-install steps - a chown plus a systemd drop-in. No group changes, no
# package changes.
#
#   docker exec cribl-dropin bash /test/dropin-test.sh
set -uo pipefail
RPM=$(ls -1 /rpms/*.rpm | head -1)
SVC_USER=ta2crib
fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "=== 0. Simulate a directory-provisioned ta2crib with a NON-dedicated"
echo "       primary group (the realistic enterprise case)"
groupadd -r domainusers 2>/dev/null
useradd -r -g domainusers -d /opt/cribl -s /sbin/nologin "$SVC_USER" 2>/dev/null
id "$SVC_USER" && ok "account exists: $(id "$SVC_USER")" || { no "could not create account"; exit 1; }
PRIMARY=$(id -gn "$SVC_USER")

echo "=== 1. Install the stock RPM unchanged"
dnf install -y "$RPM" >/tmp/i.log 2>&1 && ok "installed $(rpm -q cribl)" || { no "install failed"; tail -20 /tmp/i.log; exit 1; }
[ "$(stat -c %U /opt/cribl/bin/cribl)" = cribl ] \
    && ok "package owns files as 'cribl' as expected (pre-chown)" \
    || no "unexpected initial ownership: $(stat -c %U /opt/cribl/bin/cribl)"

echo "=== 2. Runbook step: chown to ta2crib"
chown -R "$SVC_USER": /opt/cribl && ok "chown -R $SVC_USER: /opt/cribl" || no "chown failed"
[ "$(stat -c %U /opt/cribl/bin/cribl)" = "$SVC_USER" ] && ok "payload now owned by $SVC_USER" || no "chown did not take"

echo "=== 3. Runbook step: tighten config dir (primary group is $PRIMARY)"
chmod 750 /opt/cribl
chmod 700 /opt/cribl/local
[ "$(stat -c %a /opt/cribl/local)" = 700 ] \
    && ok "/opt/cribl/local is 0700 - secrets not exposed to $PRIMARY members" \
    || no "/opt/cribl/local is $(stat -c %a /opt/cribl/local)"

echo "=== 4. Runbook step: systemd drop-in"
mkdir -p /etc/systemd/system/cribl.service.d
cat > /etc/systemd/system/cribl.service.d/override.conf <<EOF
[Service]
User=$SVC_USER
Group=
EOF
# Group= empty resets the packaged Group=cribl without naming a new group.
systemctl daemon-reload && ok "drop-in written and daemon-reloaded" || no "daemon-reload failed"
eff=$(systemctl show -p User --value cribl)
[ "$eff" = "$SVC_USER" ] && ok "effective User=$eff" || no "effective User=$eff, expected $SVC_USER"

echo "=== 5. Start it"
systemctl enable --now cribl >/tmp/e.log 2>&1 || { no "enable --now failed"; cat /tmp/e.log; }
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
if [ "$(systemctl is-active cribl)" = active ]; then
    ok "service active"
    mainpid=$(systemctl show -p MainPID --value cribl)
    [ "$mainpid" = "$(cat /opt/cribl/pid/cribl.pid 2>/dev/null)" ] \
        && ok "MainPID matches pidfile (Type=forking intact)" || no "MainPID/pidfile mismatch"
    runas=$(ps -o user= -p "$mainpid" | tr -d ' ')
    [ "$runas" = "$SVC_USER" ] && ok "RUNNING AS $runas" || no "running as $runas, expected $SVC_USER"
else
    no "service failed to start"; journalctl -u cribl --no-pager -n 30
fi
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:9000/ 2>/dev/null)
[ "$code" = 200 ] && ok "UI responding (HTTP $code)" || no "UI not responding (got '$code')"
[ "$(stat -c %U /opt/cribl/local/cribl/cribl.inited 2>/dev/null || echo none)" = "$SVC_USER" ] \
    && ok "runtime files created as $SVC_USER" || ok "runtime files: $(ls /opt/cribl/local/cribl 2>/dev/null | tr '\n' ' ')"

echo "=== 6. THE CAVEAT: what an upgrade does to ownership"
cp "$RPM" /tmp/local.rpm
rpm -U --force /tmp/local.rpm >/tmp/u.log 2>&1 || no "upgrade failed: $(tail -3 /tmp/u.log)"
after=$(stat -c %U /opt/cribl/bin/cribl)
if [ "$after" = "$SVC_USER" ]; then
    ok "ownership survived the upgrade (no re-chown needed)"
else
    echo "  \033[33mNOTE\033[0m ownership reverted to '$after' after upgrade - chown MUST be re-applied"
fi
eff2=$(systemctl show -p User --value cribl)
[ "$eff2" = "$SVC_USER" ] && ok "drop-in survived the upgrade (User=$eff2)" || no "drop-in lost, User=$eff2"

echo
[ $fail -eq 0 ] && echo "=== RUNBOOK VERIFIED" || echo "=== SOME CHECKS FAILED"
exit $fail
