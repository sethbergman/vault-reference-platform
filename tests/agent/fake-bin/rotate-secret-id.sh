#!/usr/bin/env bash
# Stand-in for the secret_id rotation the agent script composes.
set -uo pipefail
printf 'rotate %s\n' "$*" >> "${FAKE_LOG}"
# FAKE_ROTATE_NOISY models the case that distinguishes the exit-code
# check from the emptiness check: a run that prints something plausible
# and still fails. Without it, removing the exit-code guard changes
# nothing, because the empty-value guard catches a silent failure anyway.
if [[ "${FAKE_ROTATE_RC:-0}" != "0" ]]; then
    [[ "${FAKE_ROTATE_NOISY:-false}" == "true" ]] && printf '%s' "${FAKE_SECRET_ID:-partial}"
    exit "${FAKE_ROTATE_RC}"
fi
if [[ "$*" == *"--wrap-ttl"* ]]; then
    printf '%s' "${FAKE_WRAP_TOKEN:-hvs.WRAPPEDTOKEN}"
else
    printf '%s' "${FAKE_SECRET_ID:-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
fi
exit 0
