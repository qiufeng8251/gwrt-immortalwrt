# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=rtl9617c
BOARDNAME:=Realtek RTL9617C (Taurus)
CPU_TYPE:=cortex-a55
# mbedtls 3.6 的 library/CMakeLists 会给 sha256.c 单独加 -march=armv8-a+crypto，
# 而 -mcpu=cortex-a55 隐含 armv8.2-a+dotprod+fp16，两者的 target attribute 不一致，
# 导致 fortify 的 inline memset 报 "target specific option mismatch"。
# 这里与 mbedtls 覆盖保持一致（-mtune 不影响 target attribute）。
CPU_CFLAGS_cortex-a55:=-march=armv8-a+crypto -mtune=cortex-a55
SUBTARGETS:=generic
FEATURES:=fpu nand ramdisk squashfs targz usb
DEPENDS:=+@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT
KERNEL_PATCHVER:=6.18
KERNELNAME:=Image
DEVICE_TYPE:=router

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += ubi-utils nand-utils ucode-mod-uci

define Target/Description
  Native RTL9617C support. TYFZA1 serial bring-up; hardware validation pending.
endef

$(eval $(call BuildTarget))
