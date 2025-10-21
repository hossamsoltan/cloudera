<# 
Sign all CSRs in a folder using a Microsoft CA template .cer, then export .pem and verify EKU/SAN.
#>

param(
  [string]$CsrFolder    = "C:\Users\Administrator\Desktop\csr",
  [string]$OutFolder    = "C:\Users\Administrator\Desktop\csr\Issued",
  [string]$TemplateName = "ClouderaAutoTLS",
  [string]$CAName       = ""                  #"dc.bigdata.local\bigdata"     # e.g. "org-host-CA\YourCAName" from `certutil -config - - -`
)

# Create output folder
if (-not (Test-Path $OutFolder)) {
  New-Item -ItemType Directory -Path $OutFolder | Out-Null
}

# Gather CSRs
$csrs = Get-ChildItem -Path $CsrFolder -Filter *.csr -File
if (-not $csrs) {
  Write-Host "No .csr files found in $CsrFolder" -ForegroundColor Yellow
  exit 1
}

# Helper: submit one CSR, save .cer, export .pem, verify EKU/SAN
function Submit-Csr {
  param(
    [Parameter(Mandatory=$true)][string]$CsrPath,
    [Parameter(Mandatory=$true)][string]$OutCerPath,
    [Parameter(Mandatory=$true)][string]$TemplateName,
    [string]$CAName = ""
  )

  Write-Host "Submitting CSR: $([IO.Path]::GetFileName($CsrPath))" -ForegroundColor Cyan

  $attrib = "CertificateTemplate:$TemplateName"

  # Build certreq command
  if ([string]::IsNullOrEmpty($CAName)) {
    # No -config → you may get one CA selection dialog the first time
    certreq -submit -attrib $attrib $CsrPath $OutCerPath | Out-Null
  } else {
    certreq -submit -attrib $attrib -config $CAName $CsrPath $OutCerPath | Out-Null
  }

  if (-not (Test-Path $OutCerPath)) {
    Write-Host "  ✖ Failed to issue certificate for $CsrPath" -ForegroundColor Red
    return $false
  }

  Write-Host "  ✔ Issued: $OutCerPath" -ForegroundColor Green

  # Export .pem (Base64)
  $OutPemPath = [IO.Path]::ChangeExtension($OutCerPath, ".pem")
  certutil -encode $OutCerPath $OutPemPath | Out-Null
  Write-Host "  ✔ PEM   : $OutPemPath" -ForegroundColor Green

  # Quick EKU / SAN verification
  $dump = certutil -dump $OutCerPath
  $eku  = ($dump | Select-String -SimpleMatch "Enhanced Key Usage").Line
  $san  = ($dump | Select-String -SimpleMatch "Subject Alternative Name").Line

  if ($eku) { Write-Host "  EKU -> $eku" -ForegroundColor DarkGray }
  if ($san) { Write-Host "  SAN -> $san" -ForegroundColor DarkGray }

  return $true
}

# Process all CSRs
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
