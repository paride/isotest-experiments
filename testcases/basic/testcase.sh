#!/bin/bash
# shellcheck disable=SC2154

isotest_test_01_run_a_command() {
    # Test that we can run commands
    expected=itworks
    result=$(sshvm "ubuntu@$vm_ip" echo $expected)
    [[ $expected = "$result" ]] || return 1
}

isotest_test_02_update_upgrade() {
    sshvm "ubuntu@$vm_ip" sudo apt-get update || return 1
    sshvm "ubuntu@$vm_ip" sudo apt-get --quiet --yes dist-upgrade || return 1
}

