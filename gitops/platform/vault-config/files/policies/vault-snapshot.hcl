# The backup job (gitops/platform/backups): takes Raft snapshots, nothing else.
# A snapshot holds Vault's encrypted storage; it is useless without the KMS key.
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
