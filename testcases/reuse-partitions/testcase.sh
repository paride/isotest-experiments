#!/bin/bash
# shellcheck disable=SC2154,SC2034

preinst_script() {
    truncate -s 8G "$pool_path/root.img"

    sudo parted --script --align optimal "$pool_path/root.img" -- \
        mklabel gpt \
        mkpart primary ext4 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart primary ext4 2MiB 1GiB \
        mkpart primary ext4 1GiB -2048s ||
            fail "Failed to partition root.img"

    local rootdev
    rootdev=$(sudo losetup -Pf --show "$pool_path/root.img") ||
        fail "Failed to setup loop device"

    # Safety check: do not proceed if rootdev is empty or unset.
    : "${rootdev:?}"

    # Do not "fail early" here, as we want to reach the 'losetup -d'.
    sudo mkfs.ext4 -q "${rootdev}p2"
    mkdir "${workdir}/tmpmnt"
    sudo mount "${rootdev}p2" "${workdir}/tmpmnt"
    echo important_data | sudo tee "${workdir}/tmpmnt/existing" > /dev/null
    sudo umount "${workdir}/tmpmnt"
    sudo losetup -d "$rootdev"
    rmdir "${workdir}/tmpmnt"
}

virt_install_opts() {
    vi_opts_storage=(--disk "vol=$pool_name/root.img,bus=virtio,cache=unsafe")
}

isotest_test_data_present_in_reused_partition() {
    expected=important_data
    result=$(sshvm "ubuntu@$vm_ip" cat /srv/existing)
    [[ $result = "$expected" ]] || return 1
}
