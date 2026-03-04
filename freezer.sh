#!/bin/bash

set -e
LOG_FILE="/var/log/butter-t0aster.log"

if [[ $EUID -eq 0 && -z "$SUDO_USER" ]]; then
    echo "🛑 This script must be run with sudo, not as the root user directly "
    echo "   Please retry with: sudo $0 "
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo "🛑 This script requires sudo privileges "
    echo "   Please retry with: sudo $0 "
    exit 1
fi

echo "🗞  Let's start it all by creating a log file to trap errors "
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

error_handler() {
    echo "🛑 error in freezer.sh - see $LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        cat "$LOG_FILE"
    fi
    exit 1
}

trap 'error_handler' ERR
exec > >(tee -a "$LOG_FILE") 2>&1

echo "     👉 plug in a USB drive right now to format it and label it 'backups' "
echo ""
echo "     ❗️ this will wipe the drive and all its data ❗️"
echo ""
read -p "     Is the USB drive plugged in❓ (y/n): " plugged

if [[ "$plugged" == "y" || "$plugged" == "Y" ]]; then
    mapfile -t USB_CANDIDATES < <(lsblk -dn -o NAME,RM,TYPE,SIZE | awk '$2==1 && $3=="disk" {print $1","$4}')

    if [ "${#USB_CANDIDATES[@]}" -eq 0 ]; then
        echo "   ⚠️ no removable USB disk detected - skipping "
    else
        echo "   🔎 removable USB disks detected:"
        for i in "${!USB_CANDIDATES[@]}"; do
            CANDIDATE_NAME=$(echo "${USB_CANDIDATES[$i]}" | cut -d',' -f1)
            CANDIDATE_SIZE=$(echo "${USB_CANDIDATES[$i]}" | cut -d',' -f2)
            echo "      [$((i+1))] /dev/$CANDIDATE_NAME ($CANDIDATE_SIZE)"
        done

        read -p "      choose disk number to format as 'backups' (or press Enter to cancel): " selected
        if [[ -n "$selected" && "$selected" =~ ^[0-9]+$ && "$selected" -ge 1 && "$selected" -le ${#USB_CANDIDATES[@]} ]]; then
            USB_NAME=$(echo "${USB_CANDIDATES[$((selected-1))]}" | cut -d',' -f1)
            USB_SIZE=$(echo "${USB_CANDIDATES[$((selected-1))]}" | cut -d',' -f2)
            echo "   🔎 selected USB drive: '$USB_NAME' size: '$USB_SIZE' "
            read -p "      use '$USB_NAME' as 'backups'❓ (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                echo "   🆑  formatting /dev/$USB_NAME as Btrfs with label 'backups' "
                sudo parted /dev/$USB_NAME --script mklabel gpt mkpart primary 0% 100% || { echo "🛑 failed to partition " >&2; exit 1; }
                sudo mkfs.btrfs -f -L "backups" /dev/${USB_NAME}1 || { echo "🛑 failed to format " >&2; exit 1; }
                echo "   ✅ USB drive formatted as 'backups' "
                echo "   🔌 plug it in at anytime to trigger automatic backups 🛟 "
            else
                echo "   ⏭ skipping USB format - prepare a 'backups' drive later "
            fi
        else
            echo "   ⏭ no disk selected - skipping "
        fi
    fi
fi

echo "✅ scripts are complete for good "
echo ""
echo "   You might want to have a look at our Debian firstbOOt script 🥾 "
echo "   to leverage the security and pleasure of use of your Debian server. "
echo "   Have a look at: https://github.com/lerez0/firstb00t "
