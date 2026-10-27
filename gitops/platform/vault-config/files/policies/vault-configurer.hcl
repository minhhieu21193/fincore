# The configuration Job: may manage auth methods, policies, audit devices and the
# database secrets engine. It cannot read secrets or issue database credentials.
path "sys/auth"                    { capabilities = ["read"] }
path "sys/auth/*"                  { capabilities = ["create", "update", "read", "sudo"] }
path "sys/mounts"                  { capabilities = ["read"] }
path "sys/mounts/*"                { capabilities = ["create", "update", "read"] }
path "sys/audit"                   { capabilities = ["read", "sudo"] }
path "sys/audit/*"                 { capabilities = ["create", "update", "sudo"] }
path "sys/policies/acl/*"          { capabilities = ["create", "update", "read"] }
path "auth/kubernetes/config"      { capabilities = ["create", "update", "read"] }
path "auth/kubernetes/role/*"      { capabilities = ["create", "update", "read"] }
path "database/config/*"           { capabilities = ["create", "update", "read"] }
path "database/roles/*"            { capabilities = ["create", "update", "read"] }
path "database/rotate-root/*"      { capabilities = ["update"] }
