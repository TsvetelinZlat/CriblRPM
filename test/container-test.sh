#!/bin/bash
# Runs INSIDE a rockylinux:9 container with the RPM bind-mounted at /rpms.
# Covers everything except systemd itself: %pre, dependency resolution, file
# placement, that Cribl actually starts as the unprivileged user, that it
# writes the pidfile the unit expects, and the upgrade/erase paths.
set -uo pipefail
RPM=$(ls -1 /rpms/*.rpm | head -1)
fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "=== 1. Dependency resolution and install"
dnf install -y "$RPM" >/tmp/install.log 2>&1 \
    && ok "dnf resolved all Requires and installed" \
    || { no "install failed"; tail -20 /tmp/install.log; }
rpm -q cribl >/dev/null && ok "rpm -q cribl: $(rpm -q cribl)" || no "package not registered"

echo "=== 2. Service account created by %pre"
id cribl >/dev/null 2>&1 && ok "user cribl exists: $(id cribl)" || no "user cribl missing"
getent passwd cribl | grep -q ':/sbin/nologin$' && ok "login shell is /sbin/nologin" || no "unexpected shell: $(getent passwd cribl)"
getent passwd cribl | grep -q ':/opt/cribl:'   && ok "home is /opt/cribl"          || no "unexpected home"
[ "$(id -u cribl)" -lt 1000 ] && ok "system uid ($(id -u cribl))" || no "uid $(id -u cribl) is not in the system range"

echo "=== 3. File placement and ownership"
[ -x /opt/cribl/bin/cribl ]                     && ok "/opt/cribl/bin/cribl executable" || no "binary missing or not executable"
[ "$(stat -c %U /opt/cribl/bin/cribl)" = cribl ] && ok "payload owned by cribl"          || no "payload owned by $(stat -c %U /opt/cribl/bin/cribl)"
[ -L /usr/bin/cribl ]                           && ok "/usr/bin/cribl symlink"          || no "symlink missing"
[ -f /etc/sysconfig/cribl ]                     && ok "/etc/sysconfig/cribl present"    || no "sysconfig missing"
[ -f /usr/lib/systemd/system/cribl.service ]    && ok "unit file installed"             || no "unit missing"
for d in local log pid groups; do
    [ "$(stat -c %U:%G /opt/cribl/$d)" = cribl:cribl ] \
        && ok "/opt/cribl/$d writable by service account" \
        || no "/opt/cribl/$d owned by $(stat -c %U:%G /opt/cribl/$d)"
done

echo "=== 4. Cribl starts as the unprivileged account"
# Same environment the unit provides, minus systemd itself.
runuser -u cribl -- env CRIBL_HOME=/opt/cribl /opt/cribl/bin/cribl start >/tmp/start.log 2>&1
rc=$?
[ $rc -eq 0 ] && ok "cribl start exited 0" || { no "cribl start exited $rc"; tail -20 /tmp/start.log; }

for i in $(seq 1 30); do [ -s /opt/cribl/pid/cribl.pid ] && break; sleep 1; done
# This is the assertion that matters for the unit's Type=forking + PIDFile.
if [ -s /opt/cribl/pid/cribl.pid ]; then
    pid=$(cat /opt/cribl/pid/cribl.pid)
    ok "pidfile at the path the unit declares (/opt/cribl/pid/cribl.pid, pid $pid)"
    kill -0 "$pid" 2>/dev/null && ok "pid $pid is a live process" || no "pidfile is stale - Type=forking would fail"
else
    no "no pidfile at /opt/cribl/pid/cribl.pid - unit's PIDFile= is wrong"
    ls -la /opt/cribl/pid/ 2>&1 | head
fi

for i in $(seq 1 60); do
    curl -sS -o /dev/null http://localhost:9000/ 2>/dev/null && break; sleep 2
done
code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:9000/ 2>/dev/null)
[ -n "$code" ] && [ "$code" != 000 ] && ok "UI responding on :9000 (HTTP $code)" || no "no response on :9000"

[ -n "$(ls -A /opt/cribl/local 2>/dev/null)" ] && ok "config written to /opt/cribl/local" || no "nothing in /opt/cribl/local"
echo "cribl-rpm-test-marker" > /opt/cribl/local/TESTMARKER

runuser -u cribl -- env CRIBL_HOME=/opt/cribl /opt/cribl/bin/cribl stop >/tmp/stop.log 2>&1 \
    && ok "cribl stop exited 0" || no "cribl stop failed: $(tail -3 /tmp/stop.log)"

echo "=== 5. Upgrade path (scriptlets run with \$1=2)"
rpm -U --force "$RPM" >/tmp/upgrade.log 2>&1 \
    && ok "reinstall/upgrade succeeded" || { no "upgrade failed"; tail -10 /tmp/upgrade.log; }
[ -f /opt/cribl/local/TESTMARKER ] && ok "user config in /opt/cribl/local survived upgrade" || no "upgrade destroyed /opt/cribl/local"
grep -q . /etc/sysconfig/cribl && ok "%config(noreplace) sysconfig intact" || no "sysconfig lost"

echo "=== 6. Erase path"
rpm -e cribl >/tmp/erase.log 2>&1 && ok "rpm -e succeeded" || { no "erase failed"; cat /tmp/erase.log; }
[ ! -e /opt/cribl/bin/cribl ]     && ok "package payload removed"      || no "payload left behind"
[ ! -e /usr/lib/systemd/system/cribl.service ] && ok "unit removed"     || no "unit left behind"
[ -f /opt/cribl/local/TESTMARKER ] && ok "user config survived erase (by design)" || no "erase destroyed user config"

echo
[ $fail -eq 0 ] && echo "=== ALL CONTAINER TESTS PASSED" || echo "=== SOME TESTS FAILED"
exit $fail
