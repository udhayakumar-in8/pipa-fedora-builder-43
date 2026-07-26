# Packages a pre-built pipa kernel (vanilla linux.org + pmOS patch stack,
# see build-kernel.sh) into an RPM Fedora's kernel-install/BLS flow will
# recognize.
#
# Usage:
#   1. Run build-kernel.sh first -- produces ./pipa-kernel-build/stage/usr/lib/modules/<kver>/
#   2. rpmbuild --define "_topdir $(pwd)/rpmbuild" \
#               --define "kver $(cat pipa-kernel-build/src/linux-7.1.4/include/config/kernel.release)" \
#               --define "stagedir $(pwd)/pipa-kernel-build/stage" \
#               -bb linux-xiaomi-pipa.spec
#   3. Resulting RPM installs into the image the same way `dnf install kernel-core`
#      would -- build.sh's existing `kernel-install add` step then just works.

%define kver %{?kver}%{!?kver:UNSET_KVER}
%define stagedir %{?stagedir}%{!?stagedir:UNSET_STAGEDIR}
%define debug_package %{nil}

Name:           linux-xiaomi-pipa
Version:        7.1.4
Release:        1%{?dist}
Summary:        Xiaomi Pad 6 (pipa) kernel, vanilla + pmOS hardware patch stack
License:        GPL-2.0-only
URL:            https://kernel.org
BuildArch:      aarch64
Provides:       kernel = %{version}-%{release}
Provides:       kernel-uname-r = %{kver}

%description
Kernel build for the Xiaomi Pad 6 (pipa), built from vanilla kernel.org
%{version} plus the postmarketOS xiaomi-pipa hardware-enablement patch
stack (touchscreen, panel, camera, audio, fuel gauge, hall sensor,
wireless charging, keyboard cover). Packaged for installation into a
Fedora image via kernel-install (BLS), replacing the pipa-mainline/linux
fork-derived kernel-core normally pulled from COPR.

%prep
# nothing to unpack -- consumes a pre-built stage dir

%build
# nothing to build -- see build-kernel.sh

%install
mkdir -p %{buildroot}/usr/lib/modules
cp -a %{stagedir}/usr/lib/modules/%{kver} %{buildroot}/usr/lib/modules/

%files
/usr/lib/modules/%{kver}

%post
# Same trigger build.sh's existing flow relies on: register the new kernel
# with kernel-install so it gets a BLS boot entry.
kernel-install add %{kver} /usr/lib/modules/%{kver}/vmlinuz --verbose || :

%postun
kernel-install remove %{kver} || :

%changelog
* Sat Jul 25 2026 Udhayakumar <udhayakumar@localhost> - 7.1.4-1
- Initial package: pmOS patch stack rebased onto vanilla 7.1.4 for Fedora image
