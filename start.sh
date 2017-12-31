#!/bin/bash
 ##############################################################################
 #                       parabola-arm-imagebuilder                            #
 #                                                                            #
 #    Copyright (C) 2017  Andreas Grapentin                                   #
 #                                                                            #
 #    This program is free software: you can redistribute it and/or modify    #
 #    it under the terms of the GNU General Public License as published by    #
 #    the Free Software Foundation, either version 3 of the License, or       #
 #    (at your option) any later version.                                     #
 #                                                                            #
 #    This program is distributed in the hope that it will be useful,         #
 #    but WITHOUT ANY WARRANTY; without even the implied warranty of          #
 #    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
 #    GNU General Public License for more details.                            #
 #                                                                            #
 #    You should have received a copy of the GNU General Public License       #
 #    along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
 ##############################################################################

set -eu

_builddir=build
mkdir -p $_builddir

_imagefile=$1
_pidfile=$_builddir/qemu.pid

_loopdev=$(sudo losetup -f --show $_imagefile)
_bootdir=.boot

# register a cleanup error handler
function cleanup {
  test -f $_pidfile && (sudo kill -9 $(cat $_pidfile) || true)
  rm -f $_pidfile
  sudo umount ${_loopdev}p1
  sudo losetup -d $_loopdev
  rm -rf $_bootdir
}
trap cleanup ERR

# start the VM
mkdir -p $_bootdir
sudo mount ${_loopdev}p1 $_bootdir
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M vexpress-a9 \
  -m 1G \
  -dtb $_bootdir/dtbs/vexpress-v2p-ca9.dtb \
  -kernel $_bootdir/zImage \
  --append "root=/dev/mmcblk0p2 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file=$_imagefile \
  -display none \
  -net user,hostfwd=tcp::2022-:22 \
  -net nic \
  -daemonize \
  -snapshot \
  -pidfile $_pidfile

# wait for ssh to be up
_sshopts="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
while ! ssh -p 2022 -i keys/id_rsa root@localhost $_sshopts true 2>/dev/null; do
  echo -n . && sleep 5
done && echo

# open a session
ssh -p 2022 -i keys/id_rsa parabola@localhost

# shutdown the VM
ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
while sudo kill -0 $(cat $_pidfile) 2> /dev/null; do echo -n . && sleep 5; done && echo
rm -f $_pidfile

# cleanup
sudo umount ${_loopdev}p1
sudo losetup -d $_loopdev
rm -rf $_bootdir
