#!/bin/bash
set -e -o pipefail

CONFIG_FILE="${CONFIG_FILE:-.config}"
PACKAGE_CONF="${PACKAGE_CONF:-../package.conf}"

fail() {
  echo "软件包校验失败：$*" >&2
  exit 1
}

require_enabled() {
  grep -Fqx "CONFIG_PACKAGE_$1=y" "$CONFIG_FILE" || fail "缺少 $1"
}

require_disabled() {
  ! grep -Fqx "CONFIG_PACKAGE_$1=y" "$CONFIG_FILE" || fail "$1 不应被选中"
  ! grep -Fqx "CONFIG_PACKAGE_$1=m" "$CONFIG_FILE" || fail "$1 不应被选中"
}

find_enabled() {
  local package

  for package in "$@"; do
    if grep -Fqx "CONFIG_PACKAGE_$package=y" "$CONFIG_FILE"; then
      printf '%s\n' "$package"
      return 0
    fi
  done

  return 1
}

[ -f "$CONFIG_FILE" ] || fail "缺少配置文件 $CONFIG_FILE"

missing=()
requested=0

while IFS= read -r pkg || [ -n "$pkg" ]; do
  pkg="${pkg%$'\r'}"
  pkg="${pkg%%#*}"
  pkg="${pkg#"${pkg%%[![:space:]]*}"}"
  pkg="${pkg%"${pkg##*[![:space:]]}"}"
  [ -z "$pkg" ] && continue
  ((requested += 1))

  if ! grep -Fqx "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE"; then
    missing+=("$pkg")
  fi
done < "$PACKAGE_CONF"

if (( ${#missing[@]} > 0 )); then
  echo "make defconfig 后，下面这些请求的包没有被启用：" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "请检查包名、ImmortalWrt 25.12 分支支持情况和依赖关系。" >&2
  exit 1
fi

# require_enabled luci-app-sqm
require_enabled sqm-scripts
require_enabled kmod-sched-cake
require_enabled kmod-ifb
require_enabled iptables-mod-ipopt

tc_provider="$(find_enabled tc tc-tiny tc-full || true)"
[ -n "$tc_provider" ] || fail "缺少 tc、tc-tiny 或 tc-full"

iptables_provider="$(find_enabled iptables iptables-nft iptables-legacy || true)"
[ -n "$iptables_provider" ] || fail "缺少 iptables、iptables-nft 或 iptables-legacy"

require_disabled luci-app-tailscale
require_disabled luci-app-tailscale-community
require_disabled tailscale

echo "已验证 $requested 个请求的包：SQM 及其依赖已启用（tc: $tc_provider，iptables: $iptables_provider），Tailscale 已移除。"
