# ---------------------------------------------------------------------------
# Cribl Stream / Edge -- repackaged from the official Linux x64 tarball.
#
# This is a binary repack: the payload is prebuilt (bundled Node.js runtime,
# native .node addons, Brotli-compressed JS bundles). All of RPM's post-install
# file processing is therefore disabled -- stripping, shebang mangling and
# dependency auto-detection would corrupt or wildly over-constrain the payload.
# ---------------------------------------------------------------------------

%global cribl_build   2566299d
%global cribl_home    /opt/cribl
%global cribl_user    cribl
%global cribl_group   cribl

# Binary repack: no debuginfo, no build-id links, no brp-* post-processing.
%global debug_package     %{nil}
%global _build_id_links   none
%global __os_install_post %{nil}
%global __jar_repack      0

# Provided by systemd-rpm-macros on RHEL; absent when building on Debian/Ubuntu.
%{!?_unitdir: %global _unitdir /usr/lib/systemd/system}

Name:           cribl
Version:        4.19.1
Release:        1%{?dist}
Summary:        Cribl Stream -- observability data processing and routing engine

License:        Proprietary
URL:            https://cribl.io/
Source0:        cribl-%{version}-%{cribl_build}-linux-x64.tgz
Source1:        cribl.service
Source2:        cribl.sysconfig
Source3:        README.packaging.md

ExclusiveArch:  x86_64

# The tarball ships its own Node.js runtime and every native module it needs.
# Auto-detection would emit hundreds of bogus Provides from bundled libraries.
AutoReqProv:    no
Requires:       glibc
Requires:       libstdc++
Requires:       systemd
Requires(pre):  shadow-utils

%description
Cribl Stream collects, reduces, enriches, transforms and routes observability
data (logs, metrics and traces) between any source and any destination.

This package installs the official Cribl distribution under %{cribl_home},
creates a dedicated unprivileged %{cribl_user} service account, and provides a
systemd unit. The service is installed but not started; configuration written
at runtime under %{cribl_home}/local is preserved across upgrades and removal.

%prep
# The payload is unpacked straight into the buildroot in %%install; unpacking
# it here as well would double ~1 GB of I/O for no benefit.
%setup -q -c -T

%install
rm -rf %{buildroot}
install -d -m 0755 %{buildroot}/opt
tar -xzf %{SOURCE0} -C %{buildroot}/opt
test -d %{buildroot}%{cribl_home} || \
    { echo "ERROR: tarball did not unpack to cribl/"; exit 1; }

# Directories Cribl populates at runtime. Owned by the package so permissions
# are correct on a fresh install; their *contents* stay unowned so that user
# configuration and logs survive `rpm -e`.
install -d -m 0755 %{buildroot}%{cribl_home}/local
install -d -m 0755 %{buildroot}%{cribl_home}/log
install -d -m 0755 %{buildroot}%{cribl_home}/pid
install -d -m 0755 %{buildroot}%{cribl_home}/groups

install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/cribl.service
install -D -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/sysconfig/cribl

# Convenience: `cribl` on PATH. Run it as the %{cribl_user} user --
# invoking it as root leaves root-owned files under %{cribl_home}.
install -d -m 0755 %{buildroot}%{_bindir}
ln -sf %{cribl_home}/bin/cribl %{buildroot}%{_bindir}/cribl

install -D -m 0644 %{SOURCE3} %{buildroot}%{_docdir}/%{name}/README.packaging.md

%pre
getent group %{cribl_group} >/dev/null || groupadd -r %{cribl_group}
getent passwd %{cribl_user} >/dev/null || \
    useradd -r -g %{cribl_group} -d %{cribl_home} -s /sbin/nologin \
            -c "Cribl service account" %{cribl_user}
exit 0

%post
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    # Fresh install: honour the distribution's presets (normally: disabled).
    if [ "$1" -eq 1 ]; then
        systemctl preset cribl.service >/dev/null 2>&1 || :
    fi
fi
exit 0

%preun
# Uninstall (not upgrade): stop and disable before the files disappear.
if [ "$1" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --no-reload disable --now cribl.service >/dev/null 2>&1 || :
fi
exit 0

%postun
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    # Upgrade: restart only if it was already running.
    if [ "$1" -ge 1 ]; then
        systemctl try-restart cribl.service >/dev/null 2>&1 || :
    fi
fi
exit 0

%files
%defattr(-,%{cribl_user},%{cribl_group},-)
%dir %{cribl_home}
%{cribl_home}/bin
%{cribl_home}/data
%{cribl_home}/default
%{cribl_home}/state
%{cribl_home}/thirdparty
%dir %{cribl_home}/local
%dir %{cribl_home}/log
%dir %{cribl_home}/pid
%dir %{cribl_home}/groups
%attr(0644,root,root) %{_unitdir}/cribl.service
%attr(-,root,root) %{_bindir}/cribl
%config(noreplace) %attr(0644,root,root) %{_sysconfdir}/sysconfig/cribl
%attr(0644,root,root) %doc %{_docdir}/%{name}/README.packaging.md

%changelog
* Thu Aug 20 2026 Packaging <tsvetelin.zlat@gmail.com> - 4.19.1-1
- Initial RPM repack of cribl-4.19.1-%{cribl_build}-linux-x64.tgz
