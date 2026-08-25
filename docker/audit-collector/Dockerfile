# Audit collector: receives Vault's socket audit stream and hash-chains
# it as it arrives. See collect.sh for what the chain buys and anchor.sh
# for what it does not.
#
# Previously this was the stock alpine/socat image with an OPEN: target.
# That appended bytes and offered no way to tell whether the bytes were
# still the ones Vault sent.
FROM alpine:3.20

# socat    — the listener, as before
# coreutils — sha256sum with predictable output across busybox versions
#
# No util-linux: the lock is built from mkdir rather than flock, so the
# collector has one code path everywhere and cannot silently degrade to
# running unserialised when the binary is absent. See collect.sh.
RUN apk add --no-cache socat coreutils

COPY collect.sh /usr/local/bin/collect.sh
COPY anchor.sh  /usr/local/bin/anchor.sh
RUN chmod +x /usr/local/bin/collect.sh /usr/local/bin/anchor.sh

# -u is unidirectional: data flows from the socket into the program and
# nothing is ever written back to Vault. An audit collector that can talk
# back to the thing it audits is a channel nobody asked for.
#
# fork gives each connection its own collect.sh; the lock inside keeps
# their appends ordered.
ENTRYPOINT ["socat", "-u", "TCP-LISTEN:9090,fork,reuseaddr", \
            "EXEC:/usr/local/bin/collect.sh"]
