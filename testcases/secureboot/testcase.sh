#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    vi_opts_boot=(--boot uefi,loader_secure=yes)
    vi_opts_extra=(--features smm=on)
}

isotest_test_secureboot() {
    # FIXME: can we *truly* enable Secure Boot with signature verification?
    sshvm "ubuntu@$vm_ip" mokutil --sb-state | grep "Platform is in Setup Mode" || return 1
}
