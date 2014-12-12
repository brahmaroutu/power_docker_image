#!/usr/bin/env bash
# Generate a very minimal filesystem based on busybox-static,
# and load it into the local docker under the name "docker-ut".

set -o pipefail

if [ -n "$(pidof docker)" ]; then
    echo "Make sure docker is not running..."
    exit 1
fi

missing_pkg() {
    echo "Sorry, I could not locate $1"
    echo "Try 'apt-get install ${2:-$1}'?"
    exit 1
}

BUSYBOX=$(which busybox)
[ "$BUSYBOX" ] || missing_pkg busybox busybox-static
SOCAT=$(which socat)
[ "$SOCAT" ] || missing_pkg socat

shopt -s extglob
set -ex
workdir=`mktemp -d ${TMPDIR:-/var/tmp}/docker-tet-image.XXXXXXXXXX`
trap "rm -rf '$workdir'" 0

outputdir="$PWD"
cd $workdir
mkdir fsroot
cd fsroot

mkdir bin etc dev dev/pts lib proc sys tmp
touch etc/resolv.conf
cp /etc/nsswitch.conf etc/nsswitch.conf
echo root:x:0:0:root:/:/bin/sh > etc/passwd
echo daemon:x:1:1:daemon:/usr/sbin:/bin/sh >> etc/passwd
echo root:x:0: > etc/group
echo daemon:x:1: >> etc/group
ln -s lib lib64
ln -s bin sbin
cp $BUSYBOX $SOCAT bin
for X in $(busybox --list)
do
    ln -s busybox bin/$X
done
rm bin/init
ln bin/busybox bin/init
case `uname -m` in
  x86_64)
    cp -P /lib/x86_64-linux-gnu/lib{pthread*,c*(-*),dl*(-*),nsl*(-*),nss_*,util*(-*),wrap,z}.so* lib
    cp /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 lib
    cp -P /usr/lib/x86_64-linux-gnu/lib{crypto,ssl}.so* lib
    ;;
  ppc64le)
    cp -P /lib/powerpc64le-linux-gnu/lib{pthread*,c*(-*),dl*(-*),nsl*(-*),nss_*,util*(-*),wrap,z}.so* lib
    cp /lib/powerpc64le-linux-gnu/ld64.so.2 lib
    cp -P /lib/powerpc64le-linux-gnu/lib{crypto,ssl}.so* lib
    ;;
  ppc64)
    cp -P /usr/lib64/lib{util*(-*),readline,ssl,crypto,c*(-*),tinfo,gssapi_krb5,krb5,com_err,k5crypto,dl*(-*),z,krb5support,keyutils,resolv*(-*),pthread*(-*),selinux,pcre,lzma}.so* lib
    cp -P /lib64/ld*.so* lib
esac

for X in console null ptmx random stdin stdout stderr tty urandom zero
do
    cp -a /dev/$X dev
done

chmod 0755 "$workdir/fsroot" # See #486

cd $workdir
mkdir unit-tests
docker -d -g "$workdir/unit-tests" -e native -s vfs &
trap "rm -rf '$workdir'; pkill docker" 0
sleep 5

tar --numeric-owner -cf- fsroot | docker import - docker-ut

imgid=83599e29c455eb719f77d799bc7c51521b9551972f5a850d7ad265bc1b5292f6
size=$(docker inspect -f '{{printf "%.0f" .VirtualSize}}' docker-ut)
docker rmi docker-ut

mkdir docker-test-image

echo '{"docker-test-image":{"latest":"'"$imgid"'"}}' > docker-test-image/repositories
mkdir -p "docker-test-image/$imgid"
echo '{"id":"'"$imgid"'","comment":"Imported from -","created":"2013-07-01T16:59:41.932231309-07:00","container_config":{"Hostname":"","User":"","Memory":0,"MemorySwap":0,"CpuShares":0,"AttachStdin":false,"AttachStdout":false,"AttachStderr":false,"PortSpecs":null,"Tty":false,"OpenStdin":false,"StdinOnce":false,"Env":null,"Cmd":null,"Dns":null,"Image":"","Volumes":null,"VolumesFrom":""},"docker_version":"0.4.6","architecture":"x86_64","Size":'"$size"'}' > "docker-test-image/$imgid/json"
echo '1.0' > "docker-test-image/$imgid/VERSION"
tar -C fsroot -cf "docker-test-image/$imgid/layer.tar" .
(cd docker-test-image && tar --numeric-owner -cf - * | docker load)

pkill docker
trap "rm -rf '$workdir'" 0
wait

tar -cf "$outputdir/unit-tests.tar" unit-tests

rm -rf "$workdir"
trap "" 0
