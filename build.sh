#!/bin/bash
set -euo pipefail
# ---------------------------------------------------------------------------
#  SETTINGS -- the only part you normally need to touch
# ---------------------------------------------------------------------------
export KERNEL_ROOT="$(pwd)"
DEFCONFIG="m14x_defconfig"      
EXTRA_CONFIGS=(custom.config)               
KERNEL_IMAGE="Image"           
USE_OUT_DIR=0                  
MENUCONFIG=0                   # 0 = skip the menuconfig GUI
export KBUILD_BUILD_USER="@prisma_droid"
export DEVICE="m14x"
export ARCH=arm64
export SUBARCH=arm64
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LLVM=1
export LTO=thin
export LLVM_IAS=1
export TARGET_SOC=s5e8535
export SOC_NAME=s5e8535
export DTC_FLAGS="-@"
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export DEPMOD=depmod
export PATH=${KERNEL_ROOT}/toolchain/clang/host/linux-x86/clang-r450784d/bin:$PATH
export PATH=${KERNEL_ROOT}/toolchain/build/kernel/build-tools/path/linux-x86/:$PATH
# ---------------------------------------------------------------------------

info(){ echo -e "\n[INFO]: $*\n"; }
die(){ echo -e "\n[ERROR]: $*\n" >&2; exit 1; }

DEB_PKGS=(build-essential bc bison flex pkg-config git curl tar xz-utils zip unzip cpio rsync
          kmod perl python3 python-is-python3 libssl-dev libelf-dev pahole libncurses-dev
          zlib1g-dev libyaml-dev lz4 zstd device-tree-compiler)

install_deps(){
    local missing=() available=() p
    if ! command -v dpkg &>/dev/null; then
        info "Non-Debian system detected -- ensure build dependencies are installed manually."
        return 0
    fi

    for p in "${DEB_PKGS[@]}"; do
        [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] || missing+=("$p")
    done
    [ "${#missing[@]}" = 0 ] && return 0

    for p in "${missing[@]}"; do 
        apt-cache show "$p" &>/dev/null && available+=("$p")
    done
    [ "${#available[@]}" = 0 ] && return 0

    info "Installing missing dependencies: ${available[*]}"
    sudo apt update && sudo apt install -y "${available[@]}" || die "apt failed"
}

[ -f Makefile ] && [ -d arch/arm64 ] || die "Run this from the kernel source root."
install_deps
[ -f .gitmodules ] && git submodule update --init --recursive

BUILD_OPTIONS=(
    -j"$(nproc)"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    HOSTCC=gcc
    HOSTCXX=g++
)

if [ "${USE_OUT_DIR}" = 1 ]; then
    BUILD_ROOT="${KERNEL_ROOT}/out"
    BUILD_OPTIONS+=(O="${BUILD_ROOT}")
    BOOT_DIR="${BUILD_ROOT}/arch/arm64/boot"
else
    BUILD_ROOT="${KERNEL_ROOT}"
    BOOT_DIR="${KERNEL_ROOT}/arch/arm64/boot"
fi

STAGING_DIR="${KERNEL_ROOT}/build/staging"

build_kernel(){
    info "Kernel $(make kernelversion) | defconfig: ${DEFCONFIG}"
    make "${BUILD_OPTIONS[@]}" "${DEFCONFIG}" "${EXTRA_CONFIGS[@]}" || die "Failed to write .config"
    
    if [ "${MENUCONFIG}" = 1 ]; then
        make "${BUILD_OPTIONS[@]}" menuconfig
    fi

    # 1. Build Kernel, Modules, and Device Trees
    make "${BUILD_OPTIONS[@]}" "${KERNEL_IMAGE}" modules dtbs || die "Build failed"

    # 2. Prepare Clean Staging Directory
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}/boot/dtbs"

    # 3. Copy Kernel Image
    cp "${BOOT_DIR}/${KERNEL_IMAGE}" "${STAGING_DIR}/boot/"

    # 4. Install & Strip Modules to Staging
    make "${BUILD_OPTIONS[@]}" INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="${STAGING_DIR}" modules_install || die "Modules install failed"

    # 5. Install DTBs and DTBOs to Staging
    find "${BOOT_DIR}" -type f \( -name "*.dtb" -o -name "*.dtbo" \) -exec cp {} "${STAGING_DIR}/boot/dtbs/" \; 2>/dev/null || true

    # 6. Copy System.map and .config to Staging
    if [ -f "${BUILD_ROOT}/System.map" ]; then
        cp "${BUILD_ROOT}/System.map" "${STAGING_DIR}/boot/System.map"
    else
        die "System.map not found at ${BUILD_ROOT}/System.map"
    fi

    if [ -f "${BUILD_ROOT}/.config" ]; then
        cp "${BUILD_ROOT}/.config" "${STAGING_DIR}/boot/config"
    fi

    info "Done -> Staging successfully created at: ${STAGING_DIR}"
}

build_kernel
