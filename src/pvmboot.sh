#!/bin/bash
###############################################################################
#     parabola-vmbootstrap -- create and start parabola virtual machines      #
#                                                                             #
#     Copyright (C) 2017 - 2019  Andreas Grapentin                            #
#                                                                             #
#     This program is free software: you can redistribute it and/or modify    #
#     it under the terms of the GNU General Public License as published by    #
#     the Free Software Foundation, either version 3 of the License, or       #
#     (at your option) any later version.                                     #
#                                                                             #
#     This program is distributed in the hope that it will be useful,         #
#     but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#     GNU General Public License for more details.                            #
#                                                                             #
#     You should have received a copy of the GNU General Public License       #
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
###############################################################################

# shellcheck source=/usr/lib/libretools/messages.sh
. "$(librelib messages)"

usage() {
  print "usage: %s [-h] IMG [ARG]..." "${0##*/}"
  prose "Determine the architecture of IMG and boot it using qemu. IMG is assumed
         to be a valid, raw-formatted parabola virtual machine image, ideally
         created using pvmbootstrap. The started instances are assigned 1GiB of
         RAM and one SMP core."
  echo
  prose "When a graphical desktop environment is available, start the machine
         normally, otherwise append -nographic to the qemu options. This behavior
         can be forced by unsetting DISPLAY manually, for example through:"
  echo
  echo  "  DISPLAY= ${0##*/} IMG ..."
  echo
  prose "When the architecture of IMG is compatible with the host architecture,
         append -enable-kvm to the qemu arguments."
  echo
  prose "Further arguments provided after IMG will be passed unmodified to the
         qemu invocation. This can be used to allocate more resources to the virtual
         machine, for example:"
  echo
  echo  "  ${0##*/} IMG -m 2G -smp 2"
  echo
  echo  "Supported options:"
  echo  "  -h   Display this help and exit"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  " <https://git.parabola.nu/~oaken-source/parabola-vmbootstrap.git>"
}

pvm_mount() {
  if ! file "$1" | grep -q ' DOS/MBR '; then
    error "$1: does not seem to be a raw qemu image."
    return "$EXIT_FAILURE"
  fi

  trap 'pvm_umount' INT TERM EXIT

  workdir="$(mktemp -d -t pvm-XXXXXXXXXX)" || return
  loopdev="$(sudo losetup -fLP --show "$1")" || return
  sudo mount "$loopdev"p1 "$workdir" \
    || sudo mount "$loopdev"p2 "$workdir" || return
}

pvm_umount() {
  trap - INT TERM EXIT

  [ -n "$workdir" ] && (sudo umount "$workdir"; rmdir "$workdir")
  unset workdir
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset loopdev
}

pvm_probe_arch() {
  local kernel
  kernel=$(find "$workdir" -maxdepth 1 -type f -iname '*vmlinu*' | head -n1)
  if [ -z "$kernel" ]; then
    warning "%s: unable to find kernel binary" "$1"
    return
  fi

  # attempt to get kernel arch from elf header
  arch="$(readelf -h "$kernel" 2>/dev/null | grep Machine | awk '{print $2}')"
  case "$arch" in
    PowerPC64) arch=ppc64; return;;
    RISC-V) arch=riscv64; return;;
    *) arch="";;
  esac

  # attempt to get kernel arch from objdump
  arch="$(objdump -f "$kernel" 2>/dev/null | grep architecture: | awk '{print $2}' | tr -d ',')"
  case "$arch" in
    i386) arch=i386; return;;
    i386:*) arch=x86_64; return;;
    *) arch="";;
  esac

  # attempt to get kernel arch from file magic
  arch="$(file "$kernel")"
  case "$arch" in
    *"ARM boot executable"*) arch=arm; return;;
    *) arch="";;
  esac

  # no more ideas; giving up.
}

pvm_native_arch() {
  local arch
	case "$1" in
		arm*) arch=armv7l;;
		*)    arch="$1";;
	esac

  setarch "$arch" /bin/true 2>/dev/null || return
}

pvm_guess_qemu_args() {
  # if we're not running on X / wayland, disable graphics
  if [ -z "$DISPLAY" ]; then qemu_args+=(-nographic); fi

  # if we're running a supported arch, enable kvm
  if pvm_native_arch "$2"; then qemu_args+=(-enable-kvm); fi

  # otherwise, decide by target arch
  case "$2" in
    i386|x86_64|ppc64)
      qemu_args+=(-m 2G "$1")
      # unmount the unneeded virtual drive early
      pvm_umount ;;
    arm)
      qemu_args+=(
        -machine virt
        -m 2G
        -kernel "$workdir"/vmlinuz-linux-libre
        -initrd "$workdir"/initramfs-linux-libre.img
        -append "console=tty0 console=ttyAMA0 rw root=/dev/vda3"
        -drive "if=none,file=$1,format=raw,id=hd"
        -device "virtio-blk-device,drive=hd"
        -netdev "user,id=mynet"
        -device "virtio-net-device,netdev=mynet") ;;
    riscv64)
      qemu_args+=(
        -machine virt
        -m 2G
        -kernel "$workdir"/bbl
        -append "rw root=/dev/vda"
        -drive "file=${loopdev}p3,format=raw,id=hd0"
        -device "virtio-blk-device,drive=hd0"
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device "virtio-rng-device,rng=rng0"
        -device "virtio-net-device,netdev=usernet"
        -netdev "user,id=usernet")
      if [ -z "$DISPLAY" ]; then
        qemu_args+=(-append "console=ttyS0 rw root=/dev/vda");
      fi ;;
    *)
      error "%s: unable to determine default qemu args" "$1"
      return "$EXIT_FAILURE" ;;
  esac
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as a regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  # parse options
  while getopts 'h' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      *) usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  if [ "$#" -lt 1 ]; then usage >&2; exit "$EXIT_INVALIDARGUMENT"; fi

  local imagefile="$1"
  shift

  if [ ! -e "$imagefile" ]; then
    error "%s: file not found" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  local workdir loopdev
  pvm_mount "$imagefile" || exit

  local arch
  pvm_probe_arch "$imagefile" || exit

  if [ -z "$arch" ]; then
    error "%s: arch is unknown" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  local qemu_args=()
  pvm_guess_qemu_args "$imagefile" "$arch" || exit
  qemu_args+=("$@")

  (set -x; qemu-system-"$arch" "${qemu_args[@]}")

  # clean up the terminal, in case SeaBIOS did something weird
  echo -n "[?7h[0m"
  pvm_umount
}

main "$@"