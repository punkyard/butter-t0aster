#!/bin/bash

set -e

# disclaimer
echo ""
echo ""
echo ""
echo "========================================================="
echo "                                                         "
echo "  🌀 This sm00th script will make a Debian 12 server     "
echo "      with butter file system (BTRFS) ready for:         "
echo "       📸 /root partition snapshots                      "
echo "       🛟  automatic backups of /home partition          "
echo "       💈 preserving SSDs lifespan                       "
echo "       😴 stay active when laptop lid is closed          "
echo "                                                         "
echo "========================================================="
echo "                                                         "
echo "  👀 if any step fails, the script will exit             "
echo "  🗞 and logs will be printed for review from:           "
echo "      👉 $LOG_FILE                                       "
echo "                                                         "
echo "========================================================="
echo ""
echo ""
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "  🗞 Let's start it all by creating a log file to trap errors"
LOG_FILE="/var/log/butter-t0aster.log" # define log file
error_handler() {
    echo "🛑 error occurred - exit script"
    echo "======== BEGIN LOGS ========"
    cat "$LOG_FILE" # print the log file
    echo "========  END LOGS  ========"
    exit 1
}

trap error_handler ERR # set up error trap
exec > >(tee -a "$LOG_FILE") 2>&1 # redirect outputs to log file

if [[ $(/usr/bin/id -u) -ne 0 ]]; then # check for root privilege
    echo "  🛑 this script must be run by a sudo user with root permissions"
    echo "     please retry"
    exit 1
fi
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣ create mount points 🪄"
ROOT_MOUNT_POINT="/mnt" # print mount point for /root
HOME_MOUNT_POINT="/mnt/home" # print mount point for /home

mkdir -p "$ROOT_MOUNT_POINT" # ensure /root mount point exists
if [ $? -ne 0 ]; then
    echo "    🛑 ERROR could not create $ROOT_MOUNT_POINT"
    exit 1
fi

mkdir -p "$HOME_MOUNT_POINT" # ensure /home mount point exists
if [ $? -ne 0 ]; then
    echo "    🛑 ERROR could not create $HOME_MOUNT_POINT"
    exit 1
fi

echo "    ✅ mount points created successfully"
echo ""

echo "    🔎 check current partition layout"
lsblk -o NAME,FSTYPE,MOUNTPOINT | tee -a "$LOG_FILE"
echo ""

echo "    🔎 look for BTRFS subvolumes"
btrfs subvolume list / || echo "No subvolumes detected on /"
btrfs subvolume list /home || echo "No subvolumes detected on /home"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 2️⃣ detecte /root and /home partitions ⏫"
DISK_ROOT=$(findmnt -n -o SOURCE -T / | awk -F'[' '{print $1}')
DISK_HOME=$(findmnt -n -o SOURCE -T /home | awk -F'[' '{print $1}')
echo ""

if [[ -z "$DISK_ROOT" || -z "$DISK_HOME" ]]; then
    echo "    🛑 ERROR /root and /home partitions not detected"
    exit 1
fi

echo "    ✅ detected /root partition: $DISK_ROOT"
echo "    ✅ detected /home partition: $DISK_HOME"
echo ""

read -p "  Are these partitions correct? (y/n): " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Partition detection aborted."; exit 1; }

HOME_PERMISSIONS=$(stat -c "%a" /home)
echo "💡 Initial /home permissions saved: $HOME_PERMISSIONS"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 3️⃣ ensure mount points exist 🏗️"
mkdir -p /mnt
mkdir -p /mnt/home
echo "    ✅ mount points created"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 4️⃣ ensure BTRFS subvolumes exist 🧈"
mount "$DISK_HOME" /mnt/home || { echo "🛑 ERROR failed to mount /home temporarily"; exit 1; }

if ! btrfs subvolume list /mnt/home | grep -q "@home"; then
    echo "   @home subvolume not found. Creating it..."
    btrfs subvolume create /mnt/home/@home
fi

umount /mnt/home
echo "    ✅ BTRFS subvolume @home OK"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 5️⃣ mount /root and /home in optimized BTRFS subvolumes ⏫"
mount -o subvol=@rootfs "$DISK_ROOT" /mnt || { echo "🛑 ERROR failed to mount /root"; exit 1; }
mount -o subvol=@home "$DISK_HOME" /mnt/home || { echo "🛑 ERROR failed to mount /home"; exit 1; }

chmod "$HOME_PERMISSIONS" /mnt/home
echo "    🔐 /home permissions restored to: $HOME_PERMISSIONS"
echo "    ✅ /root and /home partitions mounted successfully"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 6️⃣ configure /etc/fstab for persistence 💾"
UUID_ROOT=$(blkid -s UUID -o value "$DISK_ROOT")
UUID_HOME=$(blkid -s UUID -o value "$DISK_HOME")
sudo sed -i "/\/home.*btrfs.*/d" /etc/fstab # remove incorrect entries
sudo sed -i "/\/.*btrfs.*/d" /etc/fstab

echo "    📝 write fstab entries"
echo "UUID=$UUID_ROOT /      btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@rootfs 0 1" | tee -a /etc/fstab
echo "UUID=$UUID_HOME /home  btrfs defaults,noatime,compress=zstd,ssd,space_cache=v2,subvol=@home  0 2" | tee -a /etc/fstab
echo "    ✅ /etc/fstab updated successfully."

echo "    🔄 remount /root and /home"
mount -o remount,compress=zstd "$DISK_ROOT" /
mount -o remount,compress=zstd "$DISK_HOME" /home
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 7️⃣ install SNAPPER and create '0 initial snapshot' for /root (to keep for ever) 📸"
apt-get update # update packages lists
apt-get install -y snapper snapper-support grub-btrfs
snapper -c root create-config / # configure SNAPPER for /root

echo "    check /.snapshots BTRFS subvolume state"
if ! btrfs subvolume list / | grep -q "path /.snapshots"; then
    echo "    📂 create BTRFS subvolume for SNAPPER"
    btrfs subvolume create /.snapshots
fi

echo "    configuring snapshot policies"
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_CLEANUP=yes"
snapper -c root set-config "TIMELINE_MIN_AGE=1800"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=0"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=2"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=2"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"

echo "    enable SNAPPER automatic snapshots"
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer

snapper -c root create --description "00 initial server snapshot"
echo "    📸 initial snapshot for /root created"

echo "    configuring GRUB-BTRFS for boot snapshots"
systemctl enable --now grub-btrfsd.service
update-grub

echo "    To list previous snapshots, run:"
echo "       👉 sudo snapper -c root list"
echo "    To rollback to a previous snapshot, use:"
echo "       👉 sudo snapper rollback <snapshot_number>"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 8️⃣ install ZRAM tools to compress swap in RAM 🗜"
apt-get install zram-tools -y # install ZRAM tools

echo "    configure ZRAM with 25% of RAM and compression"
cat <<EOF > /etc/default/zramswap # configure ZRAM settings
ZRAM_PERCENTAGE=25
COMPRESSION_ALGO=zstd
PRIORITY=10
EOF

echo "    start ZRAM on system boot"
systemctl start zramswap # start ZRAM now
systemctl enable zramswap # start ZRAM on boot
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 9️⃣ set swappiness to 10 📝"
sysctl vm.swappiness=10 # set swappiness value
echo "vm.swappiness=10" >> /etc/sysctl.conf  # make swappiness persistent
sysctl vm.swappiness=10 # apply change now
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣0️⃣ plan SSD trim once a week 💈"
echo "0 0 * * 0 fstrim /" | tee -a /etc/cron.d/ssd_trim # schedule SSD trim with a cron job
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣1️⃣ set up automatic backups when 'backups' USB is inserted 🛟"
echo "      📝 create backup script"
BACKUP_SCRIPT='/usr/local/bin/auto_backup.sh'
cat <<EOF > $BACKUP_SCRIPT # write backup script
#!/bin/bash
TARGET="/media/backups"
LOG_FILE="/var/log/backup.log"
mkdir -p \$TARGET # create backup target
rsync -aAXv --delete --exclude={"/lost+found/*","/mnt/*","/media/*","/var/cache/*","/proc/*","/tmp/*","/dev/*","/run/*","/sys/*"} / \$TARGET/ >> \$LOG_FILE 2>&1 # perform backup
echo "      🛟 backup completed at \$(date)" >> \$LOG_FILE # log completion timestamp
EOF
chmod +x $BACKUP_SCRIPT # make backup script executable

echo "         set udev rule for USB detection"
UDEV_RULE='/etc/udev/rules.d/99-backup.rules'
cat <<EOF > $UDEV_RULE # create udev rule
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="backups", RUN+="$BACKUP_SCRIPT"
EOF
udevadm control --reload-rules && udevadm trigger
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣2️⃣ disable sleep when lid is closed (in logind.conf) 💡"
while true; do
    read -p "     Do you want the laptop to remain active when the lid is closed? (y/n): " lid_response
    case $lid_response in
        [yYnN]) break ;;
        *) echo "     answer 'y' or 'n'" ;;
    esac
done

if [[ "$lid_response" == "y" || "$lid_response" == "Y" ]]; then
  echo "     configure the laptop to remain active with the lid closed"
  cat <<EOF | sudo tee /etc/systemd/logind.conf
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
EOF
  sudo systemctl restart systemd-logind
else
  echo "     skip closed lid configuration"
fi
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣3️⃣ disable suspend and hibernation 😴"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do # ignore sleep triggers
    systemctl mask "$target"
    systemctl disable "$target"
done
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣4️⃣ take automatic snapshots before automatic security upgrades 📸"
echo "     if automatic security updates have been activated during OS install"
if dpkg -l | grep -q unattended-upgrades; then
  echo "     configure snapshot hook for unattended-upgrades"
  echo 'DPkg::Pre-Invoke {"btrfs subvolume snapshot / /.snapshots/pre-update-$(date +%Y%m%d%H%M%S)";};' | sudo tee /etc/apt/apt.conf.d/99-btrfs-snapshot-before-upgrade > /dev/null
else
  echo "     automatic security upgrades are not installed; skip"
fi
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣5️⃣ create '01 optimised server snapshot' 📸"
snapper -c root create --description "01 optimised server snapshot"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo " 1️⃣6️⃣ create post-reboot system check 🧰"
echo "      This script will run a series of tests after reboot"
echo "       to ensure the butter-t0aster script ran fine"

cat <<EOF > /usr/local/bin/post-reboot-system-check.sh
#!/bin/bash
echo "     🧰 run post-reboot system check"

echo "🔎 check BTRFS subvolumes"
btrfs subvolume list /
echo ""

echo "🔎 check fstab entries"
grep btrfs /etc/fstab
echo ""

echo "🔎 check SNAPPER configurations"
snapper -c root list
echo ""

echo "🔎 check GRUB-BTRFS detection"
ls /boot/grub/
echo ""

echo "🔎 check for failed services"
systemctl --failed
echo ""

echo "🔎 check disk usage"
df -h
echo ""

echo "✅ post-reboot system check complete - remove script"
rm -- "$0"
EOF
chmod +x /usr/local/bin/post-reboot-system-check.sh
echo ""

cat <<EOF > /etc/systemd/system/post-reboot-system-check.service
[Unit]
Description=Run post-reboot system checks
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/post-reboot-system-check.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
systemctl enable post-reboot-system-check.service
echo "     ✅ post-reboot script will be run once after reboot"
echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

read -p "🏁 setup is complete - reboot now? (y/n): " reboot_response
if [[ "$reboot_response" == "y" ]]; then
  reboot
else
  echo ""
  echo "🔃 reboot is required to apply changes"
  echo "📸 to manually trigger a snapshot at any time, run:"
  echo "👉 sudo btrfs subvolume snapshot / /.snapshots/manual-$(date +%Y%m%d%H%M%S)"
  echo "🗞 logs are available at: $LOG_FILE"
  echo ""
  echo "   made with ⏳ by le rez0.net"
  echo "   please return experience and issues at https://github.com/lerez0"
  echo ""
fi
