#!/usr/bin/env bash
#
# add-user.sh
#
# Issues a new client certificate for an additional NiFi user, and trusts
# it by adding it directly to the existing JKS truststore - no CA private
# key required. This matters because generate-certs.sh encrypts the CA
# key with a randomly-generated, one-time passphrase that is intentionally
# never saved to disk, so re-signing with the original CA is not possible
# once that first script run has finished. A certificate trusted directly
# in a truststore (rather than via a signing chain) is validated by Java's
# TLS stack the same way a self-signed root would be - it works fine as a
# trust anchor in its own right.
#
# Usage (from the same directory as docker-compose.yml, where certs/ and
# .env from generate-certs.sh already exist):
#   NEW_USER_CN=jane ./scripts/add-user.sh
#
# Optional overrides: NEW_USER_OU, NEW_USER_O, NEW_USER_L, NEW_USER_ST, NEW_USER_C

set -euo pipefail

ROOT_DIR="$(pwd)"
CERTS_DIR="${ROOT_DIR}/certs"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" || ! -f "${CERTS_DIR}/truststore.jks" ]]; then
  echo "Couldn't find .env / certs/truststore.jks in $(pwd)." >&2
  echo "Run this from the same directory as docker-compose.yml, after generate-certs.sh has already run once." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

NEW_USER_CN="${NEW_USER_CN:?Set NEW_USER_CN, e.g. NEW_USER_CN=jane ./scripts/add-user.sh}"
NEW_USER_OU="${NEW_USER_OU:-NiFiUsers}"
NEW_USER_O="${NEW_USER_O:-MyOrg}"
NEW_USER_L="${NEW_USER_L:-Lagos}"
NEW_USER_ST="${NEW_USER_ST:-Lagos}"
NEW_USER_C="${NEW_USER_C:-NG}"
DAYS_VALID="${DAYS_VALID:-825}"

# Same RDN-order gotcha as the admin cert: openssl's "-subj" lists CN
# first, but NiFi/Java report (and match against) the identity with C
# first, CN last. Always confirm against nifi-user.log if login fails.
NEW_USER_IDENTITY="C=${NEW_USER_C}, ST=${NEW_USER_ST}, L=${NEW_USER_L}, O=${NEW_USER_O}, OU=${NEW_USER_OU}, CN=${NEW_USER_CN}"

KEY_FILE="${CERTS_DIR}/user-${NEW_USER_CN}.key"
CRT_FILE="${CERTS_DIR}/user-${NEW_USER_CN}.crt"
P12_FILE="${CERTS_DIR}/user-${NEW_USER_CN}.p12"

if [[ -f "${P12_FILE}" ]]; then
  echo "${P12_FILE} already exists - remove it first if you want to reissue this user's cert." >&2
  exit 1
fi

gen_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
P12_PASSWORD="$(gen_pass)"

echo "==> Generating self-signed client certificate for ${NEW_USER_CN}"
openssl genrsa -out "${KEY_FILE}" 2048
openssl req -x509 -new -nodes -key "${KEY_FILE}" -sha256 -days "${DAYS_VALID}" \
  -subj "/CN=${NEW_USER_CN}/OU=${NEW_USER_OU}/O=${NEW_USER_O}/L=${NEW_USER_L}/ST=${NEW_USER_ST}/C=${NEW_USER_C}" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=clientAuth" \
  -out "${CRT_FILE}"

echo "==> Packaging ${P12_FILE} for browser import"
openssl pkcs12 -export -in "${CRT_FILE}" -inkey "${KEY_FILE}" \
  -name "${NEW_USER_CN}" -out "${P12_FILE}" -passout pass:"${P12_PASSWORD}"

echo "==> Adding ${NEW_USER_CN}'s certificate to truststore.jks"
keytool -import -noprompt -trustcacerts \
  -alias "nifi-user-${NEW_USER_CN}" \
  -file "${CRT_FILE}" \
  -keystore "${CERTS_DIR}/truststore.jks" -storetype JKS \
  -storepass "${TRUSTSTORE_PASSWORD}"

chmod 600 "${KEY_FILE}"

# Persist the password the same way generate-certs.sh does for the admin's
# ADMIN_P12_PASSWORD - otherwise it only ever exists in this one terminal's
# scrollback.
ENV_VAR_NAME="USER_$(echo "${NEW_USER_CN}" | tr '[:lower:]-' '[:upper:]_')_P12_PASSWORD"
if grep -q "^${ENV_VAR_NAME}=" "${ENV_FILE}" 2>/dev/null; then
  sed -i.bak "s/^${ENV_VAR_NAME}=.*/${ENV_VAR_NAME}=${P12_PASSWORD}/" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
else
  echo "${ENV_VAR_NAME}=${P12_PASSWORD}" >> "${ENV_FILE}"
fi

echo
echo "==================================================================="
echo "Done."
echo
echo "1. Restart NiFi so it reloads the updated truststore:"
echo "     docker compose restart nifi"
echo
echo "2. Give ${NEW_USER_CN} this file + password to import into their browser:"
echo "     ${P12_FILE}"
echo "     (import password saved as ${ENV_VAR_NAME} in ${ENV_FILE})"
echo "   They also need certs/ca.crt trusted, same as the admin setup."
echo
echo "3. Log into NiFi as admin, go to the Users icon (top right) ->"
echo "   Users and Policies -> add a new user with EXACTLY this identity:"
echo "     ${NEW_USER_IDENTITY}"
echo "   Then assign whatever policies (view/modify) they should have."
echo
echo "If they get 'Insufficient Permissions' after that, check the exact"
echo "identity NiFi actually parsed:"
echo "  docker compose exec nifi grep -i identity /opt/nifi/nifi-current/logs/nifi-user.log | tail -5"
echo "==================================================================="
