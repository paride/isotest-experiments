#!/bin/bash
# shellcheck disable=SC2154

isotest_test_snap_present() {
    # Check if the 'stress-ng' snap is installed
    sshvm "ubuntu@$vm_ip" timeout 2m cloud-init status --wait > /dev/null || return 1
    sshvm "ubuntu@$vm_ip" snap list stress-ng || return 1
}
