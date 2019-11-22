#!/bin/bash
# shellcheck disable=SC2153

# Useful environment variables:
#
# ISO=<path>: path to the ISO image to test
# TESTCASE=<name>: testcase to run
# VM_NAME=<name>: VM name
# NO_PRESEED=bool: if 'true', skip the actual preseeding
# NO_CLEANUP=bool: do no destroy/undefine the VM before exiting
# REBOOT=<bool>: reboot at the end of the installation
#
# Bools are to be set to 'true' or to anything else for false.


set -o pipefail
shopt -s failglob

export PS4='+ [$(basename ${BASH_SOURCE}):${LINENO}${FUNCNAME[0]:+ ${FUNCNAME[0]}()}] '

export LIBVIRT_DEFAULT_URI='qemu:///system'

info() { printf "I: %s\n" "$*" >&2; }
warn() { printf "W: %s\n" "$*" >&2; }
error() { printf "E: %s\n" "$*" >&2; }
fail() { [ $# -eq 0 ] || error "$@"; exit 1; }

cleanup() {
    if ((no_cleanup)); then
        info "Skipping cleanup (NO_CLEANUP=true)"
        return
    fi

    info "Cleaning up VM and storage pool..."

    # sanity
    [[ -n $vm_name ]] || return
    # destroy vm
    virsh list --name | grep -q "$vm_name" && virsh destroy "$vm_name"
    # undefine vm
    if virsh list --name --all | grep -q "$vm_name"; then
        sleep 5
        virsh undefine "$vm_name" --nvram --remove-all-storage
    fi

    # sanity
    [[ -n $pool_name ]] || return
    # destroy storage pool
    virsh pool-list --name | grep -q "$pool_name" && virsh pool-destroy "$pool_name"
    # undefine storage pool
    if virsh pool-list --name --all | grep -q "$pool_name"; then
        sleep 5
        virsh pool-undefine "$pool_name"
    fi

    rm -rf "$pool_path"

    # check the cleanup outcome
    virsh list --name --all | grep -q "$vm_name" && fail "Failed to cleanup VM"
    virsh pool-list --name --all | grep -q "$pool_name" && fail "Failed to cleanup storage pool"
}

get_vm_ip() {
    # FIXME: there has to be a better way!
    local mac ipaddr
    mac=$(virsh domiflist "$vm_name" | awk '{ print $5 }' | tail -2 | head -1)
    ipaddr=$(arp -an | grep "$mac" | awk '{ print $2 }' | sed 's/[()]//g')
    [[ $ipaddr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    echo "$ipaddr"
}

sshvm() {
    ssh -q -i "$ssh_privkey" -o 'StrictHostKeyChecking no' \
        -o 'UserKnownHostsFile /dev/null' "$@"
}

rsyncvm() {
    rsync -e "ssh -q -i $ssh_privkey -o 'StrictHostKeyChecking no' \
        -o 'UserKnownHostsFile /dev/null'" "$@"
}

setup_storage_pool() {
    info "Setting storage pool $pool_name at $pool_path"

    rm -rf "$pool_path" || fail "Failed to cleanup the storage pool directory '$pool_path'"
    mkdir "$pool_path" || fail "Failed to create the storage pool directory '$pool_path'"

    virsh pool-define-as --name "$pool_name" --type dir --target "$pool_path" ||
        fail "Failed to define storage pool $pool_name"

    virsh pool-start "$pool_name" ||
        fail "Failed to define storage pool $pool_name"
}

copy_iso() {
    # Copying the ISO image to the storage pool helps keeping all the
    # volumes/images related to a test run in one place. When running
    # virt-install with --cdrom it automatically creates a storage pool
    # in the directory where the ISO image is. Having the image in the
    # pool we're already using eases the cleanup process.
    info "Copying the ISO to the storage pool"
    cp "$iso" "$pool_path"
}

generate_answers_yaml() {
    info "Generating answers.yaml from template"

    # Set and export the variables needed to compile the answers.yaml template
    # using envsubst(1). Namespace them as 'ISOTEST_*'.
    ISOTEST_HOSTNAME=$vm_name
    ISOTEST_SUBIQUITY_REFRESH=${SUBIQUITY_REFRESH:-true}
    ISOTEST_SUBIQUITY_CHANNEL=${SUBIQUITY_CHANNEL:-stable}
    ISOTEST_SSH_PUBKEY=$(cat "$ssh_pubkey") || fail "SSH pubkey not found"
    ISOTEST_REBOOT=${REBOOT:-true}

    export ISOTEST_HOSTNAME
    export ISOTEST_SUBIQUITY_CHANNEL
    export ISOTEST_SUBIQUITY_REFRESH
    export ISOTEST_SSH_PUBKEY
    export ISOTEST_REBOOT

    # As we namespaced the variables to substitute in the it's easty make a list
    # of them to pass to envsubst(1).
    substvars=$(printenv | grep '^ISOTEST_' | sed 's/=.*//; s/^/\$/' | paste -s -d ' ')
    envsubst "$substvars" < "$testcasedir/answers.yaml.template" > "${workdir}/answers.yaml" ||
        fail "Failed to generate answers from template"
}

generate_answers_img() {
    # Get rid of this function once subiquity supports passing the answers
    # file as a b64 encoded string in the kernel cmdline.

    info "Creating the preseed volume"

    local img="${workdir}/answers.img"
    truncate -s 1M "$img"
    mkfs.ext2 -q -U 00c629d6-06ab-4dfd-b21e-c3186f34105d "$img"

    local imgmnt="${workdir}/tmpmnt"
    mkdir "$imgmnt" || fail "Failed to create tmp mount directory"

    # Once the Jenkins nodes are on Focal mount with 'fuse2fs -o fakeroot' and
    # drop the sudo on the following three lines:
    sudo fuse2fs "$img" "$imgmnt" || fail "Failed to mount $img"
    sudo cp "${workdir}/answers.yaml" "$imgmnt"
    sudo fusermount -u "$imgmnt" || fail "Failed to umount $imgmnt"

    rmdir "$imgmnt" || fail "Failed to cleanup tmp mount directory"

    cp "$img" "$pool_path" || fail "Can't copy answers.img to the pool directory"

    # Keep a compressed copy to be stored as an artifact.
    gzip "$img"
}

generate_ssh_key() {
    info "Generating ephemeral SSH keys"
    ssh-keygen -q -f "$ssh_privkey" -N '' || fail "Could not generate SSH keys"
}

install_vm() {
    info "Installing..."

    # Set some sensible, cross-arch defaults.
    #
    # The variable arrays can be overridden in the test case definition
    # to test specific configurations.

    vi_opts_base=(--name "$vm_name" --os-variant ubuntu18.04 --noautoconsole --wait -1)
    vi_opts_boot=()
    vi_opts_memory=(--memory 2048)

    # raw images make debugging easier (we can fdisk and loopback mount them)
    vi_opts_storage=(--disk "path=$pool_path/disk1.img,format=raw,bus=virtio,cache=unsafe,size=4")
    ((!no_preseed)) && vi_opts_storage_preseed=(--disk "vol=$pool_name/answers.img,bus=virtio,readonly=on")
    vi_opts_cdrom=(--cdrom "$pool_path/$iso_basename")
    vi_opts_network=()
    vi_opts_console=()
    vi_opts_extra=()

    if [[ $arch = amd64 ]]; then
        # On amd64 the installer does not start on the serial console.
        # Let's disable it; we'll use the graphical one only.
        vi_opts_console=(--console none)
    elif [[ $arch = ppc64el ]]; then
        # On ppc64 the text console is functional; disable the gfx one
        vi_opts_console=(--nographics)
    fi

    # Load the testcase specific overrides (if any)
    type -t virt_install_opts > /dev/null && virt_install_opts

    if type -t preinst_script > /dev/null; then
        # Run the preinstall script. Usecase: generate the volumes to test
        # the "reuse existing partition" feature. The function is defined
        # as part of the test case.
        info "Running preinstall script"
        preinst_script
    fi

    # Refresh the pool as new volumes are not available immediately
    # after their creation. If the preinst script created one it may
    # not be available at install time without refreshing.
    virsh pool-refresh "$pool_name"

    (set -x; virt-install "${vi_opts_base[@]}" "${vi_opts_memory[@]}" \
        "${vi_opts_boot[@]}" "${vi_opts_storage[@]}" \
        "${vi_opts_storage_preseed[@]}" "${vi_opts_cdrom[@]}" \
        "${vi_opts_network[@]}" "${vi_opts_console[@]}" \
        "${vi_opts_extra[@]}") || fail "Install failed"

    virsh list --name | grep -q "$vm_name" || fail "Installation finished but VM not found"
}

wait_for_vm() {
    info "Install finished, waiting for VM to reboot"
    declare -i online=0
    for ((i=0; i<40; i++)); do
        virsh list --name | grep -q "$vm_name" || fail "VM not found (externally destroyed?)"
        sleep 5
	vm_ip=$(get_vm_ip) || continue
        sshvm "ubuntu@$vm_ip" true && online=1 && break
    done

    ((online)) || fail "Failed to connect to VM $vm_name"
    info "VM online with IP address: $vm_ip"
}

read_testcase() {
    if [[ -f $testcasedir/README ]]; then
        info "Testcase README:"
        echo '   ------------------------------------------------------------------------'
        sed 's/^/   /' < "$testcasedir/README"
        echo '   ------------------------------------------------------------------------'
    fi

    # Source the testcase scripts
    # shellcheck source=testcases/basic/testcase.sh
    source "$testcasedir/testcase.sh" || fail 'Failed to source testcase script'
    compgen -A function isotest_test_ > /dev/null || fail "Testcase does not define any isotest_test_*() function"
}

# An optional test that ensures there are no tracebacks in the logs
isotest_optional_test_no_tracebacks() {
    ! grep -q Traceback "${workdir}/installer_logs/curtin-install.log" \
        "${workdir}/installer_logs/subiquity-debug.log".* && return 0
}

### END OF FUNCTION DEFINITIONS

scriptdir=$(realpath "${BASH_SOURCE%/*}")
arch=$(dpkg --print-architecture)
release=${RELEASE:-$(distro-info --latest 2>/dev/null || source /etc/os-release && echo $UBUNTU_CODENAME)} ||
    fail "RELEASE variable not set and could not guess a release to use."
testcase=${TESTCASE:-basic}
testcasesdir="$scriptdir/testcases"
testcasedir="$testcasesdir/$testcase"
iso=$(realpath "${ISO:-$HOME/iso/ubuntu-server/$release-live-server-$arch.iso}")
iso_basename=$(basename "$iso")
build_id=${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}
vm_prefix=${VM_PREFIX:-isotest}
vm_name="${VM_NAME:-${vm_prefix}-${testcase}-${build_id}}"
workdir=$(realpath "${vm_name}")
pool_name="$vm_name"
pool_path="${workdir}/storage_pool"
ssh_privkey="${workdir}/id_rsa"
ssh_pubkey="${ssh_privkey}.pub"
mediainfofile="${workdir}/media_info"

# VM has networking
declare -i vm_has_network=1

declare -i no_preseed=0
[[ $NO_PRESEED = true ]] && no_preseed=1

declare -i no_cleanup=0
[[ $NO_CLEANUP = true ]] && no_cleanup=1

# Return code Jenkins will mark as Unstable
declare -i unstable_rc=99

for tool in virsh virt-install xmlstarlet envsubst; do
    command -v "$tool" > /dev/null || fail "Missing tool: $tool"
done

trap cleanup EXIT

info "ISO testing begins"
info "Testcase: $testcase"

mkdir "$workdir"

# This allows us to skip some testcases from Jenkins by setting the TESTCASE_SUBSET
# environment variable. Useful in matrix jobs. Skipped sub-jobs can be set as
# unstable using their return code.
if [[ -n $TESTCASE_SUBSET && ! $TESTCASE_SUBSET =~ (^| )$testcase($| ) ]]; then
    warn "Testcase '$testcase' not in TESTCASE_SUBSET ($TESTCASE_SUBSET), exiting with RC=$unstable_rc"
    exit $unstable_rc
fi

[[ -f $iso ]] || fail "ISO image not found: $iso"
info "Target ISO: $iso"

bsdtar -Oxf "$iso" .disk/info > "$mediainfofile" || fail "Couldn't retrieve the ISO's .disk/info file"
info "Media info: $(cat "$mediainfofile")"

info "VM name $vm_name"

read_testcase
generate_ssh_key
setup_storage_pool
copy_iso
generate_answers_yaml
generate_answers_img
install_vm

virsh list --name | grep -q "$vm_name" || fail "VM not found"
virsh dumpxml "$vm_name" > "${workdir}/${vm_name}.xml"

if ! xmlstarlet sel -Q -t -c 'domain/devices/interface' "${workdir}/${vm_name}.xml"; then
    info "The VM has no network inteface. The install logs won't be retrieved."
    vm_has_network=0
fi

if ((vm_has_network)); then
    wait_for_vm

    info "Setting up the VM for passwordless sudo"
    sshvm "ubuntu@$vm_ip" 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /tmp/sudo-nopasswd'
    sshvm "ubuntu@$vm_ip" 'echo ubuntu | sudo --stdin cp /tmp/sudo-nopasswd /etc/sudoers.d 2>/dev/null'
    sshvm "ubuntu@$vm_ip" 'sudo --non-interactive true' || fail "Failed to setup sudo"

    info "Retrieving installer logs"
    sshvm "ubuntu@$vm_ip" "sudo --non-interactive cp --recursive /var/log/installer installer_logs"
    sshvm "ubuntu@$vm_ip" "sudo --non-interactive chown --recursive ubuntu: installer_logs"
    # This will skip symlinks, which is fine as Jenkins can't archive them as such
    rsyncvm --recursive "ubuntu@$vm_ip:installer_logs" "${workdir}/" || fail "Failed to retrieve the installer logs"
fi


info "Test run begins"

# This variable will hold the test run return code.
# Work in negative logic, assuming the test has failed.
declare -i testrc=1

declare -i ntests passed_tests rc
ntests=$(compgen -A function isotest_test_ | wc -l)
passed_tests=0
((ntests)) || fail "No tests defined!"
info "Found $ntests test definitions"
for testfunc in $(compgen -A function isotest_test_); do
    info "Running test: $testfunc"
    (set -x; $testfunc)
    rc=$?
    if ((rc == 0)); then
        info "Result: PASS"
        ((passed_tests+=1))
    else
        info "Result: FAIL (RC = $rc)"
    fi
done
info "Tests passed: $passed_tests/$ntests"

# If all the tests succeeded promote the result from FAILED to UNSTABLE
((ntests == passed_tests)) && testrc="$unstable_rc"

if ((testrc == unstable_rc)); then
    ntests=$(compgen -A function isotest_optional_test_ | wc -l)
    passed_tests=0
    info "Found $ntests optional test definitions"
    for testfunc in $(compgen -A function isotest_optional_test_); do
        info "Running test: $testfunc"
        (set -x; $testfunc)
        rc=$?
        if ((rc == 0)); then
            info "Result: PASS"
            ((passed_tests+=1))
        else
            info "Result: FAIL (RC = $rc)"
        fi
    done
    ((ntests == passed_tests)) && testrc=0
fi

if ((testrc == 0)); then
    info "Test result: SUCCESS"
elif ((testrc == 99)); then
    info "Test result: UNSTABLE (found failures in optional tests)"
else
    info "Test result: FAILURE"
fi

cleanup

info "Test run completed"

exit $testrc
