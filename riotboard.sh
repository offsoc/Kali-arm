#!/usr/bin/env bash
#
# Kali Linux ARM build-script for RIoTboard (32-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a community script - you will need to generate your own image to use
# More information: https://www.kali.org/docs/arm/riotboard/
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
image_name=${3:-kali-linux-$1-riotboard}

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
base_dir=${repo_dir}/riot-"$1"

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

# Don't add the kernel here.  It depends on flash-kernel which in turn will fail
# when building on amd64, instead we fake a uname/architecture further down and
# actually install the kernel package after compiling it
arm="kali-linux-arm ntpdate"

base="apt-transport-https apt-utils bash-completion console-setup dialog \
e2fsprogs ifupdown initramfs-tools inxi iw man-db mlocate net-tools \
netcat-traditional parted pciutils psmisc rfkill screen tmux unrar usbutils \
vim wget whiptail zerofree"

desktop="kali-desktop-xfce kali-root-login xfonts-terminus xinput \
xserver-xorg-video-fbdev"

tools="kali-linux-default"

services="apache2 atftpd"

extras="alsa-utils bc bison bluez bluez-firmware kali-linux-core \
libnss-systemd libssl-dev triggerhappy"

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

export MALLOC_CHECK_=0 # workaround for LP: #520465

# Enable the use of http proxy in third-stage in case it is enabled
if [ -n "$proxy_url" ]; then
    echo "Acquire::http { Proxy \"$proxy_url\" };" >${work_dir}/etc/apt/apt.conf.d/66proxy

fi

# Fake a uname response so that flash-kernel doesn't bomb out
cat <<'EOF' >${work_dir}/root/fakeuname.c
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <stdio.h>
#include <string.h>

/* Fake uname -r because we are in a chroot:
https://gist.github.com/DamnedFacts/5239593
*/

int uname(struct utsname *buf)
{
    int ret;
    ret = syscall(SYS_uname, buf);
    strcpy(buf->release, "5.7.0-kali1-armmp");
    strcpy(buf->machine, "armv7l");
    return ret;
}
EOF

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
eatmydata apt-get install -y \$aptops --autoremove systemd-timesyncd || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get dist-upgrade -y \$aptops

eatmydata apt-get -y --allow-change-held-packages --purge autoremove

# We do this here, otherwise flash-kernel will fail to run because of not seeing
# the proper kernel version
cd /root && gcc -Wall -shared -o libfakeuname.so fakeuname.c
LD_PRELOAD=/root/libfakeuname.so eatmydata apt-get install -y \$aptops linux-image-armmp u-boot-imx
rm /root/libfakeuname*
cd /

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

# Copy bashrc
cp  /etc/skel/.bashrc /root/.bashrc

# Set a REGDOMAIN.  This needs to be done or wireless doesn't work correctly on the RPi 3B+
sed -i -e 's/REGDOM.*/REGDOMAIN=00/g' /etc/default/crda

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttymxc1 115200 vt100" >> /etc/inittab

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

cat <<EOF >>${work_dir}/etc/udev/links.conf
M   ttymxc1 c   5 1
EOF

cat <<EOF >>${work_dir}/etc/securetty
ttymxc1
EOF

# systemd doesn't seem to be generating the fstab properly for some people, so
# let's create one.  The root partition is added below after img file creation
# so we can add it via uuid
cat <<EOF >${work_dir}/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p1  /boot           vfat    defaults          0       2
EOF

# Define sources.list
cat <<EOF >${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

cd "${base_dir}"
# Mainline u-boot with RIoTboard fixes on top
#wget ftp://ftp.denx.de/pub/u-boot/u-boot-2018.05.tar.bz2
#tar -xf u-boot-2018.05.tar.bz2
#cd u-boot-2018.05
#export CROSS_COMPILE=arm-linux-gnueabihf-
#make riotboard_config
#make -j $(grep -c processor /proc/cpuinfo)
#dd if=u-boot.imx of=$loopdevice bs=1024 seek=1
#cd "${base_dir}"

# Generate the bootscript so that u-boot knows where everything is..
#cat << __EOF__ > "${base_dir}"/kali-$architecture/boot/bootscript
#fdt_high=0xffffffff
#initrd_high=0xffffffff

#kaddr=0x12000000

#loadkernel=load \${dtype} \${disk}:1 \${loadaddr} zImage

#bargs=setenv bootargs console=ttymxc1,115200n8 rootwait root=PARTUUID=\${btpart} net.ifnames=0 rootfstype=$fstype

#loadfdt=load \${dtype} \${disk}:1 0x11000000 \${fdt_file}

#doboot=part uuid \${dtype} \${disk}:2 btpart ; run bargs; if run loadkernel; then echo kernel_loaded ; if run loadfdt; then echo fdt_loaded; bootz \${loadaddr} - 0x11000000 ; else echo fail1 ; fi ; fi ; echo failed to boot
#__EOF__

# Calculate the space to create the image
root_size=$(du -s -B1 ${work_dir} --exclude=${work_dir}/boot | cut -f1)
root_extra=$((${root_size} / 1024 / 1000 * 5 * 1024 / 5))
raw_size=$(($((${free_space} * 1024)) + ${root_extra} + $((${bootsize} * 1024)) + 4096))

# Create the disk and partition it
echo "Creating image file ${image_name}.img"
fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si) "${image_dir}/${image_name}.img"
parted -s "${image_dir}/${image_name}.img" mklabel msdos
parted -s "${image_dir}/${image_name}.img" mkpart primary fat32 1MiB ${bootsize}MiB
parted -s -a minimal "${image_dir}/${image_name}.img" mkpart primary $fstype ${bootsize}MiB 100%

# Set the partition variables
loopdevice=$(losetup -f --show ${repo_dir}/${image_name}.img)
device=$(kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1)
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat -n BOOT ${bootp}

if [[ $fstype == ext4 ]]; then
    features="-O ^64bit,^metadata_csum"

elif [[ $fstype == ext3 ]]; then
    features="-O ^64bit"

fi

mkfs $features -t $fstype -L ROOTFS ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${base_dir}"/root
mount ${rootp} "${base_dir}"/root
mkdir -p "${base_dir}"/root/boot
mount ${bootp} "${base_dir}"/root/boot

# We do this down here to get rid of the build system's resolv.conf after running through the build
echo "nameserver ${nameserver}" >"${work_dir}"/etc/resolv.conf

# Create an fstab so that we don't mount / read-only
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               $fstype    errors=remount-ro 0       1" >>${work_dir}/etc/fstab

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${work_dir}/ ${base_dir}/root/

# Unmount partitions
sync
umount -l ${bootp}
umount -l ${rootp}
kpartx -dv ${loopdevice}
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
echo "Removing temporary build files"
rm -rf "${base_dir}"
