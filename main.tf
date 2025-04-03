# Create tenant namespace
resource "vault_namespace" "tenant_namespace" {
  path = var.vault-tenant-namespace
}

# Vault Signing CA
resource "vault_managed_keys" "vault_signing_ca" {
  aws {
    name               = "vault-signing-ca-key"
    access_key         = ""
    secret_key         = ""
    kms_key            = "alias/vault-signing-ca-key"
    key_type           = "ECDSA"
    key_bits           = ""
    curve              = "P384"
    allow_generate_key = true
  }
}

resource "vault_mount" "pki" {
  path                      = "pki"
  type                      = "pki"
  description               = "PKI engine for the Vault Signing CA"
  default_lease_ttl_seconds = 157680000 # 5 years
  max_lease_ttl_seconds     = 157680000
  allowed_managed_keys = [
    tolist(vault_managed_keys.vault_signing_ca.aws)[0].name,
  ]
}

resource "vault_pki_secret_backend_root_cert" "vault_signing_ca" {
  depends_on           = [vault_mount.pki]
  backend              = vault_mount.pki.path
  type                 = "internal"
  common_name          = "vault.ca.example.com"
  ttl                  = 157680000
  format               = "pem"
  private_key_format   = "der"
  key_type             = "ec"
  key_bits             = 384
  exclude_cn_from_sans = false
  max_path_length      = "1"
  managed_key_name     = tolist(vault_managed_keys.vault_signing_ca.aws)[0].name
  issuer_name          = "vault-signing-ca"
}

resource "vault_pki_secret_backend_config_cluster" "vault_signing_ca" {
  backend  = vault_mount.pki.path
  path     = "https://127.0.0.1:8200/v1/${var.vault-parent-namespace}/pki"
  aia_path = "https://127.0.0.1:8200/v1/${var.vault-parent-namespace}/pki"
}

resource "vault_pki_secret_backend_config_urls" "vault_signing_ca" {
  backend = vault_mount.pki.path
  issuing_certificates = [
    "{{cluster_aia_path}}/issuer/{{issuer_id}}/der",
  ]
  crl_distribution_points = [
    "{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der",
  ]
  ocsp_servers = [
    "{{cluster_path}}/ocsp",
  ]
  enable_templating = true
}

# Tenant Issuing CA
resource "vault_managed_keys" "tenant_issuing_ca" {
  namespace = vault_namespace.tenant_namespace.path_fq
  aws {
    name               = "tenant-1-issuing-ca-key"
    access_key         = ""
    secret_key         = ""
    kms_key            = "alias/tenant-1-issuing-ca-key"
    key_type           = "ECDSA"
    key_bits           = ""
    curve              = "P384"
    allow_generate_key = true
  }
}

resource "vault_mount" "tenant_issuing_ca" {
  namespace                 = vault_namespace.tenant_namespace.path_fq
  path                      = "pki"
  type                      = vault_mount.pki.type
  description               = "PKI engine for the Tenant Issuing CA"
  default_lease_ttl_seconds = 78840000 # 2.5 years
  max_lease_ttl_seconds     = 78840000
  allowed_managed_keys = [
    tolist(vault_managed_keys.tenant_issuing_ca.aws)[0].name,
  ]
}

resource "vault_pki_secret_backend_intermediate_cert_request" "tenant_issuing_ca" {
  namespace        = vault_namespace.tenant_namespace.path_fq
  backend          = vault_mount.tenant_issuing_ca.path
  type             = vault_pki_secret_backend_root_cert.vault_signing_ca.type
  common_name      = "tenant-1.ca.example.com"
  managed_key_name = tolist(vault_managed_keys.vault_signing_ca.aws)[0].name
}

resource "vault_pki_secret_backend_root_sign_intermediate" "tenant_issuing_ca" {
  backend              = vault_mount.pki.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.tenant_issuing_ca.csr
  common_name          = "tenant-1.ca.example.com"
  exclude_cn_from_sans = false
  revoke               = true
  max_path_length      = "0"
  ttl                  = 78840000
}

resource "vault_pki_secret_backend_intermediate_set_signed" "tenant_issuing_ca" {
  namespace   = vault_namespace.tenant_namespace.path_fq
  backend     = vault_mount.tenant_issuing_ca.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.tenant_issuing_ca.certificate
}

resource "vault_pki_secret_backend_config_cluster" "tenant_issuing_ca" {
  namespace = vault_namespace.tenant_namespace.path_fq
  backend   = vault_mount.tenant_issuing_ca.path
  path      = "https://127.0.0.1:8200/v1/${var.vault-parent-namespace}/${var.vault-tenant-namespace}/pki"
  aia_path  = "https://127.0.0.1:8200/v1/${var.vault-parent-namespace}/${var.vault-tenant-namespace}/pki"
}

resource "vault_pki_secret_backend_config_urls" "tenant_issuing_ca" {
  namespace = vault_namespace.tenant_namespace.path_fq
  backend   = vault_mount.tenant_issuing_ca.path
  issuing_certificates = [
    "{{cluster_aia_path}}/issuer/{{issuer_id}}/der",
  ]
  crl_distribution_points = [
    "{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der",
  ]
  ocsp_servers = [
    "{{cluster_path}}/ocsp",
  ]
  enable_templating = true
}

# Unified CRL and Cross-Cluster Revocations
resource "vault_pki_secret_backend_crl_config" "crl_config" {
  namespace                     = vault_namespace.tenant_namespace.path_fq
  backend                       = vault_mount.tenant_issuing_ca.path
  auto_rebuild                  = true
  auto_rebuild_grace_period     = "12h" # Optional, defaults to 12h
  unified_crl                   = true
  unified_crl_on_existing_paths = true
  cross_cluster_revocation      = true
}

# Tidying
resource "vault_pki_secret_backend_config_auto_tidy" "pki_auto_tidy" {
  namespace          = vault_namespace.tenant_namespace.path_fq
  backend            = vault_mount.tenant_issuing_ca.path
  enabled            = true
  interval_duration  = "24h"
  tidy_cert_store    = true
  tidy_revoked_certs = true
  tidy_cert_metadata = true
}

# Team role
resource "vault_pki_secret_backend_role" "team-a" {
  namespace         = vault_namespace.tenant_namespace.path_fq
  backend           = vault_mount.tenant_issuing_ca.path
  name              = "team-a"
  allowed_domains   = ["tenant-1.example.com", "test.example.com"]
  allow_subdomains  = true
  key_type          = "ec"
  key_bits          = 256
  max_ttl           = 2592000
  no_store          = true
  generate_lease    = false
  no_store_metadata = false
}

# Sentinel EGP
resource "vault_egp_policy" "restrict-common-name" {
  namespace         = vault_namespace.tenant_namespace.path_fq
  name              = "restrict-common-name"
  paths             = ["pki/issue/team-a"]
  enforcement_level = "hard-mandatory"

  policy = file("${path.module}/pki.sentinel")
}
