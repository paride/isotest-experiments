#!/bin/bash
# shellcheck disable=SC2154,SC2034

virt_install_opts() {
    vi_opts_storage=(
        --disk "path=$pool_path/disk1.qcow2,bus=virtio,cache=unsafe,size=6"
        --disk "path=$pool_path/disk2.qcow2,bus=virtio,cache=unsafe,size=6"
        --disk "path=$pool_path/disk3.qcow2,bus=virtio,cache=unsafe,size=6"
        )
}

isotest_test_root_on_raid() {
    rootdev=$(sshvm "ubuntu@$vm_ip" df / | sed 1d | awk '{ print $1 }')
    expected=^/dev/md
    echo "rootdev: '$rootdev', should match: '$expected'"
    [[ $rootdev =~ $expected ]] || return 1
}
