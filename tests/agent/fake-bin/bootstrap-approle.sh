#!/usr/bin/env bash
# Stand-in for the AppRole bootstrap the agent script composes.
set -uo pipefail
printf 'approle %s\n' "$*" >> "${FAKE_LOG}"
exit "${FAKE_APPROLE_RC:-0}"
