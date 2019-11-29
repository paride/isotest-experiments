#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    # Recommended custom UEFI setup, see virt-install(1)
    vi_opts_boot=(--boot loader=/usr/share/OVMF/OVMF_CODE.secboot.fd,loader.readonly=yes,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS.ms.fd,loader_secure=yes)
    vi_opts_extra=(--features smm=on)
}

isotest_test_secureboot() {
    sshvm "ubuntu@$vm_ip" mokutil --sb-state | grep "SecureBoot enabled" || return 1
    sshvm "ubuntu@$vm_ip" bootctl 2>&1 | grep "Secure Boot: enabled" || return 1
}
