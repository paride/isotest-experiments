#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    vi_opts_boot=(--boot uefi)
}

isotest_test_uefi_boot() {
    sshvm "ubuntu@$vm_ip" test -d /sys/firmware/efi
}
