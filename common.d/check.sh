#!/usr/bin/env bash

# Check EUID=0 you can run any binary as root.
if [[ $EUID -ne 0 ]]; then
  log "This script must be run as root or have super user permissions" $red
  log "Use: sudo $0 ${1:-2.0} ${2:-kali}" $green
  exit 1
fi

# Pass version number
# if [[ $# -eq 0 ]] ; then
#   log "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali" $yellow
#   exit 1
# fi

# Check exist bsp directory.
if [ ! -e "bsp" ]; then
  log "Error: missing bsp directory structure" $red
  log "Please clone the full repository ${kaligit}/build-scripts/kali-arm" $green
  exit 255
fi

# Check directory build
if [ -e "${basedir}" ]; then
  log "${basedir} directory exists, will not continue" $red
  exit 1
elif [[ ${current_dir} =~ [[:space:]] ]]; then
  log "The directory "\"${current_dir}"\" contains whitespace. Not supported." $red
  exit 1
else
  log "The basedir thinks it is: ${basedir}" $bold
  mkdir -p ${basedir}
fi

# Detect architecture
case ${architecture} in
  arm64)
    qemu_bin="/usr/bin/qemu-aarch64-static"
    lib_arch="aarch64-linux-gnu" ;;
  armhf)
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabihf" ;;
  armel)
    qemu_bin="/usr/bin/qemu-arm-static"
    lib_arch="arm-linux-gnueabi" ;;
esac