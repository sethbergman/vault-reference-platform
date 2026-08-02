# Architecture

## High availability topology

```mermaid
flowchart TD
    U[Users / Applications] --> LB[Load Balancer]
    LB --> V1[Vault Node 1]
    LB --> V2[Vault Node 2]
    LB --> V3[Vault Node 3]
    V1 <--> V2
    V2 <--> V3
    V1 <--> V3
    V1 --> R[(Raft Integrated Storage)]
    V2 --> R
    V3 --> R
    R --> S[Snapshot / Backup Storage]
    V1 --> AU[Auto-Unseal - Cloud KMS]
    V2 --> AU
    V3 --> AU
```

## Notes

- **Storage backend**: Raft integrated storage is used instead of an
  external Consul cluster, to keep the operational surface area smaller
  for a reference deployment.
- **Auto-unseal**: production nodes use a cloud KMS (AWS KMS / Azure Key
  Vault) for auto-unseal; the local Docker Compose profile uses Shamir
  shares for simplicity, documented in `docs/deployment.md`.
- **Load balancer**: health-checks the Vault `/v1/sys/health` endpoint so
  standby nodes aren't sent client traffic that requires an active leader.
- **Backups**: scheduled Raft snapshots are shipped to object storage; see
  `docs/disaster-recovery.md` for restore procedure.
