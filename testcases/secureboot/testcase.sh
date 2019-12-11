#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    # Recommended custom UEFI setup, see virt-install(1)
    vi_opts_boot=(--boot loader=/usr/share/OVMF/OVMF_CODE.secboot.fd,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/OVMF/OVMF_VARS.ms.fd,loader_secure=yes)
    vi_opts_extra=(--features smm=on)
}

isotest_test_secureboot() {
    sshvm "ubuntu@$vm_ip" mokutil --sb-state | grep "SecureBoot enabled" || return 1

    # Ignore the bootctl return code (returns 1 on Bionic)
    sshvm "ubuntu@$vm_ip" 'bootctl 2>/dev/null || true' | grep "Secure Boot: enabled" || return 1
}
