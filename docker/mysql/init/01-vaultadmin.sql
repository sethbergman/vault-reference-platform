-- The account Vault connects as, created at first start.
--
-- Vault needs CREATE USER and GRANT OPTION to issue credentials, which an
-- ordinary per-database account does not have. The obvious shortcut is to
-- point Vault at root -- but the bootstrap rotates the password of
-- whatever account it connects with, and root's password is also what
-- this container's healthcheck uses. Rotating it would leave the
-- container permanently unhealthy while MySQL itself was fine, which is
-- the sort of failure that costs an hour to understand.
--
-- So Vault gets its own privileged account. Rotating this one affects
-- nothing else, and it mirrors what the Postgres profile already does.
CREATE USER IF NOT EXISTS 'vaultadmin'@'%'
    IDENTIFIED BY 'bootstrap-only-rotated-immediately';

-- ON *.* because CREATE USER is a global privilege -- it cannot be
-- granted per-database. WITH GRANT OPTION because Vault has to grant the
-- issued users their rights on appdata, and MySQL forbids granting a
-- privilege you do not hold with that option.
--
-- This account is as privileged as root. That is inherent to what it
-- does, and the mitigation is that its password is rotated on bootstrap
-- and known only to Vault afterwards.
GRANT ALL PRIVILEGES ON *.* TO 'vaultadmin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
