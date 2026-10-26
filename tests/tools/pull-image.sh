#!/bin/sh
# Retry registry failures, never the tests that use the image.
set -eu
image=${1:?usage: pull-image.sh IMAGE}
for attempt in 1 2 3; do
    if docker pull "$image"; then
        exit 0
    else
        status=$?
    fi
    if [ "$attempt" -eq 3 ]; then
        printf 'FAIL: could not pull %s after 3 attempts\n' "$image" >&2
        exit "$status"
    fi
    sleep 5
done
