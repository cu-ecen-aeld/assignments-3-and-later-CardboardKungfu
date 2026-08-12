#!/bin/sh
# Script outline to install and build kernel.
# Author: Siddhant Jajoo.

set -e
set -u

OUTDIR=/tmp/aeld
KERNEL_REPO=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
KERNEL_VERSION=v5.15.163
BUSYBOX_VERSION=1_33_1
FINDER_APP_DIR=$(realpath $(dirname $0))
ARCH=arm64
CROSS_COMPILE=aarch64-none-linux-gnu-

if [ $# -lt 1 ]
then
	echo "Using default directory ${OUTDIR} for output"
else
	OUTDIR=$1
	echo "Using passed directory ${OUTDIR} for output"
fi

mkdir -p ${OUTDIR}

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/linux-stable" ]; then
    #Clone only if the repository does not exist.
	echo "CLONING GIT LINUX STABLE VERSION ${KERNEL_VERSION} IN ${OUTDIR}"
	git clone ${KERNEL_REPO} --depth 1 --single-branch --branch ${KERNEL_VERSION}
fi
if [ ! -e ${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image ]; then
    cd ${OUTDIR}/linux-stable
    echo "Checking out version ${KERNEL_VERSION}"
    git checkout ${KERNEL_VERSION}

    # TODO: Add your kernel build steps here
    # Steps located in Module 2 - Building the Linux Kernel video
    
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} mrproper
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    make -j4 ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} all
    # make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} modules
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} dtbs
fi

echo "Adding the Image in outdir"
cp ${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image ${OUTDIR}/Image

echo "Creating the staging directory for the root filesystem"
cd "$OUTDIR"
if [ -d "${OUTDIR}/rootfs" ]
then
	echo "Deleting rootfs directory at ${OUTDIR}/rootfs and starting over"
    sudo rm  -rf ${OUTDIR}/rootfs
fi

# TODO: Create necessary base directories
mkdir -p ${OUTDIR}/rootfs
cd ${OUTDIR}/rootfs
mkdir -p bin dev etc home lib lib64 proc sbin sys tmp usr var
mkdir -p usr/bin usr/lib usr/sbin
mkdir -p var/log

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/busybox" ]
then
git clone git://busybox.net/busybox.git
    cd busybox
    git checkout ${BUSYBOX_VERSION}
    # TODO:  Configure busybox
    make distclean
    make defconfig
else
    cd busybox
fi

# TODO: Make and install busybox
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}
make CONFIG_PREFIX=${OUTDIR}/rootfs ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}  install

cd "${OUTDIR}/rootfs"

echo "Library dependencies"
${CROSS_COMPILE}readelf -a bin/busybox | grep "program interpreter"
${CROSS_COMPILE}readelf -a bin/busybox | grep "Shared library"

# TODO: Add library dependencies to rootfs
# Dynamically determine toolchain sysroot from cross-compiler
TOOLCHAIN_SYSROOT=$(${CROSS_COMPILE}gcc -print-sysroot 2>/dev/null || echo "")
if [ -z "${TOOLCHAIN_SYSROOT}" ]; then
    # Fallback: try to find libc path relative to cross-compiler
    CROSS_CC_PATH=$(which ${CROSS_COMPILE}gcc 2>/dev/null || true)
    if [ -n "${CROSS_CC_PATH}" ]; then
        # Deduce sysroot from compiler path (e.g., /path/to/bin/aarch64-none-linux-gnu-gcc -> /path/to)
        TOOLCHAIN_SYSROOT=$(cd "$(dirname "${CROSS_CC_PATH}")/.." && pwd)
    fi
fi

# Locate ld-linux-aarch64.so.1
LD_LINUX_AARCH64=""
if [ -n "${TOOLCHAIN_SYSROOT}" ]; then
    # Search common lib/lib64 paths under sysroot
    for libdir in lib lib64 aarch64-none-linux-gnu/libc/lib aarch64-none-linux-gnu/libc/lib64; do
        if [ -f "${TOOLCHAIN_SYSROOT}/${libdir}/ld-linux-aarch64.so.1" ]; then
            LD_LINUX_AARCH64="${TOOLCHAIN_SYSROOT}/${libdir}/ld-linux-aarch64.so.1"
            break
        fi
    done
fi

# Fallback: hardcoded local path (for local development)
if [ -z "${LD_LINUX_AARCH64}" ] && [ -f "/home/jed/arm-cross-compiler/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu/aarch64-none-linux-gnu/libc/lib/ld-linux-aarch64.so.1" ]; then
    LD_LINUX_AARCH64="/home/jed/arm-cross-compiler/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu/aarch64-none-linux-gnu/libc/lib/ld-linux-aarch64.so.1"
fi

# Locate standard C libraries
LIBM=""
LIBRESOLVE=""
LIBC=""
if [ -n "${TOOLCHAIN_SYSROOT}" ]; then
    for libdir in lib64 lib aarch64-none-linux-gnu/libc/lib64; do
        [ -z "${LIBM}" ] && [ -f "${TOOLCHAIN_SYSROOT}/${libdir}/libm.so.6" ] && LIBM="${TOOLCHAIN_SYSROOT}/${libdir}/libm.so.6"
        [ -z "${LIBRESOLVE}" ] && [ -f "${TOOLCHAIN_SYSROOT}/${libdir}/libresolv.so.2" ] && LIBRESOLVE="${TOOLCHAIN_SYSROOT}/${libdir}/libresolv.so.2"
        [ -z "${LIBC}" ] && [ -f "${TOOLCHAIN_SYSROOT}/${libdir}/libc.so.6" ] && LIBC="${TOOLCHAIN_SYSROOT}/${libdir}/libc.so.6"
    done
fi

# Fallback to local hardcoded paths
TOOLCHAIN_ROOT_FALLBACK=/home/jed/arm-cross-compiler/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-linux-gnu/aarch64-none-linux-gnu/libc
[ -z "${LIBM}" ] && [ -f "${TOOLCHAIN_ROOT_FALLBACK}/lib64/libm.so.6" ] && LIBM="${TOOLCHAIN_ROOT_FALLBACK}/lib64/libm.so.6"
[ -z "${LIBRESOLVE}" ] && [ -f "${TOOLCHAIN_ROOT_FALLBACK}/lib64/libresolv.so.2" ] && LIBRESOLVE="${TOOLCHAIN_ROOT_FALLBACK}/lib64/libresolv.so.2"
[ -z "${LIBC}" ] && [ -f "${TOOLCHAIN_ROOT_FALLBACK}/lib64/libc.so.6" ] && LIBC="${TOOLCHAIN_ROOT_FALLBACK}/lib64/libc.so.6"

mkdir -p "${OUTDIR}/rootfs/lib" "${OUTDIR}/rootfs/lib64"
if [ -n "${LD_LINUX_AARCH64}" ] && [ -f "${LD_LINUX_AARCH64}" ]; then
    echo "Copying loader ${LD_LINUX_AARCH64} -> ${OUTDIR}/rootfs/lib/"
    cp "${LD_LINUX_AARCH64}" "${OUTDIR}/rootfs/lib/"
else
    echo "Warning: ld-linux-aarch64.so.1 not found in toolchain (${TOOLCHAIN_ROOT}); init may fail if busybox is dynamically linked"
fi

cp "${LIBM}" "${OUTDIR}/rootfs/lib64" || true
cp "${LIBRESOLVE}" "${OUTDIR}/rootfs/lib64" || true
cp "${LIBC}" "${OUTDIR}/rootfs/lib64" || true

# TODO: Make device nodes
sudo mknod -m 666 ${OUTDIR}/rootfs/dev/null c 1 3
sudo mknod -m 666 ${OUTDIR}/rootfs/dev/console c 5 1

# TODO: Clean and build the writer utility
cd "${FINDER_APP_DIR}"
make clean
make CROSS_COMPILE=${CROSS_COMPILE} writer

# TODO: Copy the finder related scripts and executables to the /home directory
# on the target rootfs
cp writer ${OUTDIR}/rootfs/home
cp finder.sh ${OUTDIR}/rootfs/home
cp finder-test.sh ${OUTDIR}/rootfs/home
mkdir -p ${OUTDIR}/rootfs/home/conf/ && cp conf/username.txt conf/assignment.txt ${OUTDIR}/rootfs/home/conf
cp autorun-qemu.sh ${OUTDIR}/rootfs/home

# TODO: Chown the root directory
sudo chown -R root:root ${OUTDIR}/rootfs

# TODO: Create initramfs.cpio.gz
cd ${OUTDIR}/rootfs
find . | cpio -H newc -ov --owner root:root > ${OUTDIR}/initramfs.cpio
gzip -f ${OUTDIR}/initramfs.cpio
