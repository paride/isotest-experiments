#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    vi_opts_network=(--network none)
}

isotest_test_installed_system_has_booted() {
    # For some reason virt-install (at least the version in Bionic) thinks
    # the installer system has rebooted before it actually has! This
    # seems to happen only in this test case, and does not seem to happen
    # when the host system is Eoan. Let's give it a few more minutes to
    # actually finish.
    sleep 5m

    # With no accesso the the VM it's difficult to tell if it has completed
    # booting. Here we just wait for a few minutes.
    sleep 2m

    virsh list --name | grep "$vm_name" || return 1
    virsh shutdown "$vm_name"

    # Wait for shutdown
    for ((i=0; i<30; i++)); do
        sleep 10
        ! virsh list --name | grep -q "$vm_name" && break
    done

    # Shutdown failed
    virsh list --name | grep -q "$vm_name" && return 1

    local rootdev
    rootdev=$(sudo losetup -Pf --show "$pool_path/disk1.img") ||
        fail "Failed to setup loop device"

    mkdir -p "${workdir}/tmpmnt"
    sudo mount "${rootdev}p2" "${workdir}/tmpmnt"
    sudo cp -r "${workdir}/tmpmnt/var/log" "${workdir}/_var_log"

    # For consistency with the networked tests
    sudo cp -r "${workdir}/tmpmnt/var/log/installer" "${workdir}/installer_logs"

    sudo chown -R "$USER:" "${workdir}/_var_log" "${workdir}/installer_logs"
    sudo umount "${workdir}/tmpmnt"
    sudo losetup -d "$rootdev"
    rmdir "${workdir}/tmpmnt"

    [[ $(ls "${workdir}/_var_log/journal/") ]] || return 1
    grep -q "SUCCESS: running modules for final" "${workdir}/_var_log/cloud-init.log" || return 1
}

