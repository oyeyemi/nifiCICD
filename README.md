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

## Adding a second user

`scripts/add-user.sh` issues a new client certificate for another person
and trusts it directly - it does **not** need the CA's private key.

That matters because `generate-certs.sh` encrypts `ca.key` with a
randomly-generated, one-time passphrase that is deliberately never saved
anywhere. That's fine for the CA's actual job (signing the server and
initial admin certs during setup), but it does mean the CA can't be used
to sign anything else afterward. Rather than fight that, `add-user.sh`
gives each new person their own self-signed client certificate and adds
its public cert as a second trusted entry directly in `truststore.jks`.
Java's TLS stack accepts a certificate trusted this way exactly like it
would a CA-signed one - no chain is required if the leaf cert itself is
already a trust anchor in the truststore.

```bash
NEW_USER_CN=jane ./scripts/add-user.sh
docker compose restart nifi   # required - NiFi doesn't hot-reload the truststore
```

This produces `certs/user-jane.p12` (password saved as
`USER_JANE_P12_PASSWORD` in `.env`) for jane to import into her browser,
alongside the same `certs/ca.crt` everyone else trusts. Then, logged in
as admin, go to the Users icon → *Users and Policies* → add a user with
the exact identity the script prints (order matters, same RDN-ordering
gotcha as the admin cert - see below) and assign whatever policies she
needs.

Optional overrides: `NEW_USER_OU`, `NEW_USER_O`, `NEW_USER_L`,
`NEW_USER_ST`, `NEW_USER_C` (defaults match whatever you set for the
admin in `generate-certs.sh`).

## The RDN-order gotcha (read this before troubleshooting a login failure)

`openssl -subj` and NiFi's actual identity string list the same fields in
**opposite order**. This script builds `-subj` as `CN=..., OU=..., O=...`
(CN first, as openssl expects), but NiFi reports and matches identities as
`C=..., ..., CN=...` (CN last). The scripts already account for this when
writing `INITIAL_ADMIN_IDENTITY` / the instructions `add-user.sh` prints -
but if you ever hand-build a DN yourself and get "Insufficient
Permissions" after a cert is otherwise accepted, the fix is always to
check the ground truth rather than guess:

```bash
docker compose exec nifi grep -i identity /opt/nifi/nifi-current/logs/nifi-user.log | tail -5
```

Whatever identity string appears there is exactly what needs to go into
`authorizers.xml` (for the bootstrap admin) or the Users screen (for
everyone added afterward).


## nifi.properties, mapped

`AUTH=tls` triggers the Docker image's `secure.sh`, which reads its own
fixed set of environment variable names and writes them into
`nifi.properties` for you, plus seeds `authorizers.xml`. These are
**not** the same as the generic `NIFI_SECURITY_*` template variables the
image also supports elsewhere - `secure.sh` doesn't read those at all,
so mixing the two (as an earlier draft of this project mistakenly did)
causes it to fail on startup with "Must specify an absolute path to the
keystore being used." The variables that actually work with `AUTH=tls`:

| Environment variable | nifi.properties key |
|---|---|
| `KEYSTORE_PATH` | `nifi.security.keystore` |
| `KEYSTORE_TYPE` | `nifi.security.keystoreType` |
| `KEYSTORE_PASSWORD` | `nifi.security.keystorePasswd` |
| `KEY_PASSWORD` | `nifi.security.keyPasswd` |
| `TRUSTSTORE_PATH` | `nifi.security.truststore` |
| `TRUSTSTORE_TYPE` | `nifi.security.truststoreType` |
| `TRUSTSTORE_PASSWORD` | `nifi.security.truststorePasswd` |
| `INITIAL_ADMIN_IDENTITY` | seeds `authorizers.xml`'s Initial Admin Identity (first boot only) |

One generic `NIFI_SECURITY_*` variable is still used alongside these:
`NIFI_SECURITY_USER_AUTHORIZER` → `nifi.security.user.authorizer`
(`managed-authorizer`). That one comes from the image's separate,
general-purpose config templating (visible in the boot log as lines like
`File [.../nifi.properties] replacing [...]`), which runs independently
of `secure.sh` and does accept the `NIFI_SECURITY_*` naming - it's only
`secure.sh` itself that requires the shorter, unprefixed names above.

`authorizers.xml` is a separate file from `nifi.properties` entirely, and
only `secure.sh` (via `AUTH=tls` + `INITIAL_ADMIN_IDENTITY`) writes to it
in this image - there's no generic env var for it.

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

## Configuration best practices applied

Beyond the mTLS setup itself, `docker-compose.yml` sets a handful of
properties the [NiFi Admin Guide](https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html)
calls out, so they're deliberate rather than left to image defaults:

| Setting | Why |
|---|---|
| `NIFI_SENSITIVE_PROPS_KEY` | Encrypts sensitive processor properties (passwords/tokens you'll type into a flow later). The Admin Guide specifically calls this out as something to always set explicitly. Generated once by `generate-certs.sh` and preserved across re-runs (including `--force`) - **back up `.env` somewhere safe**, since losing this key makes anything already encrypted with it unrecoverable. |
| Content repository archiving (`NIFI_CONTENT_REPOSITORY_ARCHIVE_*`) | Keeps deleted/superseded content briefly available for replay via the Provenance UI, bounded to 50% disk usage / 12h retention so it can't silently fill the disk. |
| Provenance repository sizing | Caps lineage history at 2 GB / 48 hours - long enough to be useful, bounded so it doesn't grow forever. |
| `NIFI_FLOW_CONFIGURATION_ARCHIVE_MAX_COUNT` | Caps how many `flow.xml.gz` backups accumulate in `conf/archive/`, which is unbounded by default. |
| `ulimits` (nofile/nproc) | NiFi can open many files and threads across its repositories and processor pools; Docker's default limits are lower than the Admin Guide recommends, and can cause "Too many open files" errors under real load even though everything looks fine at idle. |
| `mem_limit: 3g` | Caps total container memory so non-heap JVM memory (metaspace, direct buffers) plus the 2g heap can't exceed what the host can spare. Adjust to your ZBook's actual available RAM. |

All of these are adjustable directly in `docker-compose.yml` if your
needs differ (e.g. a bigger provenance window if you're debugging
lineage issues, or a larger `mem_limit` if you have RAM to spare).

## CI/CD

`.github/workflows/ci.yml` has two jobs:

**`validate`** runs on every push and PR, on GitHub's own hosted runner -
it never touches your ZBook. It shellchecks both scripts, validates
`docker-compose.yml`, generates a throwaway cert set, actually boots
NiFi inside the CI runner, confirms it's accepting TLS connections on
8443 and that the admin identity was seeded correctly, then tears
everything down. This is a real boot test, not just a syntax check - it
would have caught the `KEYSTORE_PATH` vs `NIFI_SECURITY_KEYSTORE`
mismatch bug from earlier in this project's history before it ever
reached your machine.

**`deploy`** only runs on a push to `main`, and only on a **self-hosted
runner** you install on the ZBook itself - labeled `zbook`. Your ZBook is
a private home-lab machine with no public inbound access, so GitHub's
own hosted runners can't reach it; a self-hosted runner solves this by
having your machine poll GitHub for jobs, rather than GitHub reaching
into your network. It only regenerates certs on a first-time deploy
(checked via `.env`/`certs/` not existing) - on every deploy after that
it leaves them alone, since regenerating would invalidate every
already-imported browser certificate.

### One-time setup on the ZBook

1. On GitHub: repo → **Settings → Actions → Runners → New self-hosted runner**.
2. Follow the download/config commands it gives you, run them on the
   ZBook. When prompted for labels, add `zbook` (matching
   `runs-on: [self-hosted, zbook]` in the workflow).
3. Install it as a service so it survives reboots:
   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   ```
4. Push to `main` and check the Actions tab - the `deploy` job should
   pick it up.

### What never touches GitHub

`.env` and `certs/` stay out of git entirely (already in `.gitignore`).
The `deploy` job generates them locally on the ZBook via the runner, the
same way you'd do it by hand - nothing secret ever gets uploaded to or
stored in GitHub.

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
