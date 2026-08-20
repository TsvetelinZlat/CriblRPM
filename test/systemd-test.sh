#!/bin/bash
# Runs INSIDE the systemd container. Tests the parts container-test.sh cannot:
# the unit file, %post preset, try-restart on upgrade, disable --now on erase.
set -uo pipefail
RPM=$(ls -1 /rpms/*.rpm | head -1)
fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "=== 0. systemd is actually running"
for i in $(seq 1 30); do
    state=$(systemctl is-system-running 2>/dev/null)
    [ "$state" = running ] || [ "$state" = degraded ] && break
    sleep 1
done
[ "$state" = running ] || [ "$state" = degraded ] \
    && ok "systemd is PID 1 (state: $state)" || { no "systemd not up: $state"; exit 1; }

echo "=== 1. Install"
dnf install -y "$RPM" >/tmp/i.log 2>&1 && ok "installed" || { no "install failed"; tail -20 /tmp/i.log; exit 1; }
systemctl cat cribl.service >/dev/null 2>&1 && ok "systemd parsed the unit file" || no "systemd cannot read the unit"
systemd-analyze verify /usr/lib/systemd/system/cribl.service 2>/tmp/v.log
[ -s /tmp/v.log ] && { no "systemd-analyze verify complained:"; cat /tmp/v.log; } || ok "systemd-analyze verify is clean"

echo "=== 2. %post preset left it disabled, not started"
[ "$(systemctl is-enabled cribl 2>/dev/null)" = disabled ] \
    && ok "service installed disabled (preset policy honoured)" \
    || no "unexpected enable state: $(systemctl is-enabled cribl 2>/dev/null)"
[ "$(systemctl is-active cribl 2>/dev/null)" = inactive ] \
    && ok "service not auto-started" || no "service unexpectedly active"

echo "=== 3. enable --now: THE test for Type=forking + PIDFile"
systemctl enable --now cribl >/tmp/e.log 2>&1 || { no "enable --now failed"; cat /tmp/e.log; }
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
if [ "$(systemctl is-active cribl)" = active ]; then
    ok "unit reached active state"
    mainpid=$(systemctl show -p MainPID --value cribl)
    filepid=$(cat /opt/cribl/pid/cribl.pid 2>/dev/null)
    [ -n "$mainpid" ] && [ "$mainpid" != 0 ] && ok "systemd tracked MainPID=$mainpid" || no "systemd has no MainPID - forking not tracked"
    [ "$mainpid" = "$filepid" ] \
        && ok "MainPID matches pidfile ($mainpid) - Type=forking is correct" \
        || no "MainPID=$mainpid but pidfile says $filepid - systemd is tracking the wrong process"
else
    no "unit failed to start"
    systemctl status cribl --no-pager -l 2>&1 | head -30
    journalctl -u cribl --no-pager -n 40 2>&1 | tail -40
fi
[ "$(systemctl is-enabled cribl)" = enabled ] && ok "enabled for boot" || no "not enabled for boot"

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:9000/ 2>/dev/null)
[ "$code" = 200 ] && ok "UI responding under systemd (HTTP $code)" || no "UI not responding (got '$code')"
[ "$(ps -o user= -p "$(systemctl show -p MainPID --value cribl)" 2>/dev/null | tr -d ' ')" = cribl ] \
    && ok "running as the cribl user, not root" || no "wrong runtime user"

echo "=== 4. restart"
systemctl restart cribl >/tmp/r.log 2>&1
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
[ "$(systemctl is-active cribl)" = active ] && ok "survives systemctl restart" || { no "restart broke it"; journalctl -u cribl --no-pager -n 20; }

echo "=== 5. %postun try-restart on upgrade keeps a running service running"
echo marker > /opt/cribl/local/TESTMARKER
rpm -U --force "$RPM" >/tmp/u.log 2>&1 || no "upgrade failed"
for i in $(seq 1 60); do [ "$(systemctl is-active cribl)" = active ] && break; sleep 2; done
[ "$(systemctl is-active cribl)" = active ] && ok "still active after upgrade (try-restart worked)" || no "upgrade left the service down"
[ -f /opt/cribl/local/TESTMARKER ] && ok "config survived upgrade" || no "config lost"

echo "=== 6. %preun stops and disables on erase"
rpm -e cribl >/tmp/x.log 2>&1 || { no "erase failed"; cat /tmp/x.log; }
[ "$(systemctl is-active cribl 2>/dev/null)" != active ] && ok "service stopped by %preun" || no "service still running after erase"
systemctl list-unit-files 2>/dev/null | grep -q '^cribl.service' && no "unit still registered" || ok "unit deregistered"
[ -f /opt/cribl/local/TESTMARKER ] && ok "config survived erase (by design)" || no "erase destroyed config"

echo
[ $fail -eq 0 ] && echo "=== ALL SYSTEMD TESTS PASSED" || echo "=== SOME TESTS FAILED"
exit $fail
