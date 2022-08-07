#!/bin/sh
#
BN="$(basename "$0")"

usage () {
    echo "USAGE: ${BN} [-k] osname [osdir]"
}

KEEP=
USAGE=
while getopts 'k' opt; do
    case $opt in
	k)
	    KEEP=y
	    ;;
	*)
	    USAGE=y
	    ;;
    esac
done
shift "$(expr "${OPTIND}" - 1)"

test -n "${USAGE}" && {
    usage >&2
    exit 1
}

OS="$1"
OSDIR="$2"
test -z "${OSDIR}" && OSDIR="${OS}"
# OS=focal

D="$(dirname "$0")"
VERSION="$(cat "${D}"/VERSION 2>/dev/null)"
test -z "${VERSION}" && VERSION=HEAD

# Execute a first sudo command, so hopefully
# we don't have to ask for the sudo password
# later on
sudo true

debootstrap --download-only --arch=i386 --variant=minbase "${OS}" "./${OSDIR}"
test -n "${KEEP}" && tar cf - "./${OSDIR}" |xz -c9 >"${OS}-debootstrap-debs.tar.xz"

sudo debootstrap --arch=i386 --variant=minbase "${OS}" "./${OSDIR}"
test -n "${KEEP}" && sudo tar cf - "./${OSDIR}" |xz -c9 >"${OS}-debootstrap.tar.xz"

sudo mkdir -p "./${OSDIR}/etc/netplan"
sudo tee  "./${OSDIR}/etc/netplan/netplan.yaml" >/dev/null <<EOF
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: true
EOF

sudo sed -i -e 's/$/ restricted universe multiverse/' "./${OSDIR}/etc/apt/sources.list"
SOURCE_LINE="$(head -1 "./${OSDIR}/etc/apt/sources.list")"
for r in updates backports security; do
  echo "${SOURCE_LINE}"|sed -e "s/${OS} main/${OS}-${r} main/"|sudo tee -a "./${OSDIR}/etc/apt/sources.list"
done

sudo ./mount.sh "./${OSDIR}"
sudo chroot "./${OSDIR}" apt-get update
sudo chroot "./${OSDIR}" apt-get upgrade -y
sudo chroot "./${OSDIR}" apt-get install -y uidmap systemd-sysv iproute2
sudo chroot "./${OSDIR}" apt-get install -y apt-utils net-tools
sudo chroot "./${OSDIR}" apt-get install -y ca-certificates libpsl5 openssl publicsuffix
sudo chroot "./${OSDIR}" apt-get install -y less vim

# netplan.io
# libnetplan0
# python3-netifaces
test -d "debs/${OS}" && {
  >"./install-packages-${OS}"
  for d in "debs/${OS}/"*; do
    b="$(basename "${d}")"
    sudo cp "${d}" "./${OSDIR}/var/cache/apt/archives/${b}"
    echo "/var/cache/apt/archives/${b}" >>"./install-packages-${OS}"
  done
  xargs -t sudo chroot "./${OSDIR}" apt-get install -y <"./install-packages-${OS}"
  rm -f "./install-packages-${OS}"
}

sudo chroot "./${OSDIR}" apt-get update
sudo chroot "./${OSDIR}" apt-get upgrade -y
sudo chroot "./${OSDIR}" apt-get clean
sudo ./umount.sh "./${OSDIR}"

mkdir -p "tmp-${OS}"
(
    cd  "tmp-${OS}"
    echo >metadata.yaml  "architecture: \"i386\""
    echo >>metadata.yaml "creation_date: $(date +%s)"
    echo >>metadata.yaml "properties:"
    echo >>metadata.yaml "  description: \"Ubuntu ${OS} i386 - Created by $(id -un)\""
    echo >>metadata.yaml "  os: \"ubuntu\""
    echo >>metadata.yaml "  release: \"${OS}\""

    tar -cf - metadata.yaml
)|gzip -c9 >"${OS}-metadata.tar.gz"
rm -rf "tmp-${OS}"
(cd "./${OSDIR}" && sudo tar -cpf - .)|gzip -c9 >"${OS}-lxc.tar.gz"

test -z "${KEEP}" && sudo rm -rf "./${OSDIR}"

LXCCONTAINER="$(echo "${OS}-${VERSION}"|tr -c -d -- "-a-zA-Z0-9")-$(openssl rand -hex 5)"
lxc image import "${OS}-metadata.tar.gz" "${OS}-lxc.tar.gz" --alias "${OS}-${VERSION}-import"
lxc init "${OS}-${VERSION}-import" "${LXCCONTAINER}"
lxc publish "${LXCCONTAINER}" --alias "${OS}-${VERSION}-export"
mkdir -p "tmp-${OS}-export"
lxc image export "${OS}-${VERSION}-export" "tmp-${OS}-export"
mv -v "tmp-${OS}-export"/* "${OS}-${VERSION}-lxcimage.tar.gz"
rm -rf "tmp-${OS}-export"

test -z "${KEEP}" && rm -f "${OS}-metadata.tar.gz" "${OS}-lxc.tar.gz"
lxc delete "${LXCCONTAINER}"
lxc image delete "${OS}-${VERSION}-import"
lxc image delete "${OS}-${VERSION}-export"
