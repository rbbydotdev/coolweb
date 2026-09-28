#!/bin/sh
# Builds guest/out/Image (raw arm64 kernel) and guest/out/initramfs.gz (Alpine minirootfs + modules + overlay).
set -eu
cd "$(dirname "$0")"

ALPINE=3.24.2
KVER=6.18.53-r0
MIRROR=https://dl-cdn.alpinelinux.org/alpine/latest-stable
ROOTFS=cache/alpine-minirootfs-$ALPINE-aarch64.tar.gz
KAPK=cache/linux-virt-$KVER.apk

mkdir -p cache out
[ -f "$ROOTFS" ] || curl -fL -o "$ROOTFS" "$MIRROR/releases/aarch64/alpine-minirootfs-$ALPINE-aarch64.tar.gz"
[ -f "$KAPK" ] || curl -fL -o "$KAPK" "$MIRROR/main/aarch64/linux-virt-$KVER.apk"

# The apk is concatenated gzip streams; flatten to one tar stream.
gunzip -c "$KAPK" > cache/kernel.tar 2>/dev/null || true

# Extra userland from Alpine main. socat carries worker stdio over vsock. Versions come from APKINDEX.
# libstdc++ and libgcc: runtime for C++ binaries such as Bun's musl build.
PKGS="socat readline libncursesw ncurses-terminfo-base busybox-extras libstdc++ libgcc"
[ -f cache/APKINDEX ] || { curl -fsSL "$MIRROR/main/aarch64/APKINDEX.tar.gz" | tar -xzf - -C cache APKINDEX; }
PKG_TARS=""
for p in $PKGS; do
  # index(), not ~: package names like libstdc++ are not regexes.
  v=$(awk -v RS= -v p="$p" 'index($0, "\nP:" p "\n") { if (match($0, /\nV:[^\n]+/)) print substr($0, RSTART + 3, RLENGTH - 3) }' cache/APKINDEX)
  [ -n "$v" ] || { echo "package $p not found in APKINDEX" >&2; exit 1; }
  [ -f "cache/$p-$v.apk" ] || curl -fsSL -o "cache/$p-$v.apk" "$MIRROR/main/aarch64/$p-$v.apk"
  gunzip -c "cache/$p-$v.apk" > "cache/$p.tar" 2>/dev/null || true
  PKG_TARS="$PKG_TARS @cache/$p.tar"
done

# Kernel: Alpine ships an EFI zboot wrapper; VZLinuxBootLoader needs the raw Image inside it.
tar -xOf cache/kernel.tar boot/vmlinuz-virt > cache/vmlinuz-virt 2>/dev/null
python3 - <<'EOF'
import struct, gzip
d = open('cache/vmlinuz-virt', 'rb').read()
assert d[4:8] == b'zimg', 'not an EFI zboot image'
off, size = struct.unpack_from('<II', d, 8)
open('out/Image', 'wb').write(gzip.decompress(d[off:off + size]))
EOF

# Only the modules init needs, decompressed (busybox insmod cannot read .ko.gz), in load order.
MODS="net/core/failover drivers/net/net_failover drivers/net/virtio_net drivers/virtio/virtio_balloon
  drivers/char/hw_random/rng-core drivers/char/hw_random/virtio-rng
  net/vmw_vsock/vsock net/vmw_vsock/vmw_vsock_virtio_transport_common net/vmw_vsock/vmw_vsock_virtio_transport
  fs/fuse/fuse fs/fuse/virtiofs net/packet/af_packet"
KDIR=$(tar -tf cache/kernel.tar 2>/dev/null | grep -m1 -o '^lib/modules/[^/][^/]*')
rm -rf cache/stage && mkdir -p cache/stage/lib/coolweb
cp overlay/init cache/stage/init && chmod +x cache/stage/init
# busybox-extras applets (httpd for demos); apk would make these links in a post-install hook we skip.
mkdir -p cache/stage/usr/sbin && ln -sf /bin/busybox-extras cache/stage/usr/sbin/httpd
i=0
for m in $MODS; do
  i=$((i + 1))
  tar -xOf cache/kernel.tar "$KDIR/kernel/$m.ko.gz" 2>/dev/null | gunzip > "cache/stage/lib/coolweb/$(printf %02d $i)-$(basename $m).ko"
done

# Stream archives straight into newc cpio: no extraction, so case-insensitive APFS never sees the tree.
( cd cache/stage && tar -cf ../overlay.tar --uid 0 --gid 0 init lib usr )
# shellcheck disable=SC2086
tar -cf - --format newc --uid 0 --gid 0 --exclude '.PKGINFO' --exclude '.SIGN*' --exclude '.pre-*' --exclude '.post-*' \
  "@$ROOTFS" $PKG_TARS @cache/overlay.tar | gzip -9 > out/initramfs.gz

ls -lh out/
