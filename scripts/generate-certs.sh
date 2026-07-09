#!/usr/bin/env bash
#
# generate-certs.sh - manual OpenSSL + keytool version
#
# Follows the CA -> server cert -> user cert -> PKCS12 -> keytool flow:
#   1. Self-signed CA (openssl)
#   2. NiFi server cert, signed by the CA (openssl)
#   3. NiFi admin user cert, signed by the CA (openssl)
#   4. Server cert+key -> PKCS12 keystore (openssl) - NiFi reads PKCS12
#      natively, so no JKS conversion needed for the keystore.
#   5. CA cert -> JKS truststore (keytool), matching your requested
#      nifi.security.truststoreType=JKS.
#
# Usage:
#   cd into the folder that contains (or should contain) docker-compose.yml,
#   then run: bash scripts/generate-certs.sh [--force]
#   Output always lands in ./certs and ./.env relative to your CURRENT
#   directory when you run it - not relative to the script's own location.

set -euo pipefail

ROOT_DIR="$(pwd)"
CERTS_DIR="${ROOT_DIR}/certs"
FORCE="${1:-}"

echo "Writing certs/ and .env under: ${ROOT_DIR}"
echo "(this is your current directory - cd elsewhere first if that's wrong)"
echo

# ---- Configurable identity fields -----------------------------------------
NIFI_HOSTNAME="${NIFI_HOSTNAME:-nifi.local}"
CA_CN="${CA_CN:-MyNiFiCA}"
ORG_OU="${ORG_OU:-Security}"
ORG_O="${ORG_O:-MyOrg}"
ORG_L="${ORG_L:-Lagos}"
ORG_ST="${ORG_ST:-Lagos}"
ORG_C="${ORG_C:-NG}"

ADMIN_CN="${ADMIN_CN:-admin}"
ADMIN_OU="${ADMIN_OU:-NiFiUsers}"

DAYS_VALID="${DAYS_VALID:-825}"      # 365 in your snippet; 825 is the browser-accepted max
CA_DAYS_VALID="${CA_DAYS_VALID:-3650}"

# Exact DN NiFi will read from the client cert. Order/spacing matters -
# this must match INITIAL_ADMIN_IDENTITY used to seed authorizers.xml.
INITIAL_ADMIN_IDENTITY="CN=${ADMIN_CN}, OU=${ADMIN_OU}, O=${ORG_O}, L=${ORG_L}, ST=${ORG_ST}, C=${ORG_C}"

if [[ -d "${CERTS_DIR}" && "${FORCE}" != "--force" ]]; then
  echo "certs/ already exists. Re-run with --force to regenerate (this invalidates old certs)." >&2
  exit 1
fi

rm -rf "${CERTS_DIR}"
mkdir -p "${CERTS_DIR}"
cd "${CERTS_DIR}"

gen_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24; }

CA_PASS="$(gen_pass)"
KEYSTORE_PASSWORD="$(gen_pass)"
KEY_PASSWORD="${KEYSTORE_PASSWORD}"
TRUSTSTORE_PASSWORD="$(gen_pass)"
ADMIN_P12_PASSWORD="$(gen_pass)"

# ---- 1. Certificate Authority ----------------------------------------------
echo "==> [1/5] Generating CA"
openssl genrsa -aes256 -passout pass:"${CA_PASS}" -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -passin pass:"${CA_PASS}" -sha256 -days "${CA_DAYS_VALID}" \
  -out ca.crt -subj "/CN=${CA_CN}/OU=${ORG_OU}/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"

# ---- 2. NiFi server certificate --------------------------------------------
echo "==> [2/5] Generating NiFi server certificate for ${NIFI_HOSTNAME}"
openssl genrsa -out nifi-server.key 2048
openssl req -new -key nifi-server.key -out nifi-server.csr \
  -subj "/CN=${NIFI_HOSTNAME}/OU=NiFi/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"

# SAN is required by modern browsers/JDKs even though the original snippet
# omits it - without it, hostname verification fails.
cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${NIFI_HOSTNAME}
DNS.2 = nifi
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

openssl x509 -req -in nifi-server.csr -CA ca.crt -CAkey ca.key -passin pass:"${CA_PASS}" \
  -CAcreateserial -out nifi-server.crt -days "${DAYS_VALID}" -sha256 -extfile server.ext

# ---- 3. NiFi admin (user) certificate --------------------------------------
echo "==> [3/5] Generating NiFi admin user certificate (${INITIAL_ADMIN_IDENTITY})"
openssl genrsa -out nifi-user.key 2048
openssl req -new -key nifi-user.key -out nifi-user.csr \
  -subj "/CN=${ADMIN_CN}/OU=${ADMIN_OU}/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"

cat > user.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl x509 -req -in nifi-user.csr -CA ca.crt -CAkey ca.key -passin pass:"${CA_PASS}" \
  -CAcreateserial -out nifi-user.crt -days "${DAYS_VALID}" -sha256 -extfile user.ext

# ---- 4. PKCS12 keystores ----------------------------------------------------
echo "==> [4/5] Building PKCS12 keystores"
# Server keystore - this is what nifi.security.keystore points at directly.
openssl pkcs12 -export -in nifi-server.crt -inkey nifi-server.key \
  -out nifi-server.p12 -name nifi-server -CAfile ca.crt -caname root -chain \
  -passout pass:"${KEYSTORE_PASSWORD}"

# User (admin) keystore - for importing into a browser to present as the
# client certificate during login.
openssl pkcs12 -export -in nifi-user.crt -inkey nifi-user.key \
  -out nifi-user.p12 -name nifi-user -CAfile ca.crt -caname root -chain \
  -passout pass:"${ADMIN_P12_PASSWORD}"

# ---- 5. JKS truststore -------------------------------------------------------
echo "==> [5/5] Building JKS truststore (CA cert only)"
# Modern JDKs (9+) default keytool's store format to PKCS12 regardless of
# the .jks filename unless -storetype JKS is passed explicitly - without
# this flag, the file would be PKCS12 data wearing a .jks extension, and
# NiFi would fail to open it against truststoreType=JKS.
keytool -import -noprompt -trustcacerts \
  -alias rootCA -file ca.crt \
  -keystore truststore.jks -storetype JKS -storepass "${TRUSTSTORE_PASSWORD}"

# Note: nifi-server.p12 is used as-is (PKCS12) per NiFi's native support -
# skipping the optional PKCS12 -> JKS keystore conversion your outline
# marked optional, since it adds a step with no benefit here.

chmod 600 ca.key nifi-server.key nifi-user.key
cd "${ROOT_DIR}"

# ---- .env for docker-compose -----------------------------------------------
cat > "${ROOT_DIR}/.env" <<EOF
# Generated by scripts/generate-certs.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
NIFI_HOSTNAME=${NIFI_HOSTNAME}
KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}
KEY_PASSWORD=${KEY_PASSWORD}
TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD}
ADMIN_P12_PASSWORD=${ADMIN_P12_PASSWORD}
INITIAL_ADMIN_IDENTITY=${INITIAL_ADMIN_IDENTITY}
EOF

rm -f "${CERTS_DIR}/server.ext" "${CERTS_DIR}/user.ext"

echo
echo "==================================================================="
echo "Done. Files written under ${CERTS_DIR}:"
echo "  ca.key, ca.crt               - the CA (keep ca.key private)"
echo "  nifi-server.key/.crt/.p12    - NiFi's server identity (keystore)"
echo "  nifi-user.key/.crt/.p12      - the admin's client identity"
echo "  truststore.jks               - JKS truststore containing the CA"
echo
echo "Import into your browser to log in as admin:"
echo "  ${CERTS_DIR}/nifi-user.p12"
echo "  (import password is ADMIN_P12_PASSWORD in ${ROOT_DIR}/.env)"
echo
echo "NiFi will see the admin identity as:"
echo "  ${INITIAL_ADMIN_IDENTITY}"
echo
echo "Add this to /etc/hosts (or Windows hosts file) if you haven't:"
echo "  127.0.0.1  ${NIFI_HOSTNAME}"
echo "==================================================================="
