# The snapshot agent, and nothing else.
#
# scripts/snapshot.sh runs on every node on a timer, works out whether it
# is the leader, and if it is, takes a Raft snapshot and ships it. This
# is the policy its AppRole gets. A snapshot is every secret in the
# cluster in one file, so the credential that can take one is worth
# keeping narrow.
#
# Not granted, deliberately:
#
#   - Anything under secret/ or any other mount. The agent never reads a
#     secret; it reads the whole store as an opaque blob and uploads it.
#     A policy that could do both would make a compromised snapshot
#     credential a way to browse.
#   - sys/storage/raft/snapshot-force, which restores. Taking a backup
#     and overwriting the cluster with one are different jobs, and the
#     scheduled one has no business doing the second.
#   - Anything under sys/ beyond the two paths below.

# Reading this path *is* taking the snapshot: the response body is the
# snapshot itself.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# The timer fires on all three nodes and only the leader does the work,
# so each has to be able to ask which it is. sys/leader is
# unauthenticated in a default Vault, and snapshot.sh reads it before
# logging in for exactly that reason -- this entry is here so the policy
# still describes what the agent touches if that ever changes.
path "sys/leader" {
  capabilities = ["read"]
}
