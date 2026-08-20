# cribl RPM (repack of the official tarball)

Built from `cribl-4.19.1-2566299d-linux-x64.tgz`. This is a *repack*: the
payload is Cribl's own prebuilt distribution, unmodified.

## What the package does

- Installs the distribution to `/opt/cribl`.
- Creates a system account `cribl:cribl` (`/sbin/nologin`, home `/opt/cribl`).
- Installs `/usr/lib/systemd/system/cribl.service` (not enabled by default --
  `%post` runs `systemctl preset`, which honours distro policy).
- Installs `/etc/sysconfig/cribl` as `%config(noreplace)` for `CRIBL_*` vars.
- Symlinks `/usr/bin/cribl` -> `/opt/cribl/bin/cribl`.

## After installing

    sudo systemctl enable --now cribl

The UI listens on <http://HOST:9000> (default login `admin` / `admin`).

Set the deployment mode in `/etc/sysconfig/cribl` *before* first start if this
node is a Worker or managed Edge node.

## Upgrades and removal

Files Cribl writes at runtime -- `/opt/cribl/local`, `log`, `groups`, `pid` --
are not owned by the package (only the directories are), so configuration and
logs survive both `rpm -U` and `rpm -e`. Remove `/opt/cribl` by hand if you
want a truly clean uninstall.

`/opt/cribl/default` *is* package-owned and is replaced on upgrade, which is
correct -- that is Cribl's shipped defaults, not your configuration.

## Notes / caveats

- `AutoReqProv: no`. The tarball bundles its own Node.js runtime and native
  addons; automatic dependency extraction would generate meaningless
  `Provides:` entries for bundled shared objects. Requires are listed by hand
  (`glibc`, `libstdc++`, `systemd`).
- All `brp-*` post-processing is disabled (`__os_install_post %{nil}`).
  Stripping the bundled binaries or rewriting their shebangs breaks them.
- The package is not signed. Sign with `rpm --addsign` before publishing to a
  repository.
- SELinux: no policy module is shipped. On enforcing systems Cribl generally
  runs fine under `unconfined_service_t`, but review AVC denials after the
  first start.
- Run the `cribl` CLI as the `cribl` user (`sudo -u cribl cribl ...`).
  Running it as root leaves root-owned files under `/opt/cribl` that the
  service then cannot write.
