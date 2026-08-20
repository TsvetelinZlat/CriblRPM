#!/bin/bash
# Validates cribl-4.19.1-2: the package owns CRIBL_HOME as ta2crib:root,
# creates no groups, refuses to install without the account, and - the whole
# point of the rebuild - survives an upgrade with NO chown needed afterwards.
#
#   docker exec cribl-ta2crib bash /test/ta2crib-test.sh
set -uo pipefail
RPM=$(ls -1 /rpms/cribl-4.19.1-2*.rpm 2>/dev/null | head -1)
[ -n "$RPM" ] || { echo "cribl-4.19.1-2 rpm not found in /rpms"; exit 1; }
U=ta2crib
fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "=== 1. NEGATIVE: refuses to install without the service account"
out=$(rpm -i "$RPM" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "install refused (rc=$rc)" || no "installed without the account - %pre guard broken"
echo "$out" | grep -q "does not exist on this host" && ok "error names the missing account" \
    || { no "unclear error"; echo "$out" | head -4; }
rpm -q cribl >/dev/null 2>&1 && no "package registered despite failed %pre" || ok "nothing left installed"

echo "=== 2. Provision ta2crib the way the RHEL admin would"
# Deliberately a NON-dedicated primary group, mirroring a directory account.
groupadd -r domainusers 2>/dev/null
useradd -r -g domainusers -d /opt/cribl -s /sbin/nologin "$U" 2>/dev/null
ok "account: $(id "$U")"
before_groups=$(getent group | wc -l)

echo "=== 3. Install"
dnf install -y "$RPM" >/tmp/i.log 2>&1 && ok "installed $(rpm -q cribl)" || { no "install failed"; tail -20 /tmp/i.log; exit 1; }
[ "$(getent group | wc -l)" -eq "$before_groups" ] && ok "no groups created or modified" \
    || no "group count changed: $before_groups -> $(getent group | wc -l)"
[ "$(id -gn "$U")" = domainusers ] && ok "$U primary group untouched (domainusers)" || no "primary group changed"
getent passwd cribl >/dev/null && no "a stray 'cribl' account was created" || ok "no stray 'cribl' account"

echo "=== 4. Ownership is $U:root throughout"
for p in bin/cribl bin data default state thirdparty local log pid groups; do
    o=$(stat -c %U:%G "/opt/cribl/$p")
    [ "$o" = "$U:root" ] && ok "/opt/cribl/$p -> $o" || no "/opt/cribl/$p -> $o (expected $U:root)"
done
[ "$(stat -c %a /opt/cribl/local)" = 750 ] && ok "local/ is 0750 (auth secrets protected)" \
    || no "local/ is $(stat -c %a /opt/cribl/local)"

echo "=== 5. Unit targets $U and names no group"
grep -qx "User=$U" /usr/lib/systemd/system/cribl.service && ok "unit User=$U" || no "unit User= wrong"
grep -q '^Group=' /usr/lib/systemd/system/cribl.service && no "unit still names a Group=" || ok "unit omits Group= as intended"
grep -q '@CRIBL_' /usr/lib/systemd/system/cribl.service && no "template placeholder shipped" || ok "no placeholders left"

echo "=== 6. Starts and runs as $U"
systemctl enable --now cribl >/tmp/e.log 2>&1 || { no "enable --now failed"; cat /tmp/e.log; }
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
if [ "$(systemctl is-active cribl)" = active ]; then
    ok "service active"
    mainpid=$(systemctl show -p MainPID --value cribl)
    [ "$mainpid" = "$(cat /opt/cribl/pid/cribl.pid 2>/dev/null)" ] \
        && ok "MainPID matches pidfile (Type=forking intact)" || no "MainPID/pidfile mismatch"
    runas=$(ps -o user= -p "$mainpid" | tr -d ' ')
    [ "$runas" = "$U" ] && ok "RUNNING AS $runas" || no "running as $runas"
else
    no "failed to start"; journalctl -u cribl --no-pager -n 25
fi
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:9000/ 2>/dev/null)
[ "$code" = 200 ] && ok "UI responding (HTTP $code)" || no "UI not responding (got '$code')"

echo "=== 7. THE POINT OF THE REBUILD: upgrade must not disturb ownership"
echo marker > /opt/cribl/local/TESTMARKER
cp "$RPM" /tmp/local.rpm          # local disk: bind mounts break rpm -U
rpm -U --force /tmp/local.rpm >/tmp/u.log 2>&1 || no "upgrade failed: $(tail -3 /tmp/u.log)"
after=$(stat -c %U:%G /opt/cribl/bin/cribl)
[ "$after" = "$U:root" ] && ok "ownership preserved across upgrade ($after) - NO chown needed" \
                         || no "ownership became $after - chown still required"
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
[ "$(systemctl is-active cribl)" = active ] && ok "still active after upgrade" || no "upgrade left it down"
[ -f /opt/cribl/local/TESTMARKER ] && ok "config survived upgrade" || no "config lost"

echo "=== 8. Erase"
rpm -e cribl >/tmp/x.log 2>&1 || { no "erase failed"; cat /tmp/x.log; }
[ "$(systemctl is-active cribl 2>/dev/null)" != active ] && ok "stopped by %preun" || no "still running"
[ -f /opt/cribl/local/TESTMARKER ] && ok "config survived erase (by design)" || no "erase destroyed config"
getent passwd "$U" >/dev/null && ok "$U account left intact (not ours to remove)" || no "account was removed"

echo
[ $fail -eq 0 ] && echo "=== ALL ta2crib TESTS PASSED" || echo "=== SOME TESTS FAILED"
exit $fail
