#!/usr/bin/env bash
#
# Kali Linux ARM build-script for Raspberry Pi 5 (64-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a supported device - which you can find pre-generated images on: https://www.kali.org/get-kali/
# More information: https://www.kali.org/docs/arm/raspberry-pi-5/
#

# Hardware model
hw_model=${hw_model:-"raspberry-pi5"}

# Architecture
architecture=${architecture:-"arm64"}

# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)
desktop=${desktop:-"xfce"}

# Load default base_image configs
source ./common.d/base_image.sh

# Network configs
basic_network
#add_interface eth0

# Third stage
cat <<EOF >> "${work_dir}"/third-stage
status_stage3 'Copy rpi services'
cp -p /bsp/services/rpi/*.service /etc/systemd/system/

status_stage3 'Copy xorg config snippet'
mkdir -p /etc/X11/xorg.conf.d/
install -m644 /bsp/xorg/99-vc4.conf /etc/X11/xorg.conf.d/

status_stage3 'Copy script for handling wpa_supplicant file'
install -m755 /bsp/scripts/copy-user-wpasupplicant.sh /usr/bin/

status_stage3 'Enable copying of user wpa_supplicant.conf file'
systemctl enable copy-user-wpasupplicant

status_stage3 'Enabling ssh by putting ssh or ssh.txt file in /boot'
systemctl enable enable-ssh

status_stage3 'Disable haveged daemon'
systemctl disable haveged

status_stage3 'Fixup wireless-regdb signature'
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream

#status_stage3 'Enable hciuart and bluetooth'
#systemctl enable hciuart
#systemctl enable bluetooth

status_stage3 'Build RaspberryPi utils'
git clone --quiet https://github.com/raspberrypi/utils /usr/src/utils
cd /usr/src/utils/
# Without gcc/make, this will fail on slim images.
sudo apt install -y cmake device-tree-compiler libfdt-dev build-essential
cmake .
make
make install
EOF

# Run third stage
include third_stage

# Kernel and bootloader installation
status 'Clone bootloader'
git clone --quiet --depth 1 https://github.com/raspberrypi/firmware.git "${work_dir}"/rpi-firmware
cp -rf "${work_dir}"/rpi-firmware/boot/* "${work_dir}"/boot/

status 'Clone and build kernel'
git clone --quiet --depth 1 https://github.com/raspberrypi/linux -b rpi-6.1.y "${work_dir}"/usr/src/kernel
cd "${work_dir}"/usr/src/kernel
patch -p1 --no-backup-if-mismatch <${repo_dir}/patches/kali-wifi-injection-6.1.patch
patch -p1 --no-backup-if-mismatch <${repo_dir}/patches/rpi5/0001-net-wireless-brcmfmac-Add-nexmon-support.patch
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH="${work_dir}"
mkdir -p "${work_dir}"/boot/overlays
cp arch/arm64/boot/Image "${work_dir}"/boot/kernel8.img
cp arch/arm/boot/dts/overlays/*.dtb* "${work_dir}"/boot/overlays/
cp arch/arm/boot/dts/overlays/README "${work_dir}"/boot/overlays/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- mrproper
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls "${work_dir}"/lib/modules/)
cd "${work_dir}"/lib/modules/"${kernver}"
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source
cd "${repo_dir}"

# Firmware needed for the wifi
cd "${work_dir}"
status 'Clone Wi-Fi/Bluetooth firmware'
git clone --quiet --depth 1 https://github.com/rpi-distro/firmware-nonfree
cd firmware-nonfree/debian/config/brcm80211
rsync -HPaz brcm "${work_dir}"/lib/firmware/
rsync -HPaz cypress "${work_dir}"/lib/firmware/
cd "${work_dir}"/lib/firmware/cypress
ln -sf cyfmac43455-sdio-standard.bin cyfmac43455-sdio.bin
rm -rf "${work_dir}"/firmware-nonfree

# bluetooth firmware
wget -q 'https://github.com/RPi-Distro/bluez-firmware/raw/bookworm/debian/firmware/broadcom/BCM4345C0.hcd' -O "${work_dir}"/lib/firmware/brcm/BCM4345C0.hcd

cd "${repo_dir}/"

# Clean system
include clean_system

# Calculate the space to create the image and create
make_image

# Create the disk partitions
status "Create the disk partitions"
parted -s "${image_dir}/${image_name}.img" mklabel msdos
parted -s "${image_dir}/${image_name}.img" mkpart primary fat32 1MiB "${bootsize}"MiB
parted -s -a minimal "${image_dir}/${image_name}.img" mkpart primary "$fstype" "${bootsize}"MiB 100%

# Set the partition variables
make_loop

# Create file systems
mkfs_partitions

# Make fstab
make_fstab

# Configure Raspberry Pi firmware (before rsync)
include rpi_firmware
# We need to add in a directive so that the Pi5 knows which kernel to use.
sed -i -e '79 i [pi5]' "${work_dir}"/boot/config.txt
sed -i -e '80 i kernel=kernel8.img' "${work_dir}"/boot/config.txt


# Create the dirs for the partitions and mount them
status "Create the dirs for the partitions and mount them"
mkdir -p "${base_dir}"/root/

if [[ $fstype == ext4 ]]; then
    mount -t ext4 -o noatime,data=writeback,barrier=0 "${rootp}" "${base_dir}"/root

else
    mount "${rootp}" "${base_dir}"/root

fi

mkdir -p "${base_dir}"/root/boot
mount "${bootp}" "${base_dir}"/root/boot

status "Rsyncing rootfs into image file"
rsync -HPavz -q --exclude boot "${work_dir}"/ "${base_dir}"/root/
sync

status "Rsyncing boot into image file (/boot)"
rsync -rtx -q "${work_dir}"/boot "${base_dir}"/root
sync

# Load default finish_image configs
include finish_image
