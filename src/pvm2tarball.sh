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
  print "usage: %s [-h] [-o FILE] IMG" "${0##*/}"
  prose "Produce a parabola release tarball from IMG."
  echo
  prose "IMG is expected to be a valid parabola image, ideally freshly bootstrapped
         using pvmbootstrap. If FILE is not specifed, generate an archive name
         from IMG and place it in the current working directory"
  echo
  echo  "Supported options:"
  echo  "  -o FILE   Write the generated tar archive to FILE instead of"
  echo  "              generating a name for the archive from IMG"
  echo  "  -h        Display this help and exit"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  " <https://git.parabola.nu/~oaken-source/parabola-vmbootstrap.git>"
}

pvm_mount() {
  if ! file "$1" | grep -q ' DOS/MBR '; then
    error "%s: does not seem to be a raw qemu image." "$1"
    return "$EXIT_FAILURE"
  fi

  trap 'pvm_umount' INT TERM EXIT

  workdir="$(mktemp -d -t pvm-XXXXXXXXXX)" || return
  loopdev="$(sudo losetup -fLP --show "$1")" || return

  # find the root partition
  local part rootpart
  for part in "$loopdev"p*; do
    sudo mount "$part" "$workdir" || continue
    if [ -f "$workdir"/etc/fstab ]; then
      rootpart="$part"
      break
    fi
    sudo umount "$workdir"
  done

  if [ -z "$rootpart" ]; then
    error "%s: unable to determine root partition." "$1"
    return "$EXIT_FAILURE"
  fi

  # find the boot partition
  bootpart="$(findmnt -senF "$workdir"/etc/fstab /boot | awk '{print $2}')"

  if [ -z "$bootpart" ]; then
    error "%s: unable to determine boot partition." "$1"
    return "$EXIT_FAILURE"
  fi

  # mount and be happy
  sudo mount "$bootpart" "$workdir"/boot || return
}

pvm_umount() {
  trap - INT TERM EXIT

  [ -n "$workdir" ] && (sudo umount -R "$workdir"; rmdir "$workdir")
  unset workdir
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset loopdev
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as a regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  # parse options
  local output
  while getopts 'ho:' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      o) output="$OPTARG";;
      *) usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  if [ "$#" -ne 1 ]; then usage >&2; exit "$EXIT_INVALIDARGUMENT"; fi

  local imagebase imagefile="$1"
  imagebase="$(basename "$imagefile")"
  shift

  # check for input file presence
  if [ ! -e "$imagefile" ]; then
    error "%s: file not found" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  # determine output file
  [ -n "$output" ] || output="${imagebase%.*}.tar.gz"

  # check for output file presence
  if [ -e "$output" ]; then
    warning "%s: file exists. Continue? [y/N]" "$output"
    read -p " " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit "$EXIT_FAILURE"
    fi
    rm -f "$output" || exit
  fi

  # mount the root filesystem
  local workdir loopdev
  pvm_mount "$imagefile" || exit

  # tar the root filesystem, excluding unneeded things
  sudo tar -c -f "$output" -C "$workdir" -X - . << EOF
./boot/lost+found
./etc/.updated
./etc/pacman.d/empty.conf
./etc/pacman.d/gnupg
./lost+found
./root/.bash_history
./var/.updated
./var/log/journal/*
./var/log/pacman.log
./var/log/tallylog
EOF

  # HACKING:
  #  to update the exclude list above, one can download the latest archlinuxarm
  #  release tarball, and scroll over the diff generated by running both the
  #  archlinuxarm and the generated parabola tarball through:
  #
  # `tar -tf <tarball> | sort`

  # give the archive back to the user
  sudo chown "$(id -u)":"$(id -g)" "$output"

  # cleanup
  pvm_umount
}

main "$@"
