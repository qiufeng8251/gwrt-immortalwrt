#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-tyfza1-config.sh — 生成 Realtek RTL9617C / TYFZA1 光猫固件配置
#
# 用法：
#   sh gwrt-mk-tyfza1-config.sh            # 生成 configs/config.tyfza1-<日期>-01
#   VER=261118-01 sh gwrt-mk-tyfza1-config.sh
#   WITH_SMB=1 sh gwrt-mk-tyfza1-config.sh
#
# 【与 an7581 序列对齐】
#   内核线同为 6.18（CONFIG_LINUX_6_18），插件集沿用 gwrt-mk-an7581-config.sh：
#   GWRT mesh 四件套、广告拦截、主题、zram/NAND 工具链、网络基础。
#   PON 用户态换成 TYFZA1 自有实现（tyfza1-pon-control / tyfza1-storage /
#   luci-app-tyfza1-pon）+ 通用 luci-app-pon-wan。
#
# 【无线栈】
#   rtl9617c 目标把 cfg80211/mac80211 与 rtl_ax_ap 编译进内核树，
#   kmod-rtl-ax-ap 直接打包这些 .ko；因此必须关闭 backports 版
#   kmod-mac80211 / kmod-cfg80211，否则同名模块冲突。
#
# 【不影响其它 SoC】
#   脚本只写自己的 .config（先备份现有），不改 feeds/、不改其它 target。
# ---------------------------------------------------------------------------
set -e

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

VER=${VER:-$(date +%y%m%d)-01}
OUT=${OUT:-$TOP/configs/config.tyfza1-$VER}
BAK="$TOP/.config.bak-$(date +%Y%m%d-%H%M%S)"
DEVICE=${DEVICE:-tianyi_tyfza1}
WITH_SMB=${WITH_SMB:-0}

echo "==> 目标: rtl9617c / $DEVICE"
echo "==> 输出: $OUT"

if [ -f "$TOP/.config" ]; then
	cp "$TOP/.config" "$BAK"
	echo "==> 已备份现有 .config -> $BAK"
fi

mkdir -p "$TOP/configs"
cat >"$OUT" <<EOF
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_HOST_OS_LINUX=y
CONFIG_TARGET_rtl9617c=y
CONFIG_TARGET_rtl9617c_generic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
$( [ "$DEVICE" = all ] || echo "CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_${DEVICE}=y" )
CONFIG_LINUX_6_18=y
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

cp "$OUT" "$TOP/.config"
make defconfig >/dev/null

if [ "$DEVICE" = "all" ]; then
	sed -i -E "s|^# (CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_[A-Za-z0-9_.-]+) is not set$|\\1=y|" "$TOP/.config"
	echo "==> 全设备模式: $(grep -c "^CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_.*=y$" "$TOP/.config") 个设备"
fi

add_pkg() {
	sym=$1
	grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config" && return 0
	if grep -q "^# CONFIG_PACKAGE_${sym} is not set$" "$TOP/.config"; then
		sed -i "s|^# CONFIG_PACKAGE_${sym} is not set$|CONFIG_PACKAGE_${sym}=y|" "$TOP/.config"
	else
		echo "CONFIG_PACKAGE_${sym}=y" >>"$TOP/.config"
	fi
	echo "  + $sym"
}

unset_pkg() {
	sym=$1
	grep -q "^CONFIG_PACKAGE_${sym}=y$" "$TOP/.config" || return 0
	sed -i "s|^CONFIG_PACKAGE_${sym}=y$|# CONFIG_PACKAGE_${sym} is not set|" "$TOP/.config"
	echo "  - $sym"
}

echo "[tyfza1] 无线栈（内核内 mac80211 + rtl_ax_ap，关闭 backports 版）:"
for p in \
	kmod-rtl-ax-ap \
	kmod-tyfza1-usb-led \
	wpad-mbedtls \
	wifi-scripts \
	iw \
	wireless-regdb ; do
	add_pkg "$p"
done
for p in kmod-mac80211 kmod-cfg80211 ; do
	unset_pkg "$p"
done

echo "[tyfza1] PON 用户态:"
for p in \
	tyfza1-pon-control \
	tyfza1-storage \
	luci-app-tyfza1-pon \
	luci-app-pon-wan ; do
	add_pkg "$p"
done

echo "[tyfza1] NAND / UBI 工具链:"
for p in \
	ubi-utils \
	nand-utils \
	uboot-envtools \
	mtd \
	kmod-zram \
	zram-swap ; do
	add_pkg "$p"
done

echo "[tyfza1] 网络与基础:"
for p in \
	dnsmasq-full \
	ppp-mod-pppoe \
	ip-full \
	luci-proto-ppp \
	luci-proto-ipv6 \
	luci-app-firewall \
	luci-app-opkg \
	luci-app-attendedsysupgrade \
	usbutils \
	blockd \
	block-mount ; do
	add_pkg "$p"
done

echo "[tyfza1] GWRT mesh 组网（与 an7581 一致）:"
for p in \
	gwrt-device-defaults \
	gwrt-mesh-led \
	gwrt-mesh-apmode \
	gwrt-agent ; do
	add_pkg "$p"
done

echo "[tyfza1] GWRT 广告拦截:"
for p in \
	gwrt-tv-adblock \
	luci-app-gwrt-tvadblock ; do
	add_pkg "$p"
done

echo "[tyfza1] 主题（与整个项目同一版本）:"
add_pkg luci-theme-gwrt

echo "[tyfza1] 清除（后期设备自行安装，固件不带）:"
for p in \
	openclash \
	luci-app-openclash \
	easytier \
	easytier-noweb \
	gecoosac \
	luci-app-gecoosac \
	docker \
	dockerd \
	docker-compose \
	podman \
	kmod-wireguard \
	kmod-tun \
	kmod-nft-tproxy \
	kmod-inet-diag \
	luci-app-bandix-plus \
	bandix-plus \
	coremark \
	luci-app-ttyd \
	ttyd \
	appfilter \
	kmod-oaf \
	luci-app-oaf \
	luci-theme-argon ; do
	unset_pkg "$p"
done

if [ "${WITH_SMB}" = "1" ]; then
	echo "[tyfza1] Samba4:"
	for p in \
		samba4-server luci-app-samba4 \
		kmod-fs-ext4 kmod-fs-exfat kmod-fs-vfat kmod-fs-ntfs3 \
		e2fsprogs automount block-mount ; do
		add_pkg "$p"
	done
fi

make defconfig >/dev/null

if [ "$OUT" != "$TOP/.config" ]; then
	cp "$TOP/.config" "$OUT"
fi

echo
echo "==> 完成: $OUT"
echo "==> 设备: $(grep -c "^CONFIG_TARGET_DEVICE_rtl9617c_generic_DEVICE_.*=y$" "$OUT") 个"
echo "==> 无线: $(grep -E '^CONFIG_PACKAGE_(kmod-rtl-ax-ap|wpad-mbedtls|wifi-scripts)=y$' "$OUT" | tr '\n' ' ')"
echo "==> PON:  $(grep -E '^CONFIG_PACKAGE_(tyfza1|luci-app-tyfza1|luci-app-pon)' "$OUT" | tr '\n' ' ')"
echo "==> 主题: $(grep -E '^CONFIG_PACKAGE_luci-theme-gwrt=y$' "$OUT" || echo '缺失')"
echo "==> 冲突检查（应为空）: $(grep -E '^CONFIG_PACKAGE_(kmod-mac80211|kmod-cfg80211)=y$' "$OUT" || true)"
