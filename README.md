# Proxmox VM Restore & Test Automation Script

This Bash script automates restoring Proxmox VMs from PBS backups, testing basic network functionality, and automatically cleaning up the restored VM. It is ideal for backup verification, disaster-recovery validation, and automated integrity testing.
This script is designed with the thought of being deployed on the same PVE as the restored VM. Thats why I am removing the Network, USB and PCI devices.

# ⚠️ Read through this script carefully before deploying!
# ⚠️ Use at your own risk

## Requirements
* A Proxmox backup mounted as a storage 
* mail
* VLAN setup with DHCP enabled that specific VLAN
* The restored VM needs to be able to get DHCP from the new network device being added.

> You could use this with static ip addresses but then you would have to stop the orginal VM before running the restore script, otherwise it would lead to ip conflicts. 

> **Note:**  Make sure that the VM will ask for DHCP when presented with a new network device.
I tested all my VMs by adding a new network device and see if it got a new ip address from DHCP.  
I use static IP addresses on all my server and I solved it with this (netplan);  
enp6s2 have static ip, but when a new network device being presented aka restorenet it will ask for DHCP.
```
    enp6s2:
      match:
        macaddress: {REDACTED}
      set-name: {REDACTED}
      addresses:
      - 10.10.10.10/24
    restorenet:
      match:
        macaddress: 6A:3F:9C:12:8B:EF //This is the mac address being used by the script
      dhcp4: true
```


---

## 🚀 Features

- Automatically finds the **latest PBS backup** for each VMID  
- Restores to a target storage with a **new unique VMID**  
- Removes old **USB, PCI, and network** devices  
- Adds a fresh NIC with:
  - Fixed MAC  
  - VLAN tag  
  - Custom bridge  
- Automatically reduces RAM to **50% of original** (with a minimum threshold)  
- Boots the VM and **scans for its IP** on an isolated VLAN  
- Sends **success/failure email notifications**  
- Automatically **destroys** the restored VM after testing  
- Full logging to `/var/log/proxmox_vm_restore.log`

---

## 📂 Script Workflow

For each VMID in `SOURCE_VMS`:

1. Identify latest Proxmox Backup Server snapshot  
2. Allocate a new free VMID  
3. Restore VM into designated storage  
4. Strip old hardware (USB / PCI / NIC)  
5. Add new network interface  
6. Adjust memory  
7. Start VM  
8. Detect IP via ping sweep  
9. Send status email  
10. Stop and destroy VM  

---

## 🔧 Configuration

Modify the variables at the top of the script:

| Variable | Description |
|---------|-------------|
| `SOURCE_VMS` | List of VMIDs to restore |
| `TARGET_STORAGE` | Storage where restored VM will be placed |
| `PBS_STORAGE` | Name of PBS remote/storage |
| `NEW_NIC_BRIDGE` | Network bridge to attach |
| `NEW_NIC_VLAN` | VLAN tag |
| `FIXED_MAC` | MAC address assigned to restored VM |
| `VLAN_NET` | Network prefix used for ping scans |
| `IP_RANGE_START` / `IP_RANGE_END` | Host range for ping sweep |
| `LOGFILE` | Log file path |
| `HALF_RAM_MIN` | Minimum allowed RAM when halving |
| `PING_TIMEOUT` | Ping timeout per host |
| `MAX_PING_WAIT` | Maximum wait time for IP detection |
| `SLEEP_INTERVAL` | Time between ping attempts |



# ⚠️Make sure to configure your VLAN and subnet has DHCP enabled before continuing
This script uses as of right now the subnet `192.168.123.0/24` with the range of `192.168.123.200-250`
Make sure to change this to your liking.
The `VLAN_NET` should be without the last octet ex `192.168.111`

This might work with the native VLAN on proxmox and the standard network setup, I havent tested it.

Why use VLAN in the first place.  
The scenario I was struggeling with is that when deploying the restored VM I had no idea what ip address the VM might get and it couldnt ping sweep my usual server net. It needed a separated net so nothing else answered by accident.

```
VLAN_NET="192.168.123"               # /24 network for VLAN
IP_RANGE_START=200                   # Ping sweep from 200
IP_RANGE_END=250
```

---



```bash
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
    qm stop $new_vmid
    echo "Waiting for VM $new_vmid to stop..."
    while true; do
        status=$(qm status $new_vmid 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "stopped" ]]; then
            echo "VM $new_vmid has stopped. Destroying..."
            qm destroy $new_vmid
            break
        else
            echo "VM $new_vmid still running... checking again in 5 seconds."
            sleep 5
        fi
done

}

# =========================
# MAIN LOOP
# =========================
for vmid in "${SOURCE_VMS[@]}"; do
    restore_vm "$vmid"
done

echo "All restores completed!"

```

