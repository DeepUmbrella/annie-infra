#!/bin/bash
# Install as /usr/local/sbin/annie-frontend-release, owned by root.
set -euo pipefail

if [[ $# != 1 ]]; then
    printf 'Expected one frontend image digest or rollback.\n' >&2
    exit 2
fi
case "$1" in
    rollback)
        release=--rollback
        ;;
    sha256:*)
        if [[ ! "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            printf 'Invalid frontend image digest.\n' >&2
            exit 2
        fi
        release="ghcr.io/deepumbrella/annie-frontend@$1"
        ;;
    *)
        printf 'Expected one frontend image digest or rollback.\n' >&2
        exit 2
        ;;
esac

exec /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root /root/annie-deploy/scripts/deploy-frontend-image.sh "$release"
