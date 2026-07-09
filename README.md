# Apache NiFi 2.10.0 with mTLS - manual OpenSSL/keytool version

This is the explicit, step-by-step version of the CA -> server cert ->
admin cert -> keystore/truststore flow, matching:

1. `openssl` generates a self-signed CA.
2. `openssl` generates a NiFi server certificate, signed by that CA.
3. `openssl` generates an admin user certificate, signed by that CA.
4. `openssl pkcs12 -export` packages the server cert+key into a PKCS12
   keystore (NiFi reads PKCS12 natively, so no keystore JKS conversion
   is needed).
5. `keytool` builds a **JKS** truststore containing just the CA cert.

## One correction from the original outline

`nifi.security.user.login.identity.provider=single-user-provider` doesn't
belong here. That property configures **username/password** login (NiFi's
built-in single-user mode). It has nothing to do with certificate login,
and setting it alongside two-way TLS just creates a login mode NiFi isn't
using. With `nifi.security.needClientAuth=true` (which `AUTH=tls` sets),
NiFi reads the user's identity directly from the client certificate
presented during the TLS handshake - there's no login step, and therefore
no login-identity-provider to configure. This script and compose file
leave that property unset.

## Files this produces

```
certs/
  ca.key, ca.crt          the CA (keep ca.key private)
  nifi-server.key/.crt/.p12   NiFi's own TLS identity -> keystore
  nifi-user.key/.crt/.p12     the admin's identity -> import .p12 into your browser
  truststore.jks          JKS truststore containing the CA cert
.env                       passwords + INITIAL_ADMIN_IDENTITY, read by docker-compose.yml
```

A gotcha worth knowing if you ever build this by hand outside the script:
modern JDKs default `keytool` to write PKCS12 data even when the output
file is named `something.jks`, unless you explicitly pass `-storetype JKS`.
This script passes it explicitly - otherwise you'd get a file with a
`.jks` name that's actually PKCS12 inside, and NiFi would fail to open it
against `truststoreType=JKS`.

## nifi.properties, mapped

The docker image's startup scripts translate `NIFI_SECURITY_*`
environment variables straight into `nifi.properties` keys. Here's the
mapping this project uses, so you can see exactly which property each
variable controls:

| Environment variable | nifi.properties key |
|---|---|
| `NIFI_SECURITY_KEYSTORE` | `nifi.security.keystore` |
| `NIFI_SECURITY_KEYSTORE_TYPE` | `nifi.security.keystoreType` |
| `NIFI_SECURITY_KEYSTORE_PASSWD` | `nifi.security.keystorePasswd` |
| `NIFI_SECURITY_KEY_PASSWD` | `nifi.security.keyPasswd` |
| `NIFI_SECURITY_TRUSTSTORE` | `nifi.security.truststore` |
| `NIFI_SECURITY_TRUSTSTORE_TYPE` | `nifi.security.truststoreType` |
| `NIFI_SECURITY_TRUSTSTORE_PASSWD` | `nifi.security.truststorePasswd` |
| `NIFI_SECURITY_USER_AUTHORIZER` | `nifi.security.user.authorizer` |
| `AUTH=tls` (image convenience var) | sets `nifi.security.needClientAuth=true` and seeds `authorizers.xml`'s Initial Admin Identity from `INITIAL_ADMIN_IDENTITY` |

`AUTH=tls` is still doing one thing the explicit `NIFI_SECURITY_*` vars
can't: writing the admin's identity into `authorizers.xml`. That file is
separate from `nifi.properties` and isn't covered by the generic
env-var-to-property mechanism, so there's no plain `NIFI_SECURITY_*`
equivalent for it inside this Docker image - `AUTH=tls` is the supported
path to it.

## Usage

```bash
chmod +x scripts/generate-certs.sh
./scripts/generate-certs.sh
docker compose up -d
docker compose logs -f nifi
```

Then, same as before: add `127.0.0.1 nifi.local` to your hosts file,
import `certs/nifi-user.p12` (password: `ADMIN_P12_PASSWORD` in `.env`)
into your browser along with trusting `certs/ca.crt`, and browse to
`https://nifi.local:8443/nifi`.

Verify the seeded identity matches your cert:
```bash
docker compose exec nifi grep -A2 "Initial Admin Identity" /opt/nifi/nifi-current/conf/authorizers.xml
```

## If you're running NiFi outside Docker

The script's certs work the same way if you're not using this
docker-compose file at all - just point your own `nifi.properties`
directly at the generated files:

```
nifi.security.keystore=/path/to/certs/nifi-server.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=<KEYSTORE_PASSWORD from .env>
nifi.security.keyPasswd=<KEY_PASSWORD from .env>
nifi.security.truststore=/path/to/certs/truststore.jks
nifi.security.truststoreType=JKS
nifi.security.truststorePasswd=<TRUSTSTORE_PASSWORD from .env>
nifi.security.needClientAuth=true
nifi.security.user.authorizer=managed-authorizer
```

And in `conf/authorizers.xml`, set the `Initial Admin Identity` property
on the `managed-authorizer`'s user group provider to the value of
`INITIAL_ADMIN_IDENTITY` from `.env` - exactly, spacing included.
