#!/usr/bin/env bash
# 构建前准备签名身份（幂等、静默、不碰登录钥匙串）。
#
# 为什么需要钥匙串文件：codesign 只从钥匙串里取 SecIdentity，没有"直接从
# PEM 签名"的接口。所以这里把仓库里的明文 p12 导入一个**项目内的钥匙串文件**：
#
#   .signing/build.keychain-db   ← 由 scripts/signing/<name>.p12 生成（gitignore）
#
# 它是纯派生产物：密码固定写在仓库里，随时可删可重建；登录钥匙串完全不动。
# 授权 codesign 直接使用私钥（-T + partition-list），所以构建不会弹密码框。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-keymute-dev}"
P12="${ROOT}/scripts/signing/${NAME}.p12"
PASS="${SIGN_P12_PASS:-keymute}"
KC="${ROOT}/.signing/build.keychain-db"
KC_PASS="${SIGN_KEYCHAIN_PASS:-keymute}"

[[ ! -f "$P12" ]] && exit 0

mkdir -p "${ROOT}/.signing"

if [[ ! -f "$KC" ]]; then
  security create-keychain -p "$KC_PASS" "$KC" >/dev/null
  security set-keychain-settings -lut 21600 "$KC" >/dev/null   # 6 小时后自动锁
  security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null
  security import "$P12" -k "$KC" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PASS" "$KC" >/dev/null
else
  security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null
fi

# codesign 的身份查找走用户钥匙串搜索列表，所以这个项目钥匙串必须在列表里。
# 幂等：已在列表就不动，也不影响其它钥匙串。
if ! security list-keychains -d user | grep -Fq "$KC"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s \
    $(security list-keychains -d user | sed 's/^[[:space:]]*//;s/"//g') "$KC" >/dev/null
fi

exit 0
