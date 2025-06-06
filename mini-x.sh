#!/usr/bin/env bash
#
# Kali Linux ARM build-script for Mini-X (32-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a community script - you will need to generate your own image to use
# More information: https://www.kali.org/docs/arm/mini-x/
#

# Stop on error
set -e

# Uncomment to activate debug
# debug=true

if [ "$debug" = true ]; then
    exec > >(tee -a -i "${0%.*}.log") 2>&1
    set -x

fi

# Architecture
architecture=${architecture:-"armhf"}

# Generate a random machine name to be used
machine=$(
    tr -cd 'A-Za-z0-9' </dev/urandom | head -c16
    echo
)

# Custom hostname variable
hostname=${2:-kali}

# Custom image file name variable - MUST NOT include .img at the end
image_name=${3:-kali-linux-$1-mini-x}

# Suite to use, valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
suite=${suite:-"kali-rolling"}

# Free space rootfs in MiB
free_space="300"

# /boot partition in MiB
bootsize="128"

# Select compression, xz or none
compress="xz"

# Choose filesystem format to format (ext3 or ext4)
fstype="ext3"

# If you have your own preferred mirrors, set them here
mirror=${mirror:-"http://http.kali.org/kali"}

# GitLab URL Kali repository
kaligit="https://gitlab.com/kalilinux"

# GitHub raw URL
githubraw="https://raw.githubusercontent.com"

# Check EUID=0 you can run any binary as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root or have super user permissions" >&2
    echo "Use: sudo $0 ${1:-2.0} ${2:-kali}" >&2

    exit 1

fi

# Pass version number
if [[ $# -eq 0 ]]; then
    echo "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali" >&2

    exit 0

fi

# Check exist bsp directory
if [ ! -e "bsp" ]; then
    echo "Error: missing bsp directory structure" >&2
    echo "Please clone the full repository ${kaligit}/build-scripts/kali-arm" >&2

    exit 255

fi

# Current directory
repo_dir="$(pwd)"

# Base directory
base_dir=${repo_dir}/minix-"$1"

# Working directory
work_dir="${base_dir}/kali-${architecture}"

# Check directory build
if [ -e "${base_dir}" ]; then
    echo "${base_dir} directory exists, will not continue" >&2

    exit 1

elif [[ ${repo_dir} =~ [[:space:]] ]]; then
    echo "The directory "\"${repo_dir}"\" contains whitespace. Not supported." >&2

    exit 1

else
    echo "The base_dir thinks it is: ${base_dir}"
    mkdir -p ${base_dir}

fi

components="main,contrib,non-free"

arm="abootimg cgpt fake-hwclock ntpdate u-boot-tools vboot-kernel-utils \
vboot-utils"

base="apt-utils e2fsprogs firmware-atheros firmware-libertas firmware-linux \
firmware-realtek ifupdown initramfs-tools kali-defaults kali-menu \
linux-image-armmp parted sudo u-boot-menu u-boot-sunxi usbutils"

desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito \
kali-desktop-xfce kali-menu kali-root-login lightdm network-manager \
network-manager-gnome xfce4 xserver-xorg-video-fbdev"

tools="aircrack-ng ethtool hydra john libnfc-bin mfoc nmap passing-the-hash \
sqlmap usbutils winexe wireshark"

services="apache2 openssh-server"

extras="firefox-esr wpasupplicant xfce4-terminal"

packages="${arm} ${base} ${services}"

# Automatic configuration to use an http proxy, such as apt-cacher-ng
# You can turn off automatic settings by uncommenting apt_cacher=off
# apt_cacher=off
# By default the proxy settings are local, but you can define an external proxy
# proxy_url="http://external.intranet.local"
apt_cacher=${apt_cacher:-"$(lsof -i :3142 | cut -d ' ' -f3 | uniq | sed '/^\s*$/d')"}

if [ -n "$proxy_url" ]; then
    export http_proxy=$proxy_url

elif [ "$apt_cacher" = "apt-cacher-ng" ]; then
    if [ -z "$proxy_url" ]; then
        proxy_url=${proxy_url:-"http://127.0.0.1:3142/"}
        export http_proxy=$proxy_url

    fi
fi

# Detect architecture
if [[ "${architecture}" == "arm64" ]]; then
    qemu_bin="/usr/bin/qemu-aarch64-static"
    lib_arch="aarch64-linux-gnu"

elif [[ "${architecture}" == "armhf" ]]; then
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabihf"

elif [[ "${architecture}" == "armel" ]]; then
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabi"

fi

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want
eatmydata debootstrap --foreign \
--keyring=/usr/share/keyrings/kali-archive-keyring.gpg \
--include=kali-archive-keyring,eatmydata \
--components=${components} \
--arch ${architecture} ${suite} ${work_dir} http://http.kali.org/kali

# systemd-nspawn environment
systemd-nspawn_exec() {
    LANG=C systemd-nspawn -q --bind-ro ${qemu_bin} -M ${machine} -D ${work_dir} "$@"
}

# We need to manually extract eatmydata to use it for the second stage
for archive in ${work_dir}/var/cache/apt/archives/*eatmydata*.deb; do
    dpkg-deb --fsys-tarfile "$archive" >${work_dir}/eatmydata
    tar -xkf ${work_dir}/eatmydata -C ${work_dir}
    rm -f ${work_dir}/eatmydata

done

# Prepare dpkg to use eatmydata
systemd-nspawn_exec dpkg-divert --divert /usr/bin/dpkg-eatmydata --rename --add /usr/bin/dpkg

cat >${work_dir}/usr/bin/dpkg <<EOF
#!/bin/sh
if [ -e /usr/lib/${lib_arch}/libeatmydata.so ]; then
    [ -n "\${LD_PRELOAD}" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"

fi

for so in /usr/lib/${lib_arch}/libeatmydata.so; do
    [ -n "\$LD_PRELOAD" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"

done

export LD_PRELOAD
exec "\$0-eatmydata" --force-unsafe-io "\$@"
EOF

chmod 0755 ${work_dir}/usr/bin/dpkg

# debootstrap second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage

cat <<EOF >${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Set hostname
echo "${hostname}" >${work_dir}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat <<EOF >${work_dir}/etc/hosts
127.0.0.1       ${hostname} localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Disable IPv6
cat <<EOF >${work_dir}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
EOF

cat <<EOF >${work_dir}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# DNS server
echo "nameserver ${nameserver}" >"${work_dir}"/etc/resolv.conf

# Copy directory bsp into build dir
cp -rp bsp ${work_dir}

# Workaround for LP: #520465
export MALLOC_CHECK_=0

# Enable the use of http proxy in third-stage in case it is enabled
if [ -n "$proxy_url" ]; then
    echo "Acquire::http { Proxy \"$proxy_url\" };" >${work_dir}/etc/apt/apt.conf.d/66proxy

fi

# Third stage
cat <<EOF >${work_dir}/third-stage
#!/bin/bash -e
export DEBIAN_FRONTEND=noninteractive

eatmydata apt-get update

eatmydata apt-get -y install binutils ca-certificates console-common git initramfs-tools less locales nano u-boot-tools

# Create kali user with kali password... but first, we need to manually make some groups because they don't yet exist..
# This mirrors what we have on a pre-installed VM, until the script works properly to allow end users to set up their own... user
# However we leave off floppy, because who a) still uses them, and b) attaches them to an SBC!?
# And since a lot of these have serial devices of some sort, dialout is added as well
# scanner, lpadmin and bluetooth have to be added manually because they don't
# yet exist in /etc/group at this point
groupadd -r -g 118 bluetooth
groupadd -r -g 113 lpadmin
groupadd -r -g 122 scanner
groupadd -g 1000 kali

useradd -m -u 1000 -g 1000 -G sudo,audio,bluetooth,cdrom,dialout,dip,lpadmin,netdev,plugdev,scanner,video,kali -s /bin/bash kali
echo "kali:kali" | chpasswd

aptops="--allow-change-held-packages -o dpkg::options::=--force-confnew -o Acquire::Retries=3"

# This looks weird, but we do it twice because every so often, there's a failure to download from the mirror
# So to workaround it, we attempt to install them twice
eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get dist-upgrade -y \$aptops

eatmydata apt-get -y --allow-change-held-packages --purge autoremove

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

# Copy all services
cp -p /bsp/services/all/*.service /etc/systemd/system/

# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot
systemctl enable smi-hack

# Enable sshd
systemctl enable ssh

# Allow users to use NetworkManager
install -m644 /bsp/polkit/10-networkmanager.rules /etc/polkit-1/rules.d/

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# We replace the u-boot menu defaults here so we can make sure the build system doesn't poison it
# We use _EOF_ so that the third-stage script doesn't end prematurely
cat << '_EOF_' > /etc/default/u-boot
U_BOOT_PARAMETERS="console=ttyS0,115200 console=tty1 root=/dev/mmcblk0p1 rootwait panic=10 rw rootfstype=$fstype net.ifnames=0"
_EOF_

# Copy over the default bashrc
cp /etc/skel/.bashrc /root/.bashrc

# Set a REGDOMAIN.  This needs to be done or wireless doesn't work correctly on the RPi 3B+
sed -i -e 's/REGDOM.*/REGDOMAIN=00/g' /etc/default/crda

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt100" >> /etc/inittab

# Try and make the console a bit nicer
# Set the terminus font for a bit nicer display
sed -i -e 's/FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup
sed -i -e 's/FONTSIZE=.*/FONTSIZE="6x12"/' /etc/default/console-setup

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/usr/lib/systemd/system/networking.service"

rm -f /usr/bin/dpkg
EOF

# Run third stage
chmod 0755 ${work_dir}/third-stage
systemd-nspawn_exec /third-stage

# Clean up eatmydata
systemd-nspawn_exec dpkg-divert --remove --rename /usr/bin/dpkg

# Clean system
systemd-nspawn_exec <<'EOF'
rm -f /0
rm -rf /bsp
fc-cache -frs
rm -rf /tmp/*
rm -rf /etc/*-
rm -rf /hs_err*
rm -rf /userland
rm -rf /opt/vc/src
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/dpkg/*-old
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/debconf/*.data-old
for logs in $(find /var/log -type f); do > $logs; done
history -c
EOF

# Disable the use of http proxy in case it is enabled
if [ -n "$proxy_url" ]; then
    unset http_proxy
    rm -rf ${work_dir}/etc/apt/apt.conf.d/66proxy

fi

# Mirror & suite replacement
if [[ ! -z "${4}" || ! -z "${5}" ]]; then
    mirror=${4}
    suite=${5}

fi

# Define sources.list
cat <<EOF >${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Build system will insert it's root filesystem into the extlinux.conf file so
# we sed it out, this only affects build time, not upgrading the kernel on the
# device itself
sed -i -e 's/append.*/append console=ttyS0,115200 console=tty1 root=\/dev\/mmcblk0p1 rootwait panic=10 rw rootfstype=$fstype net.ifnames=0/g' ${work_dir}/boot/extlinux/extlinux.conf

# Calculate the space to create the image
root_size=$(du -s -B1 ${work_dir} --exclude=${work_dir}/boot | cut -f1)
root_extra=$((${root_size} / 1024 / 1000 * 5 * 1024 / 5))
raw_size=$(($((${free_space} * 1024)) + ${root_extra} + $((${bootsize} * 1024)) + 4096))

# Create the disk and partition it
echo "Creating image file ${image_name}.img"
fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si) "${image_dir}/${image_name}.img"
parted -s "${image_dir}/${image_name}.img" mklabel msdos
parted -s -a minimal "${image_dir}/${image_name}.img" mkpart primary $fstype 4MiB 100%

# Set the partition variables
loopdevice=$(losetup -f --show ${repo_dir}/${image_name}.img)
device=$(kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1)
sleep 5
device="/dev/mapper/${device}"
rootp=${device}p1

if [[ $fstype == ext4 ]]; then
    features="-O ^64bit,^metadata_csum"

elif [[ $fstype == ext3 ]]; then
    features="-O ^64bit"

fi

mkfs $features -t $fstype -L ROOTFS ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${base_dir}"/root
mount ${rootp} "${base_dir}"/root

# We do this down here to get rid of the build system's resolv.conf after running through the build
echo "nameserver ${nameserver}" >"${work_dir}"/etc/resolv.conf

# Create an fstab so that we don't mount / read-only
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               $fstype    errors=remount-ro 0       1" >>${work_dir}/etc/fstab

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${work_dir}/ ${base_dir}/root/

# Unmount partitions
sync
umount ${rootp}
kpartx -dv ${loopdevice}

# Write bootloader to imagefile
dd if=${work_dir}/usr/lib/u-boot/Mini-X/u-boot-sunxi-with-spl.bin of=${loopdevice} bs=1024 seek=8

losetup -d ${loopdevice}

# Limit CPU function
limit_cpu() {
    # Random name group
    rand=$(
        tr -cd 'A-Za-z0-9' </dev/urandom | head -c4
        echo
    )

    cgcreate -g cpu:/cpulimit-${rand}                # Name of group cpulimit
    cgset -r cpu.shares=800 cpulimit-${rand}         # Max 1024
    cgset -r cpu.cfs_quota_us=80000 cpulimit-${rand} # Max 100000

    # Retry command
    local n=1
    local max=5
    local delay=2

    while true; do
        cgexec -g cpu:cpulimit-${rand} "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                echo -e "\e[31m Command failed. Attempt $n/$max \033[0m"

                sleep $delay

            else
                echo "The command has failed after $n attempts."

                break

            fi
        }

    done
}

if [ $compress = xz ]; then
    if [ $(arch) == 'x86_64' ]; then
        echo "Compressing ${image_name}.img"

        # cpu_cores = Number of cores to use
        [ $(nproc) -lt 3 ] || cpu_cores=3

        # -p Nº cpu cores use
        limit_cpu pixz -p ${cpu_cores:-2} "${image_dir}/${image_name}.img"

        chmod 0644 ${repo_dir}/${image_name}.img.xz

    fi

else
    chmod 0644 "${image_dir}/${image_name}.img"

fi

# Clean up all the temporary build stuff and remove the directories
# Comment this out to keep things around if you want to see what may have gone wrong
echo "Cleaning up temporary build system"
rm -rf "${base_dir}"
