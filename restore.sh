#!/bin/bash

# =========================
# CONFIG
# =========================
SOURCE_VMS=(105 106 107)             # A space separated list of source VMIDs to restore
TARGET_STORAGE="RestoreTest"         # The storage where the restored VM will be placed in
PBS_STORAGE="Backups"                # The ID of the storage under Datacenter - Storage
NEW_NIC_BRIDGE="vmbr0"               # Network bridge with VLAN aware
NEW_NIC_VLAN=999                     # VLAN ID
FIXED_MAC="6A:3F:9C:12:8B:EF"        # Bogus MAC
VLAN_NET="192.168.123"               # /24 network for VLAN
IP_RANGE_START=200                   # Ping sweep from 200
IP_RANGE_END=250                     # Ping sweep to 250
EMAIL_TO="example@example.com"
LOGFILE="/var/log/proxmox_vm_restore.log"
HALF_RAM_MIN=512                     # Minimum RAM in MB
PING_TIMEOUT=2                       # seconds
MAX_PING_WAIT=900                    # Max time to wait for VM to respond (seconds)
SLEEP_INTERVAL=5                     # Interval between ping attempts

# Enable logging to file and stdout
exec &> >(tee -a "$LOGFILE")

# =========================
# FUNCTIONS
# =========================

send_email() {
    local vmid=$1
    local source=$2
    local backup=$3
    local status=$4
    local ip=$5
    local vmname=$6

    if [[ $status == "SUCCESS" ]]; then
        subject="Proxmox VM Restore SUCCESS - VMID $vmid ($vmname)"
    else
        subject="Proxmox VM Restore FAIL - VMID $vmid ($vmname)"
    fi

    echo -e "VMID: $vmid\nSource VMID: $source\nBackup: $backup\nResult: $status\nVM IP: $ip\n" \
        | mail -s "$subject" "$EMAIL_TO"
}

get_new_vmid() {
    for vmid in $(seq 555 9999); do
        if ! qm status $vmid &>/dev/null; then
            echo $vmid
            return
        fi
    done
    echo "ERROR: No available VMID found" >&2
    exit 1
}

detect_vm_ip() {
    local timeout=$1
    local vm_ip=""
    local elapsed=0

    echo "Waiting for VM to get IP and respond to ping..."
    while (( elapsed < timeout )); do
        for ip in $(seq $IP_RANGE_START $IP_RANGE_END); do
            ping -c1 -W $PING_TIMEOUT $VLAN_NET.$ip &>/dev/null
            if [[ $? -eq 0 ]]; then
                vm_ip="$VLAN_NET.$ip"
                echo "VM is responding at $vm_ip"
                echo "$vm_ip"
                return
            fi
        done
        sleep $SLEEP_INTERVAL
        (( elapsed += SLEEP_INTERVAL ))
    done

    echo "No IP detected for VM after $timeout seconds"
    echo ""
}

restore_vm() {
    local source_vmid=$1

    echo "=============================="
    echo "Starting restore for VMID $source_vmid"

    # --- Find latest backup ---
    latest_backup=$(pvesm list $PBS_STORAGE --vmid $source_vmid | awk 'NR>1 {print $1}' | sort | tail -n1)
    if [[ -z "$latest_backup" ]]; then
        echo "No backup found for VMID $source_vmid on $PBS_STORAGE"
        send_email "N/A" "$source_vmid" "N/A" "FAIL" "N/A" "N/A"
        return
    fi
    echo "Latest backup: $latest_backup"

    # --- Find new VMID ---
    new_vmid=$(get_new_vmid)
    echo "Assigning new VMID: $new_vmid"

    # --- Restore VM ---
    qmrestore "$latest_backup" "$new_vmid" --storage "$TARGET_STORAGE" --unique --force
    if [[ $? -ne 0 ]]; then
        echo "Restore failed for VMID $source_vmid"
        send_email "$new_vmid" "$source_vmid" "$latest_backup" "FAIL" "N/A" "N/A"
        return
    fi

    # --- Remove USB, PCI, and old network devices ---
    for devtype in usb hostpci net; do
        devs=$(qm config $new_vmid | grep "^$devtype" | awk -F':' '{print $1}')
        for dev in $devs; do
            qm set $new_vmid --delete $dev
            echo "Deleted $dev from VMID $new_vmid"
        done
    done

    # --- Add new network interface with fixed MAC ---
    qm set $new_vmid --net0 "virtio=$FIXED_MAC,bridge=$NEW_NIC_BRIDGE,firewall=1,tag=$NEW_NIC_VLAN"
    echo "Added new NIC $FIXED_MAC to VMID $new_vmid"

    # --- Set half of original RAM ---
    ORIG_RAM=$(qm config "$new_vmid" | grep "^memory:" | awk '{print $2}')
    HALF_RAM=$(( ORIG_RAM / 2 ))
    [[ $HALF_RAM -lt $HALF_RAM_MIN ]] && HALF_RAM=$HALF_RAM_MIN
    qm set "$new_vmid" --memory "$HALF_RAM"
    echo "Set VMID $new_vmid memory to half of original: $HALF_RAM MB"

    # --- Start VM ---
    qm start $new_vmid
    echo "VMID $new_vmid starting..."

    # --- Detect VM IP via ping ---
    vm_ip=$(detect_vm_ip $MAX_PING_WAIT)
    if [[ -n "$vm_ip" ]]; then
        status="SUCCESS"
    else
        status="FAIL"
        vm_ip="N/A"
    fi

    # --- Get VM name for email ---
    vm_name=$(qm config "$new_vmid" | grep "^name:" | awk '{print $2}')
    [[ -z "$vm_name" ]] && vm_name="N/A"

    # --- Send email with IP ---
    send_email "$new_vmid" "$source_vmid" "$latest_backup" "$status" "$vm_ip" "$vm_name"

    echo "Restore/test completed for VMID $source_vmid -> new VMID $new_vmid [$status]"
    echo "=============================="

    # --- Cleanup VM ---
        echo "Cleaning up VM $new_vmid"
        qm stop $new_vmid &>/dev/null
        sleep 15
        qm destroy $new_vmid

    echo "Restore/test completed for VMID $source_vmid -> new VMID $new_vmid [$status]"
    echo "=============================="

}

# =========================
# MAIN LOOP
# =========================
for vmid in "${SOURCE_VMS[@]}"; do
    restore_vm "$vmid"
done

echo "All restores completed!"
