#!/usr/bin/env bash
# 生成（或复用）仓库里的固定签名身份。
#
# 证书与私钥是**仓库资产**：scripts/signing/keymute-dev.{key.pem,cert.pem,p12}
# 明文存放、固定不变 —— 同一把 key 每次构建都用它，重编不会让 TCC 认为换了程序。
#
# 平时不需要跑（文件已在仓库里）。只有换证书时才用：删掉三个文件后重跑。
set -euo pipefail

NAME="${1:-keymute-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${ROOT}/scripts/signing"
PASS="${SIGN_P12_PASS:-keymute}"

mkdir -p "$DIR"

if [[ -f "${DIR}/${NAME}.p12" && -f "${DIR}/${NAME}.key.pem" ]]; then
  echo "✅ 签名身份已存在：scripts/signing/${NAME}.p12"
  exit 0
fi

echo "==> 生成自签名代码签名证书：${NAME}"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "${DIR}/${NAME}.key.pem" -out "${DIR}/${NAME}.cert.pem" \
  -subj "/CN=${NAME}" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS 的 security import 只认传统 PKCS#12（-legacy），否则 MAC 校验失败
openssl pkcs12 -export -legacy \
  -inkey "${DIR}/${NAME}.key.pem" -in "${DIR}/${NAME}.cert.pem" \
  -name "${NAME}" -out "${DIR}/${NAME}.p12" -passout "pass:${PASS}" >/dev/null 2>&1

# 旧的项目钥匙串作废，下次构建按新证书重建
rm -f "${ROOT}/.signing/build.keychain-db"

echo "✅ 生成：scripts/signing/${NAME}.{key.pem,cert.pem,p12}"
echo "   之后 make / make run 会自动使用这把固定 key 签名。"
