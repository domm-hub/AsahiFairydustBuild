Name:           fairydust-kernel
Version:        1
Release:        1%{?dist}
Summary:        Asahi Linux Fairydust ARM64 kernel
License:        GPL-2.0-only
URL:            https://github.com/AsahiLinux/linux

# The kernel is built by run_build.sh; this spec packages the staged output.
# No source archive is used by rpmbuild.

%global _build_id_links none
%global debug_package %{nil}

%description
ARM64 Linux kernel from the Asahi Linux Fairydust branch, packaged for
Fedora Asahi systems. Includes the compressed kernel image, Apple device
tree blobs, and kernel modules.

%prep
%build

%install
rm -rf %{buildroot}

# Kernel image
install -D -m 0644 %{_topdir}/BUILDROOT/fairydust-staging/boot/Image.gz \
    %{buildroot}/boot/Image-fairydust.gz

# Apple DTBs
if [ -d %{_topdir}/BUILDROOT/fairydust-staging/dtbs ]; then
    install -d %{buildroot}/boot/dtbs/fairydust
    find %{_topdir}/BUILDROOT/fairydust-staging/dtbs -type f -name '*.dtb' \
        -exec install -m 0644 {} %{buildroot}/boot/dtbs/fairydust/ \;
fi

# Kernel modules, preserving the modules_install tree.
if [ -d %{_topdir}/BUILDROOT/fairydust-staging/modules/lib/modules ]; then
    cp -a %{_topdir}/BUILDROOT/fairydust-staging/modules/lib/modules \
        %{buildroot}/lib/
fi

%files
/boot/Image-fairydust.gz
/boot/dtbs/fairydust/*.dtb
/lib/modules/*

%changelog
* Thu Aug 20 2026 Fairydust Build <fairydust@localhost> - 1-1
- Initial Fairydust ARM64 kernel RPM
