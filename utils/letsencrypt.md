# Let's Encrypt Wildcard Certificate on OCI with Automatic Renewal

Issue a **publicly trusted wildcard TLS certificate** from Let's Encrypt using the DNS-01
challenge, import it into the OCI Certificates service, serve it from an OCI Load Balancer,
and renew it automatically — with **no API keys or secrets stored anywhere**.

> **Note on terminology:** this is *not* a self-signed certificate. Let's Encrypt is a publicly
> trusted Certificate Authority, so browsers and clients accept the certificate without warnings.
> A true self-signed certificate would produce trust errors and wouldn't involve Let's Encrypt.

---

## Architecture

```
certbot (OCI compute instance)
   │
   ├─ auth/cleanup hooks ──► OCI CLI (instance principal) ──► OCI DNS  (_acme-challenge TXT)
   │                                                              │
   │                                                    Let's Encrypt validates
   │
   └─ deploy hook ──► OCI Certificates (new certificate version)
                                    │
                          LB agent polls & picks up CURRENT version
                                    │
                             OCI Load Balancer :443
```

**Why this design**

| Choice | Reason |
| --- | --- |
| **DNS-01 challenge** | Only method that supports wildcards; no port 80 exposure needed |
| **OCI CLI hooks** (not `certbot-dns-oci`) | The PyPI plugin is stuck at v0.3.6 and breaks with current certbot |
| **Instance principal** | No API keys, no private keys, no secrets on disk |
| **OCI Certificates service** (not LB-uploaded bundles) | LB bundles are immutable and force a swap-and-delete on every renewal; managed certificates just get a new *version* the LB picks up on its own |

### Reference values used in this guide

Replace with your own.

| Item | Value |
| --- | --- |
| Domain | `bcpbruno.site` |
| Region | `sa-saopaulo-1` |
| Instance | Ubuntu, `aarch64` (Ampere) |
| Compartment OCID | `ocid1.compartment.oc1..aaaa...` |
| Identity domain | `OracleIdentityCloudService` |
| Dynamic group | `certbot-hosts` |
| OCI certificate name | `bcpbruno-site-le` |
| Load balancer public IP | `144....` |

---

## Step 1 — Prerequisites and verification

**A. Public DNS zone.** Console → *Networking → DNS management → Zones*. The zone must exist and
be of type **Public** (Let's Encrypt validates over public DNS).

**B. Delegation points at OCI.**

```bash
dig +short NS bcpbruno.site @8.8.8.8
```

Expect OCI nameservers:

```
ns1.p201.dns.oraclecloud.net.
ns2.p201.dns.oraclecloud.net.
ns3.p201.dns.oraclecloud.net.
ns4.p201.dns.oraclecloud.net.
```

If this returns your registrar's defaults, fix delegation before continuing — nothing else will work.

**C. Compartment OCID** where the zone lives.

**D. Instance facts.** Must be an **OCI compute instance** (instance principal only works inside OCI).

```bash
uname -m        # x86_64 or aarch64
```

**E. Outbound reachability to Let's Encrypt.**

```bash
curl -sI https://acme-v02.api.letsencrypt.org/directory | head -1     # expect HTTP/2 200
```

**F. Certificate names.** A wildcard `*.bcpbruno.site` covers `www.`, `api.`, etc. but **not** the
bare apex. Request both:

```
-d 'bcpbruno.site' -d '*.bcpbruno.site'
```

---

## Step 2 — Create the dynamic group

Get the instance OCID from the metadata service:

```bash
curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id; echo
```

Console (switch to your **home region** first) → *Identity & Security → Domains →
(your domain) → Dynamic groups → Create dynamic group*

- **Name:** `certbot-hosts`
- **Matching rule** (single-instance least privilege):

```
instance.id = 'ocid1.instance.oc1.sa-saopaulo-1.antxelj...'
```

Broader alternative if you prefer: `instance.compartment.id = '<compartment-OCID>'`.

---

## Step 3 — IAM policy

Console → *Identity & Security → Policies*, in the **root (tenancy)** compartment →
*Create Policy*. Name it `policy-certbot-dns01`:

```
Allow dynamic-group 'OracleIdentityCloudService'/'certbot-hosts' to read dns-zones in compartment id ocid1.compartment.oc1..aaaa...
Allow dynamic-group 'OracleIdentityCloudService'/'certbot-hosts' to manage dns-records in compartment id ocid1.compartment.oc1..aaaa...
Allow dynamic-group 'OracleIdentityCloudService'/'certbot-hosts' to manage leaf-certificate-family in compartment id ocid1.compartment.oc1..aaaa...
```

> ### ⚠️ The identity domain qualifier — most common failure
>
> Dynamic groups live inside an **identity domain**, and the policy must name it. Omitting the
> qualifier assumes `Default`.
>
> **Tenancies migrated from IDCS keep the name `OracleIdentityCloudService` instead of `Default`.**
> In that case an unqualified `dynamic-group 'certbot-hosts'` silently matches nothing, and every
> call fails with `NotAuthorizedOrNotFound` (HTTP 404) — while the policy still *saves* cleanly,
> because OCI permits forward references to non-existent groups.
>
> Verify which domain contains your group: *Identity & Security → Domains → (domain) → Dynamic groups*,
> and use that exact name.

`leaf-certificate-family` covers `leaf-certificates`, `leaf-certificate-versions`,
`leaf-certificate-bundles`, `cabundles`, `certificate-associations`, and `cabundle-associations` —
enough for both the initial import and every renewal.

**No load-balancer permission is needed.** The hooks only ever write to the certificate resource;
the LB pulls new versions itself.

> IAM changes take a few minutes to propagate. On a fresh `NotAuthorized`, wait ~5 minutes and retry
> before debugging.

---

## Step 4 — Install OCI CLI and certbot

### OCI CLI

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
exec -l $SHELL
oci --version
```

### certbot

```bash
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
certbot --version
```

### Make `oci` reachable by root

certbot runs as root, so `oci` must be on root's PATH:

```bash
sudo ln -sf "$(command -v oci)" /usr/local/bin/oci
```

### Validate the IAM chain before going further

```bash
export OCI_CLI_AUTH=instance_principal
export CERT_COMPARTMENT=ocid1.compartment.oc1..aaaa...
export ZONE="bcpbruno.site"
```

**Test A — read:**

```bash
oci dns zone list --compartment-id "$CERT_COMPARTMENT" --query "data[].name"
```

Expect `["bcpbruno.site"]`.

**Test B — write:**

```bash
oci dns record rrset update \
  --zone-name-or-id "$ZONE" \
  --domain "_acmetest.${ZONE}" \
  --rtype TXT \
  --items '[{"domain":"_acmetest.bcpbruno.site","rtype":"TXT","rdata":"oci-policy-test","ttl":30}]'

dig +short TXT _acmetest.bcpbruno.site @ns1.p201.dns.oraclecloud.net

oci dns record rrset delete \
  --zone-name-or-id "$ZONE" \
  --domain "_acmetest.${ZONE}" \
  --rtype TXT \
  --force
```

**Reading errors:**

| Symptom | Meaning |
| --- | --- |
| Local error, no `opc-request-id` | Instance principal not built — dynamic group rule doesn't match this instance |
| `NotAuthorizedOrNotFound` **with** `opc-request-id` | Authenticated but not authorized — wrong domain qualifier, wrong compartment, or propagation |
| HTTP 400 about rdata format | Authorization already passed; only a payload/quoting issue |

Also confirm root can use the CLI:

```bash
sudo OCI_CLI_AUTH=instance_principal oci dns zone list \
  --compartment-id "$CERT_COMPARTMENT" --query "data[].name"
```

---

## Step 5 — Auth and cleanup hooks

```bash
sudo mkdir -p /etc/letsencrypt/oci-hooks
```

**Auth hook** — adds the TXT value and waits for it to go live (certbot validates immediately after
the hook returns, so the wait must happen *inside* the hook):

```bash
sudo tee /etc/letsencrypt/oci-hooks/auth.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export OCI_CLI_AUTH=instance_principal

ZONE="bcpbruno.site"
NAME="_acme-challenge.${CERTBOT_DOMAIN}"
NS="ns1.p201.dns.oraclecloud.net"

oci dns record rrset patch \
  --zone-name-or-id "$ZONE" \
  --domain "$NAME" \
  --rtype TXT \
  --items "[{\"domain\":\"${NAME}\",\"rtype\":\"TXT\",\"rdata\":\"${CERTBOT_VALIDATION}\",\"ttl\":30,\"operation\":\"ADD\"}]" \
  >/dev/null

for _ in $(seq 1 60); do
  if dig +short TXT "$NAME" @"$NS" | grep -qF "$CERTBOT_VALIDATION"; then
    break
  fi
  sleep 5
done

sleep 15
EOF
```

**Cleanup hook** — removes exactly the value it added:

```bash
sudo tee /etc/letsencrypt/oci-hooks/cleanup.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export OCI_CLI_AUTH=instance_principal

ZONE="bcpbruno.site"
NAME="_acme-challenge.${CERTBOT_DOMAIN}"

oci dns record rrset patch \
  --zone-name-or-id "$ZONE" \
  --domain "$NAME" \
  --rtype TXT \
  --items "[{\"domain\":\"${NAME}\",\"rtype\":\"TXT\",\"rdata\":\"${CERTBOT_VALIDATION}\",\"ttl\":30,\"operation\":\"REMOVE\"}]" \
  >/dev/null || true
EOF

sudo chmod +x /etc/letsencrypt/oci-hooks/auth.sh /etc/letsencrypt/oci-hooks/cleanup.sh
```

> ### Why `patch` with ADD/REMOVE instead of `update`
>
> Requesting the apex **and** the wildcard produces **two DNS-01 challenges**, and for both of them
> `CERTBOT_DOMAIN` is `bcpbruno.site` (certbot strips the `*.`). Both write to the same
> `_acme-challenge.bcpbruno.site` name, and Let's Encrypt needs **both values present at once**.
>
> `rrset update` **replaces** the whole record set — the second challenge would erase the first.
> `rrset patch` with `operation: ADD` appends. Use `update` only for single-value records like A records.

---

## Step 6 — Staging dry run

`--dry-run` targets Let's Encrypt staging: real challenge flow, no rate limit consumption,
no real certificate. Always validate here first — production limits are tight.

```bash
sudo certbot certonly \
  --dry-run \
  --manual \
  --preferred-challenges dns-01 \
  --manual-auth-hook /etc/letsencrypt/oci-hooks/auth.sh \
  --manual-cleanup-hook /etc/letsencrypt/oci-hooks/cleanup.sh \
  --email you@example.com \
  --agree-tos \
  --no-eff-email \
  -d 'bcpbruno.site' -d '*.bcpbruno.site'
```

Expect: `The dry run was successful.`

TXT records briefly appear during the run (required even in staging) and are removed by the cleanup hook.

---

## Step 7 — Issue the production certificate

Same command, `--dry-run` removed:

```bash
sudo certbot certonly \
  --manual \
  --preferred-challenges dns-01 \
  --manual-auth-hook /etc/letsencrypt/oci-hooks/auth.sh \
  --manual-cleanup-hook /etc/letsencrypt/oci-hooks/cleanup.sh \
  --email you@example.com \
  --agree-tos \
  --no-eff-email \
  -d 'bcpbruno.site' -d '*.bcpbruno.site'
```

Output files:

| File | Contents |
| --- | --- |
| `/etc/letsencrypt/live/bcpbruno.site/cert.pem` | Leaf certificate only |
| `/etc/letsencrypt/live/bcpbruno.site/chain.pem` | Intermediate chain |
| `/etc/letsencrypt/live/bcpbruno.site/fullchain.pem` | Leaf + chain |
| `/etc/letsencrypt/live/bcpbruno.site/privkey.pem` | Private key |

Always reference the `live/` path — certbot repoints those symlinks on each renewal.

---

## Step 8 — Import into OCI Certificates and attach to the Load Balancer

### 8.1 Import

```bash
LIVE=/etc/letsencrypt/live/bcpbruno.site
export CERT_COMPARTMENT=ocid1.compartment.oc1..aaaa...

sudo oci certs-mgmt certificate create-by-importing-config \
  --auth instance_principal \
  --compartment-id "$CERT_COMPARTMENT" \
  --name "bcpbruno-site-le" \
  --certificate-pem "$(sudo cat $LIVE/cert.pem)" \
  --cert-chain-pem  "$(sudo cat $LIVE/chain.pem)" \
  --private-key-pem "$(sudo cat $LIVE/privkey.pem)"
```

> ### ⚠️ Three traps in this one command
>
> 1. **Do not use `file://`.** The OCI CLI only resolves `file://` for parameters it declares as
>    file-type. For these string parameters it passes the literal text through, and the service
>    replies `PEM File Certificate has incorrect format`. Use `"$(cat ...)"` — double quotes are
>    required to preserve newlines.
> 2. **`sudo cat` inside the substitution.** Command substitution runs as *your* user, and
>    `/etc/letsencrypt/live` is root-only — a bare `cat` yields empty strings silently.
> 3. **`--certificate-pem` takes `cert.pem`, not `fullchain.pem`.** Two certificates in that
>    parameter also trip the format validator. The intermediate belongs in `--cert-chain-pem`.
>
> An OCI certificate **name cannot contain `*`**, so the wildcard cert is named `bcpbruno-site-le`.

Verify and capture the OCID:

```bash
sudo oci certs-mgmt certificate list \
  --auth instance_principal \
  --compartment-id "$CERT_COMPARTMENT" \
  --name "bcpbruno-site-le" \
  --query "data.items[0].{Name:name, OCID:id, State:\"lifecycle-state\"}" \
  --output table

export CERT_ID=ocid1.certificate.oc1.sa-saopaulo-1.amaa...
```

Confirm the version and its stages:

```bash
sudo oci certs-mgmt certificate-version list --auth instance_principal \
  --certificate-id "$CERT_ID" \
  --query "data.items[].{Version:\"version-number\",Stages:stages}" --output table
```

Expect version `1` with stages `CURRENT` and `LATEST`.

### 8.2 Attach to the listener

Console → *Networking → Load balancers → (your LB) → Listeners* → edit the **443** listener →
select **Certificate service managed certificate** (not "Load balancer managed certificate") →
choose the compartment and `bcpbruno-site-le` → Save.

Requirements:
- The certificate must be in the **same region** as the load balancer.
- Attaching creates the *association*, which is what authorizes the LB to read the certificate and
  receive future versions.

### 8.3 Point DNS at the load balancer

The certificate is valid regardless, but traffic needs A records. DNS-01 never required them.

```bash
export OCI_CLI_AUTH=instance_principal
LB_IP=144.22.131.24

oci dns record rrset update \
  --zone-name-or-id bcpbruno.site \
  --domain bcpbruno.site \
  --rtype A \
  --items "[{\"domain\":\"bcpbruno.site\",\"rtype\":\"A\",\"rdata\":\"$LB_IP\",\"ttl\":300}]"

oci dns record rrset update \
  --zone-name-or-id bcpbruno.site \
  --domain www.bcpbruno.site \
  --rtype A \
  --items '[{"domain":"www.bcpbruno.site","rtype":"A","rdata":"144.22.131.24","ttl":300}]'
```

`update` (not `patch`) is correct here — A records should hold a single authoritative value.

### 8.4 Verify

```bash
dig +short A bcpbruno.site @8.8.8.8
dig +short A www.bcpbruno.site @8.8.8.8

echo | openssl s_client -connect bcpbruno.site:443 -servername bcpbruno.site 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

Expected:

```
issuer=C = US, O = Let's Encrypt, CN = YE1
subject=CN = bcpbruno.site
notBefore=Jun 29 23:50:47 2026 GMT
notAfter=Sep 27 23:50:46 2026 GMT
X509v3 Subject Alternative Name:
    DNS:*.bcpbruno.site, DNS:bcpbruno.site
```

`Could not find certificate from <stdin>` means the handshake never completed — a DNS or
connectivity problem, not a certificate problem. Diagnose by dropping `2>/dev/null`:

```bash
openssl s_client -connect bcpbruno.site:443 -servername bcpbruno.site </dev/null
```

| Error | Cause |
| --- | --- |
| `Name or service not known` | Missing A record (Step 8.3) |
| `Connection refused` / `timed out` | No 443 listener, or security list / NSG blocking 443 |

To test the LB directly, bypassing DNS:

```bash
openssl s_client -connect 144.22.131.24:443 -servername bcpbruno.site </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

---

## Step 9 — Automatic renewal (deploy hook)

Without this, certbot renews the files on disk but the load balancer keeps serving the old
certificate until it expires.

Scripts in `/etc/letsencrypt/renewal-hooks/deploy/` run automatically after every successful
renewal — no `--deploy-hook` flag needed anywhere.

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/oci-deploy.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/snap/bin"
export OCI_CLI_AUTH=instance_principal

CERT_ID="ocid1.certificate.oc1.sa-saopaulo-1.amaa..."
LINEAGE="${RENEWED_LINEAGE:?deploy hook must be run by certbot}"

oci certs-mgmt certificate update-certificate-by-importing-config-details \
  --certificate-id "$CERT_ID" \
  --certificate-pem "$(cat "$LINEAGE/cert.pem")" \
  --cert-chain-pem  "$(cat "$LINEAGE/chain.pem")" \
  --private-key-pem "$(cat "$LINEAGE/privkey.pem")" \
  --force

logger -t certbot-oci "Imported renewed cert for ${RENEWED_DOMAINS:-unknown} into ${CERT_ID}"
EOF

sudo chmod 700 /etc/letsencrypt/renewal-hooks/deploy/oci-deploy.sh
```

**Three deliberate choices:**

- **`CERT_ID` hardcoded.** Common examples derive the OCI certificate name from `$RENEWED_DOMAINS`,
  but for a wildcard that variable is the two-name string `bcpbruno.site *.bcpbruno.site`, and `*`
  is not legal in an OCI certificate name. Pinning the OCID is unambiguous — and immune to shell
  environment problems.
- **Explicit `PATH`.** Renewal runs under a systemd timer with a minimal environment; without this,
  `oci` isn't found — a silent renewal failure.
- **`--force`.** Skips the interactive confirmation that would hang an unattended run.

### Test the hook standalone (no ACME traffic)

```bash
sudo RENEWED_LINEAGE=/etc/letsencrypt/live/bcpbruno.site \
     RENEWED_DOMAINS="bcpbruno.site *.bcpbruno.site" \
     /etc/letsencrypt/renewal-hooks/deploy/oci-deploy.sh

sudo oci certs-mgmt certificate-version list --auth instance_principal \
  --certificate-id "$CERT_ID" \
  --query "data.items[].{Version:\"version-number\",Stages:stages}" --output table
```

Success = a **new version number carrying `CURRENT`**. That promotion is precisely the signal the
load balancer's agent polls for.

### Full end-to-end rehearsal

```bash
sudo certbot renew --dry-run --run-deploy-hooks
```

`--dry-run` uses staging; `--run-deploy-hooks` forces the deploy hook to run (dry runs normally skip
it). This exercises auth hook → challenge → cleanup hook → deploy hook in one pass.

Expect `Congratulations, all simulated renewals succeeded` plus the hook's JSON showing the new
version with `"stages": ["CURRENT"]`.

> Two normal-but-odd observations: `"lifecycle-state": "UPDATING"` is transient (re-query for
> `ACTIVE`), and the new version carries the **same** dates and serial as the previous one — a dry
> run writes no new files, so the hook re-imported the current certificate. A real renewal produces
> fresh dates.

### Confirm the timer

```bash
systemctl list-timers | grep -i certbot
sudo certbot certificates
sudo grep -E "auth|cleanup" /etc/letsencrypt/renewal/bcpbruno.site.conf
```

The snap timer runs twice daily; the `.conf` must list both hook paths.

---

## Operating notes

**Renewal flow, fully unattended.** At ~30 days remaining: timer fires → auth hook writes challenge
TXT records via instance principal → Let's Encrypt issues → deploy hook imports a new version →
LB agent picks up the new CURRENT version within minutes. No listener edit, no downtime, no secrets.

**Set an expiry alarm.** The failure mode of unattended automation is silence. Use OCI Certificates
metrics or a Cloud Guard detector for expiring certificates, set at ~20 days remaining — that gives
three weeks of runway instead of a browser warning.

**Verify after a real renewal:**

```bash
echo | openssl s_client -connect bcpbruno.site:443 -servername bcpbruno.site 2>/dev/null \
  | openssl x509 -noout -dates
```

A `notAfter` roughly 90 days out means the whole chain ran on its own.

**Don't use `--force-renewal` to test.** Let's Encrypt caps duplicate certificates at 5 per week.
The standalone deploy-hook test proves the same thing at no cost.

**Leave old certificate versions in place.** The LB tracks `CURRENT`; pruning buys nothing.

---

## Troubleshooting quick reference

| Symptom | Cause | Fix |
| --- | --- | --- |
| `NotAuthorizedOrNotFound` (404) on every OCI call | Wrong identity domain qualifier in the policy | Use the domain that actually holds the group, e.g. `'OracleIdentityCloudService'/'certbot-hosts'` |
| Policy saved but nothing works | OCI allows forward references to non-existent groups — a clean save proves nothing | Verify the group name *and* its domain |
| `PEM File Certificate has incorrect format` | `file://` used, or `fullchain.pem` passed to `--certificate-pem` | Use `"$(sudo cat ...)"` and `cert.pem` |
| `compartmentId size must be between 1 and 255` | Shell variable empty (e.g. set inside a `sudo -i` session) | `echo "$VAR"` before use; persist exports in `~/.bashrc` |
| `404` on `list_load_balancers` / `list_associations` | Instance principal has no LB permission — by design | Verify in the console; or add `read load-balancers` if you want the CLI check |
| `Query returned empty result` on `record zone get` | Results are paginated | Add `--all` |
| `Could not find certificate from <stdin>` | Handshake failed before any certificate was sent | Check A records, 443 listener, security list / NSG |
| Second DNS-01 challenge overwrites the first | `rrset update` used in the auth hook | Use `rrset patch` with `operation: ADD` / `REMOVE` |
| Renewal succeeds but LB serves the old certificate | Deploy hook missing or `oci` not on PATH | Add the hook with an explicit `PATH` |
| Markdown auto-linking mangles a domain in a command | Pasted `www.x.com` became `[www.x.com](https://www.x.com)` | Wrap domains in single quotes when pasting |