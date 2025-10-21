# README — Bulk CSR Generation (Linux) & Microsoft CA Signing (Windows)

> This guide explains how to:
>
> 1. Generate password-protected private keys and CSRs in bulk from a CSV list on Linux, and
> 2. Sign those CSRs with a Microsoft Enterprise CA on Windows using a **custom template** that preserves SANs and includes both **Server** and **Client Authentication** EKUs.
>
> **Note:** All examples use **sample data** (example domains/IPs). Replace with your own.

---

## 1) What you’ll get

* **On Linux**

  * `/tmp/auto-tls/keys/<host>-key.pem` (RSA-4096, password-protected)
  * `/tmp/auto-tls/csrs/<host>.csr`
* **On Windows**

  * `Issued\<host>.cer` (issued by Microsoft CA)
  * `ca-chain.pem` 

---



## 2) On-Linux Prepare sample CSV

Use your own CSV, but here’s a safe example (replace later with real hosts/IPs):

```bash
vim hosts.csv
```
>  hosts.csv  (comment lines allowed, will be ignored by the script)

```csv
utility1.example.local,10.0.0.11
utility2.example.local,10.0.0.12
worker1.example.local,10.0.0.21
worker2.example.local,10.0.0.22
master1.example.local,10.0.0.31
master2.example.local,10.0.0.32
gateway1.example.local,10.0.0.41
gateway2.example.local,10.0.0.42
kts1.example.local,10.0.0.51
kts2.example.local,10.0.0.52
kms1.example.local,10.0.0.61
kms2.example.local,10.0.0.62
```

---

## 3) Generate keys & CSRs on Linux

> Update the **Subject** fields to your real organization as needed.

```bash
vim gen-csrs.sh
```

```bash
#!/usr/bin/env bash
set -euo pipefail

CSV=${1:-./hosts.csv}   # file with: fqdn,ip per line
mkdir -p /tmp/auto-tls/{keys,csrs}
[[ -f /tmp/auto-tls/keys/key.pwd ]] || echo 'KeyPassword#2026' > /tmp/auto-tls/keys/key.pwd
chmod 600 /tmp/auto-tls/keys/key.pwd

while IFS=, read -r HOSTNAME NODE_IP; do
  [[ -z "${HOSTNAME:-}" || -z "${NODE_IP:-}" ]] && continue
  [[ "$HOSTNAME" =~ ^# ]] && continue
  SHORT="${HOSTNAME%%.*}"

  echo "Generating key+CSR for ${HOSTNAME} (${NODE_IP}) ..."
  openssl req -newkey rsa:4096 -sha256 \
    -keyout "/tmp/auto-tls/keys/${HOSTNAME}-key.pem" \
    -out "/tmp/auto-tls/csrs/${HOSTNAME}.csr" \
    -passout file:/tmp/auto-tls/keys/key.pwd \
    -subj "/C=EG/ST=Cairo/L=Almazah/O=Example Corp/OU=Platform/CN=${HOSTNAME}" \
    -extensions san -config <( \
      echo '[req]'; \
      echo 'distinguished_name=req'; \
      echo 'req_extensions=san'; \
      echo '[san]'; \
      echo "subjectAltName=DNS:${HOSTNAME}, DNS:${SHORT}, DNS:localhost, IP:${NODE_IP}, IP:127.0.0.1"; \
      echo 'extendedKeyUsage = serverAuth, clientAuth' )

  # sanity check
  openssl req -in "/tmp/auto-tls/csrs/${HOSTNAME}.csr" -noout -text | egrep -A2 'Subject:|Subject Alternative Name|Extended Key Usage' || true
  sleep 1
done < "$CSV"

echo "All CSRs under /tmp/auto-tls/csrs and keys under /tmp/auto-tls/keys"
```

Save the script you already have as 
`gen-csrs.sh`, then run:

```bash
chmod +x gen-csrs.sh
./gen-csrs.sh ./hosts.csv
```

### What the script does (summary)

* Creates directories: `/tmp/auto-tls/keys` and `/tmp/auto-tls/csrs`
* Creates a key password file: `/tmp/auto-tls/keys/key.pwd` (edit the value if needed)
* For each `fqdn,ip`:

  * Generates an **RSA-4096** private key (password-protected)
  * Generates a CSR with:

    * **Subject**: `/C=EG/ST=Cairo/L=Almazah/O=Example Corp/OU=Platform/CN=<fqdn>`
      *(Feel free to change C/ST/L/O/OU to your real org data)*
    * **SANs**: `DNS:<fqdn>, DNS:<shortname>, DNS:localhost, IP:<ip>, IP:127.0.0.1`
    * **EKUs**: ServerAuth, ClientAuth
* Prints a quick CSR sanity check (Subject, SAN, EKU)

**Outputs**

* Keys → `/tmp/auto-tls/keys/`
* CSRs → `/tmp/auto-tls/csrs/`

> 🔒 **Security tip:** The key password is stored in a file (`key.pwd`). Restrict its permissions and rotate it later.

---

## 4) Create & publish a Microsoft CA template (one-time)

1. On a CA server: `certtmpl.msc`
2. Right-click **Web Server** → **Duplicate Template**
3. Configure:

   * **General**: Name it `AutoTLS` (or anything you like)
   * **Subject Name**: **Supply in the request**
   * **Extensions → Application Policies**: ensure **Server Authentication** and **Client Authentication** are present
   * **Request Handling**: (Optional) allow private key export if your policy requires it
   * **Security**: grant **Enroll** to the account/group that will request certs
4. Save.
5. Open `certsrv.msc` → **Certificate Templates** → **New** → **Certificate Template to Issue** → select your new template (e.g., `AutoTLS`).

> ❗ If **Supply in the request** is not enabled, the CA may ignore your CSR’s SANs, and your issued certificates will be missing SAN entries.

---

## 5) Transfer CSRs to the Windows machine

Copy `/tmp/auto-tls/csrs/*.csr` to a folder on your Windows admin workstation, e.g.:

```
C:\CSR
```

---

## 6) Sign CSRs with the Microsoft CA

Use the PowerShell script you provided (save as `sign-all-csr.ps1`).

```powershell
<# 
Sign all CSRs in a folder using a Microsoft CA template, then export .pem and verify EKU/SAN.

Usage examples:
  # Recommended: specify your CA "config" name (from `certutil -config - - -`):
  .\sign-all-csr.ps1 -CsrFolder C:\CSR -OutFolder C:\CSR\Issued -TemplateName "AutoTLS" -CAName "corp-CA\IssuingCA"

  # If you omit -CAName you'll get the CA selection dialog once; after first issue it will remember.
  .\sign-all-csr.ps1 -TemplateName "AutoTLS"
#>

param(
  [string]$CsrFolder    = "C:\CSR",
  [string]$OutFolder    = "C:\CSR\Issued",
  [string]$TemplateName = "AutoTLS",
  [string]$CAName       = "corp-CA\IssuingCA"
)

if (-not (Test-Path $OutFolder)) {
  New-Item -ItemType Directory -Path $OutFolder | Out-Null
}

$csrs = Get-ChildItem -Path $CsrFolder -Filter *.csr -File
if (-not $csrs) {
  Write-Host "No .csr files found in $CsrFolder" -ForegroundColor Yellow
  exit 1
}

function Submit-Csr {
  param(
    [Parameter(Mandatory=$true)][string]$CsrPath,
    [Parameter(Mandatory=$true)][string]$OutCerPath,
    [Parameter(Mandatory=$true)][string]$TemplateName,
    [string]$CAName = ""
  )

  Write-Host "Submitting CSR: $([IO.Path]::GetFileName($CsrPath))" -ForegroundColor Cyan
  $attrib = "CertificateTemplate:$TemplateName"

  if ([string]::IsNullOrEmpty($CAName)) {
    certreq -submit -attrib $attrib $CsrPath $OutCerPath | Out-Null
  } else {
    certreq -submit -attrib $attrib -config $CAName $CsrPath $OutCerPath | Out-Null
  }

  if (-not (Test-Path $OutCerPath)) {
    Write-Host "  ✖ Failed to issue certificate for $CsrPath" -ForegroundColor Red
    return $false
  }

  Write-Host "  ✔ Issued: $OutCerPath" -ForegroundColor Green

  $OutPemPath = [IO.Path]::ChangeExtension($OutCerPath, ".pem")
  certutil -encode $OutCerPath $OutPemPath | Out-Null
  Write-Host "  ✔ PEM   : $OutPemPath" -ForegroundColor Green

  $dump = certutil -dump $OutCerPath
  $eku  = ($dump | Select-String -SimpleMatch "Enhanced Key Usage").Line
  $san  = ($dump | Select-String -SimpleMatch "Subject Alternative Name").Line

  if ($eku) { Write-Host "  EKU -> $eku" -ForegroundColor DarkGray }
  if ($san) { Write-Host "  SAN -> $san" -ForegroundColor DarkGray }

  return $true
}

$ok = 0; $fail = 0
foreach ($csr in $csrs) {
  $outCer = Join-Path $OutFolder ($csr.BaseName + ".cer")
  if (Submit-Csr -CsrPath $csr.FullName -OutCerPath $outCer -TemplateName $TemplateName -CAName $CAName) {
    $ok++
  } else {
    $fail++
  }
}

Write-Host ""
Write-Host "Done. Issued: $ok, Failed: $fail" -ForegroundColor Cyan
Write-Host "Certificates: $OutFolder" -ForegroundColor Cyan
```

---


```powershell
.\sign-all-csr.ps1 `
  -CsrFolder "C:\CSR" `
  -OutFolder "C:\CSR\Issued" `
  -TemplateName "AutoTLS" `
  -CAName "corp-CA-fqdn\IssuingCA"
```

* If you omit `-CAName`, Windows may prompt you once to pick a CA; the script will reuse it.

**Outputs** (for each CSR):

* `C:\CSR\Issued\<host>.cer` (issued certificate)
* `C:\CSR\Issued\<host>.pem` (Base64 PEM)

It also prints a quick **EKU** and **SAN** check via `certutil -dump`.

---

## 7) Export CA chain & build bundles

Export the issuing CA chain to PEM (handy for Java/Unix services):


You can then assemble:

* **Server cert**: `<host>.cer` (from the earlier step)
* **Server key**: from Linux (`<host>-key.pem`)
* **Chain**: `ca-chain.pem`
---

## 8) Verify issued certificates (Linux or Windows)

### On Linux

```bash
# Copy back one issued cert for inspection:
openssl x509 -in /path/to/<host>.cer -noout -text | egrep -A2 "Subject:|Subject Alternative Name|Extended Key Usage"

# Verify key ↔ cert match (prompts for key password)
openssl x509 -noout -modulus -in <host>.cer | openssl md5
openssl rsa -noout -modulus -in <host>-key.pem -passin file:/tmp/auto-tls/keys/key.pwd | openssl md5

# Should be identical hashes
```

### On Windows

```powershell
certutil -dump "C:\CSR\Issued\<host>.cer"
```

Confirm:

* **Subject CN** = FQDN you requested
* **SANs** include `DNS`/`IP` as requested
* **Enhanced Key Usage** shows **Server Authentication** and **Client Authentication**

---

## 9) Deploy

Typical files per host:

* **Private key**: `<host>-key.pem` (restrict to owner: `chmod 600`)
* **Certificate**: `<host>.pem` (or `<host>.cer` depending on your service)
* **CA chain**: `ca-chain.pem`, if your service requires presenting the chain

> ⚠️ Never leave the key password file on shared systems. Rotate/secure it per your policy.

---
