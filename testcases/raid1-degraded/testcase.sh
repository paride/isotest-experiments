#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    vi_opts_storage=(
        --disk "path=$pool_path/disk1.qcow2,bus=virtio,cache=unsafe,size=2"
        --disk "path=$pool_path/disk2.qcow2,bus=virtio,cache=unsafe,size=6"
        --disk "path=$pool_path/disk3.qcow2,bus=virtio,cache=unsafe,size=6"
        )
}

isotest_test_boot_on_degraded_raid() {
    # Make sure the raid is clean
    sshvm "ubuntu@$vm_ip" sudo mdadm -D /dev/md1 | grep -E 'State : (active|clean) *$' || return 1

    virsh detach-disk "$vm_name" vdc --persistent
    vm_reboot || return 1

    # Make sure the raid is degraded
    sshvm "ubuntu@$vm_ip" sudo mdadm -D /dev/md1 | grep 'State : .*degraded *' || return 1
}
