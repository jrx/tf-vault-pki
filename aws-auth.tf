# Create PKI policy
resource "vault_policy" "pki" {
  namespace = vault_namespace.tenant_namespace.path_fq
  name      = "pki"
  policy    = <<EOT
path "pki/issue/{{identity.entity.metadata.BusinessSegmentName}}" {
  capabilities = ["create", "update"]
}
EOT
}

# Enable AWS auth method
resource "vault_auth_backend" "aws" {
  namespace = vault_namespace.tenant_namespace.path_fq
  type      = "aws"
}

# # Configure AWS auth client
resource "vault_aws_auth_backend_client" "config" {
  namespace = vault_namespace.tenant_namespace.path_fq
  backend   = vault_auth_backend.aws.path
}

# Configure identity parameters
resource "vault_aws_auth_backend_config_identity" "aws" {
  namespace    = vault_namespace.tenant_namespace.path_fq
  backend      = vault_auth_backend.aws.path
  iam_alias    = "unique_id"
  iam_metadata = ["canonical_arn", "account_id"]
}

# Create AWS auth role
resource "vault_aws_auth_backend_role" "my-app" {
  namespace            = vault_namespace.tenant_namespace.path_fq
  backend              = vault_auth_backend.aws.path
  role                 = "my-app-role"
  auth_type            = "iam"
  bound_account_ids    = [var.aws-auth-account-id]
  inferred_entity_type = "ec2_instance"
  inferred_aws_region  = var.aws-auth-region
  token_ttl            = 86400 # 24 hours in seconds
  token_policies       = [vault_policy.pki.name]
  #bound_iam_principal_arns = ["arn:aws:iam::143332470013:role/jrx-test-ansible-role"]
}

# Create entity with metadata
resource "vault_identity_entity" "my-app" {
  namespace = vault_namespace.tenant_namespace.path_fq
  name      = "my-app"
  metadata = {
    AppName               = "my-app"
    BusinessUnitName      = "tenant-1"
    BusinessSegmentName   = "team-a"
    EmailDistributionList = "team-a@example.com"
    TLSDomain             = "foo.tenant-1.example.com"
  }
}

# Create entity alias
resource "vault_identity_entity_alias" "aws_role" {
  namespace      = vault_namespace.tenant_namespace.path_fq
  name           = var.aws-auth-unique-id
  mount_accessor = vault_auth_backend.aws.accessor
  canonical_id   = vault_identity_entity.my-app.id
}