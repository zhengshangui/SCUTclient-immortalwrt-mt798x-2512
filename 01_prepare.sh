#!/bin/bash
set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENWRT_DIR="${OPENWRT_DIR:-$(pwd)}"
SCUTCLIENT_COMMIT="d9d618be97870813252b5ce7540f6a4ea4c22ab0"
DOWNLOAD_PATCH="$SCRIPT_DIR/patches/2512/build-system/download-reliability.patch"

cd "$OPENWRT_DIR"

if git apply --reverse --check "$DOWNLOAD_PATCH" >/dev/null 2>&1; then
  echo "下载器可靠性补丁已经应用。"
elif git apply --check "$DOWNLOAD_PATCH"; then
  git apply "$DOWNLOAD_PATCH"
  echo "已应用下载器可靠性补丁。"
else
  echo "错误：下载器可靠性补丁与当前源码不匹配。" >&2
  exit 1
fi

for patch_script in "$SCRIPT_DIR"/patches/2512/*.sh; do
  [ -e "$patch_script" ] || continue
  bash "$patch_script" "$OPENWRT_DIR"
done
 # ====================== 【这里是 feeds 部分，重点修改】======================
 ./scripts/feeds update -a
 # ✅ 必须在 feeds install‑a 之前删除损坏包
 rm -rf feeds/luci/applications/luci-app-radicale3
 ./scripts/feeds update luci
 ./scripts/feeds install -a
 # ==========================================================================
 # 下面是你原有其他包处理（scutclient等，原样保留）
rm -rf package/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon.git package/luci-theme-argon

rm -rf feeds/luci/applications/luci-app-scutclient
git clone https://github.com/hanwckf/luci-app-scutclient.git feeds/luci/applications/luci-app-scutclient
git -C feeds/luci/applications/luci-app-scutclient checkout --detach "$SCUTCLIENT_COMMIT"
[ "$(git -C feeds/luci/applications/luci-app-scutclient rev-parse HEAD)" = "$SCUTCLIENT_COMMIT" ]
git -C feeds/luci/applications/luci-app-scutclient apply \
  "$SCRIPT_DIR/patches/2512/luci-app-scutclient-modern-luci.patch"
bash "$SCRIPT_DIR/scripts/validate_scutclient.sh" \
  feeds/luci/applications/luci-app-scutclient/luasrc/controller/scutclient.lua

rm -rf package/scut-unicom
mkdir -p package/scut-unicom
wget --tries=5 --timeout=30 \
  https://raw.githubusercontent.com/wykdg/route_script/master/scut-unicom/Makefile \
  -O package/scut-unicom/Makefile
sed -i \
  -e 's#^PKG_RELEASE:=$(shell date "+%Y-%m-%d")#PKG_VERSION:=$(shell date "+%Y%m%d")\nPKG_RELEASE:=1#' \
  -e 's#^  VERSION:=$(PKG_RELEASE)#  VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)#' \
  package/scut-unicom/Makefile

openvpn_server_dir="feeds/luci/applications/luci-app-openvpn-server"
if [ -d "$openvpn_server_dir" ]; then
  rm -f "$openvpn_server_dir/root/etc/config/openvpn"
  openvpn_defaults="$openvpn_server_dir/root/etc/uci-defaults/openvpn"
  if [ -f "$openvpn_defaults" ] && ! grep -q "openvpn.myvpn=openvpn" "$openvpn_defaults"; then
    tmp_file="$(mktemp)"
    {
      cat <<'EOF'
if ! uci -q get openvpn.myvpn >/dev/null; then
uci -q batch <<-'EOF_UCI' >/dev/null
	set openvpn.myvpn=openvpn
	set openvpn.myvpn.enabled='0'
	set openvpn.myvpn.proto='tcp-server'
	set openvpn.myvpn.port='1194'
	set openvpn.myvpn.ddns='example.com'
	set openvpn.myvpn.dev='tun'
	set openvpn.myvpn.topology='subnet'
	set openvpn.myvpn.server='10.8.0.0 255.255.255.0'
	set openvpn.myvpn.comp_lzo='adaptive'
	set openvpn.myvpn.ca='/etc/openvpn/pki/ca.crt'
	set openvpn.myvpn.dh='/etc/openvpn/pki/dh.pem'
	set openvpn.myvpn.cert='/etc/openvpn/pki/server.crt'
	set openvpn.myvpn.key='/etc/openvpn/pki/server.key'
	set openvpn.myvpn.persist_key='1'
	set openvpn.myvpn.persist_tun='1'
	set openvpn.myvpn.user='nobody'
	set openvpn.myvpn.group='nogroup'
	set openvpn.myvpn.max_clients='10'
	set openvpn.myvpn.keepalive='10 120'
	set openvpn.myvpn.verb='3'
	set openvpn.myvpn.status='/var/log/openvpn_status.log'
	set openvpn.myvpn.log='/tmp/openvpn.log'
	add_list openvpn.myvpn.push='route 192.168.1.0 255.255.255.0'
	add_list openvpn.myvpn.push='comp-lzo adaptive'
	add_list openvpn.myvpn.push='redirect-gateway def1 bypass-dhcp'
	add_list openvpn.myvpn.push='dhcp-option DNS 192.168.1.1'
	commit openvpn
EOF_UCI
fi

EOF
      cat "$openvpn_defaults"
    } > "$tmp_file"
    cat "$tmp_file" > "$openvpn_defaults"
    rm -f "$tmp_file"
  fi
fi

rm -rf package/luci-app-tailscale

./scripts/feeds install -a

# Passwall 需要 haproxy 二进制，但系统自带的示例服务不应在首启时常驻。
haproxy_defaults="package/base-files/files/etc/uci-defaults/99-disable-unused-haproxy"
mkdir -p "$(dirname "$haproxy_defaults")"
cat > "$haproxy_defaults" <<'EOF'
#!/bin/sh

if [ -x /etc/init.d/haproxy ]; then
	/etc/init.d/haproxy disable
	/etc/init.d/haproxy stop
fi

exit 0
EOF
chmod 0755 "$haproxy_defaults"

if [ -f package/base-files/files/etc/rc.local ] && \
   ! grep -q 'scut_unicom/add_route.sh server_ip username password' package/base-files/files/etc/rc.local; then
  sed -i '/^exit 0/i # 如果要使用联通加速，取消下一行注释并填好参数\n#sleep 10 && /usr/share/scut_unicom/add_route.sh server_ip username password' \
    package/base-files/files/etc/rc.local
fi

ttyd_config="feeds/packages/utils/ttyd/files/ttyd.config"
if [ -f "$ttyd_config" ]; then
  sed -i "s#option command '/bin/login'#option command '/bin/login -f root'#" "$ttyd_config"
fi

default_settings="package/emortal/default-settings/files/99-default-settings"
if [ -f "$default_settings" ] && ! grep -q 'trojan-go' "$default_settings"; then
  sed -i "s#exit 0#[ ! -f '/usr/sbin/trojan' ] \\&\\& [ -f '/usr/bin/trojan-go' ] \\&\\& ln -sf /usr/bin/trojan-go /usr/bin/trojan\\nexit 0#" "$default_settings"
fi
#1、兜底强制apk官方源，隔绝vsean
mkdir -p files/etc/apk/repositories.d
cat > files/etc/apk/repositories.d/distfeeds.list <<'EOF'
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/targets/mediatek/filogic/packages/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/packages/aarch64_cortex-a53/base/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/targets/mediatek/filogic/kmods/6.12.103-1-b5b7729ffbba3ecdd83f339de8fadfb8/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/packages/aarch64_cortex-a53/luci/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/packages/aarch64_cortex-a53/packages/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/packages/aarch64_cortex-a53/routing/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12-SNAPSHOT/packages/aarch64_cortex-a53/telephony/packages.adb
EOF
# =====伪装网页型号 RuiJie SR503 （FUR‑603底层硬件ID不变）=====
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99_fake_ruijie <<'EOF'
#!/bin/sh
# 替换LuCI首页系统信息 /tmp/sysinfo/model
echo "RuiJie SR503" > /tmp/sysinfo/model

# 修改 board.json 网页硬件信息
if [ -f /etc/board.json ]; then
  sed -i 's|"name": *"HONOR FUR-602/603"|"name":"RuiJie SR503"|g' /etc/board.json
fi

# 兼容老版 board.info
[ -f /etc/board.info ] && sed -i 's/HONOR FUR-602\/603/RuiJie SR503/g' /etc/board.info

exit 0
EOF
chmod +x files/etc/uci-defaults/99_fake_ruijie
echo "[01_prepare.sh] finished"
