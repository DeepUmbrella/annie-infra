#!/bin/bash
# Run on the deployment host, alongside the existing Compose deployment.
set -euo pipefail
umask 077

readonly image_repo=ghcr.io/deepumbrella/annie-frontend
readonly rollback_repo=annie-frontend-rollback
readonly project=annie-website
readonly deploy_dir="${ANNIE_FRONTEND_DEPLOY_DIR:-/root/annie-deploy}"
readonly loopback_origin="${ANNIE_FRONTEND_LOOPBACK_ORIGIN:-http://127.0.0.1:3000}"
readonly public_origin="${ANNIE_FRONTEND_PUBLIC_ORIGIN:-https://www.linany.com}"
readonly state_dir="$deploy_dir/.frontend-deploy"
readonly state_file="$state_dir/state"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

is_rollback_image() {
    [[ "$1" == "$rollback_repo:"* && "${1#*:}" =~ ^[0-9a-f]{64}$ ]]
}

compose() {
    local image=$1
    shift
    FRONTEND_IMAGE="$image" docker compose --project-name "$project" \
        --project-directory "$deploy_dir" --env-file "$deploy_dir/.env" \
        -f "$deploy_dir/docker-compose.yml" \
        -f "$deploy_dir/docker-compose.frontend-image.yml" "$@"
}

curl_check() {
    local expected_type=$1 url=$2 destination=$3 response status mime
    response=$(curl --disable --fail --silent --show-error --max-time 15 \
        --header 'Cache-Control: no-cache' --output "$destination" \
        --write-out '%{http_code} %{content_type}' -- "$url") || return 1
    read -r status mime <<< "$response"
    [[ "$status" == 200 && "${mime%%;*}" =~ ^($expected_type)$ ]]
}

read_entry() {
    sed -n 's@.*src="\(/assets/[^" ]*\.js\)".*@\1@p' "$1"
}

verify_frontend() {
    local nonce="$$-$RANDOM-$RANDOM" local_entry external_entry
    curl_check text/plain "$loopback_origin/health?release=$nonce" "$scratch/health" &&
        [[ $(<"$scratch/health") == healthy ]] || return 1

    curl_check text/html "$loopback_origin/?release=$nonce" "$scratch/loopback.html" &&
        curl_check text/html "$public_origin/?release=$nonce" "$scratch/public.html" || return 1
    local_entry=$(read_entry "$scratch/loopback.html") || return 1
    external_entry=$(read_entry "$scratch/public.html") || return 1
    [[ "$local_entry" =~ ^/assets/[a-zA-Z0-9_.-]+\.js$ && "$local_entry" == "$external_entry" ]] ||
        return 1

    curl_check 'application/javascript|text/javascript' "$loopback_origin$local_entry?release=$nonce" "$scratch/loopback.js" &&
        curl_check 'application/javascript|text/javascript' "$public_origin$external_entry?release=$nonce" "$scratch/public.js" &&
        [[ -s "$scratch/loopback.js" ]] &&
        cmp -s "$scratch/loopback.js" "$scratch/public.js" || return 1
    printf 'Verified frontend asset %s over loopback and HTTPS.\n' "$local_entry"
}

frontend_image_id() {
    local allowed_state=${1:-true} info running owner service image extra
    info=$(docker container inspect --format \
        '{{.State.Running}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}} {{.Image}}' \
        annie-frontend) || return 1
    read -r running owner service image extra <<< "$info"
    [[ ( "$running" == true || ( "$running" == false && "$allowed_state" == any ) ) &&
        "$owner" == "$project" && "$service" == frontend &&
        "$image" =~ ^sha256:[0-9a-f]{64}$ && -z "$extra" ]] || return 1
    printf '%s\n' "$image"
}

local_image_id() {
    local image_id
    image_id=$(docker image inspect --format '{{.Id}}' "$1") || return 1
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$image_id"
}

write_state() {
    local state_tmp
    state_tmp=$(mktemp "$state_dir/state.XXXXXX") || return 1
    if ! printf '%s %s %s\n' "$1" "$2" "${3:-none}" > "$state_tmp" ||
       ! mv -f -- "$state_tmp" "$state_file"; then
        rm -f -- "$state_tmp"
        return 1
    fi
}

apply_image() {
    local image=$1 expected_id=$2 actual_id
    compose "$image" up -d --no-deps --no-build --pull never --wait --wait-timeout 120 frontend || return 1
    actual_id=$(frontend_image_id) || return 1
    [[ "$actual_id" == "$expected_id" ]] || return 1
    verify_frontend
}

restore_pending() {
    local image=$1 older=$2 expected_id actual_id
    expected_id="sha256:${image#*:}"
    actual_id=$(local_image_id "$image") || return 1
    [[ "$actual_id" == "$expected_id" ]] || return 1

    printf 'Restoring frontend image %s.\n' "$expected_id" >&2
    if [[ "$(frontend_image_id)" != "$expected_id" ]] || ! verify_frontend; then
        apply_image "$image" "$expected_id" || return 1
    fi
    write_state ready "$older"
}

on_exit() {
    local result=$? journal
    trap '' HUP INT TERM
    if [[ "$before" != none && -f "$state_file" ]] &&
        IFS= read -r journal < "$state_file" &&
        [[ "$journal" == "pending $before $previous" ]]; then
        if ! restore_pending "$before" "$previous"; then
            printf 'Frontend rollback did not pass verification. Re-run this script to retry recovery.\n' >&2
            result=1
        fi
    fi
    rm -rf -- "$scratch"
    exit "$result"
}

if [[ $# != 1 ]]; then
    die "Usage: $0 $image_repo@sha256:<digest> | --rollback"
fi
request=$1
if [[ "$request" != --rollback && ! "$request" =~ ^ghcr\.io/deepumbrella/annie-frontend@sha256:[0-9a-f]{64}$ ]]; then
    die 'Expected the frontend GHCR image by SHA-256 digest or --rollback.'
fi

[[ -r "$deploy_dir/.env" && -r "$deploy_dir/docker-compose.yml" &&
    -r "$deploy_dir/docker-compose.frontend-image.yml" ]] ||
    die "The existing Compose files and frontend image override are required in $deploy_dir."
command -v flock >/dev/null || die 'flock is required on the deployment host.'
docker compose version >/dev/null
mkdir -p -- "$state_dir"
exec 9>"$state_dir/lock"
flock -n 9 || die 'Another frontend deployment is running.'

scratch=$(mktemp -d "$state_dir/check.XXXXXX")
before=none
previous=none
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -f "$state_file" ]]; then
    read -r state saved older extra < "$state_file"
    [[ -z "$extra" ]] && { [[ "$older" == none ]] || is_rollback_image "$older"; } ||
        die 'Invalid frontend deployment state.'
    case "$state" in
        pending)
            is_rollback_image "$saved" || die 'Invalid pending frontend deployment state.'
            restore_pending "$saved" "$older" || die 'Could not recover the interrupted frontend deployment.'
            printf 'Recovered the interrupted deployment. Run the requested release again to continue.\n'
            exit 1
            ;;
        ready)
            [[ "$saved" == none ]] || is_rollback_image "$saved" || die 'Invalid rollback image.'
            previous=$saved
            ;;
        *)
            die 'Invalid frontend deployment state.'
            ;;
    esac
fi

target=$request
if [[ "$request" == --rollback ]]; then
    [[ "$previous" != none ]] || die 'There is no previous frontend release to restore.'
    target=$previous
    expected_id=$(local_image_id "$target") || die 'The previous frontend image is missing locally.'
    [[ "$expected_id" == "sha256:${target#*:}" ]] || die 'The previous frontend image tag has changed.'
else
    compose "$target" pull --policy always frontend || die 'The frontend image could not be pulled. The running container is unchanged.'
    expected_id=$(local_image_id "$target") || die 'The requested digest is missing locally after pull.'
fi

if [[ "$request" == --rollback ]]; then
    if ! current_id=$(frontend_image_id any); then
        existing=$(docker container ls --all --filter 'name=^/annie-frontend$' --format '{{.Names}}') ||
            die 'Could not determine whether a frontend container exists.'
        [[ -z "$existing" ]] || die "The existing frontend container is not managed by Compose project $project."
        apply_image "$target" "$expected_id" || die 'Could not restore the previous frontend image.'
        write_state ready none || die 'Could not record the restored frontend image.'
        printf 'Restored frontend image %s.\n' "$expected_id"
        exit 0
    fi
else
    current_id=$(frontend_image_id) || die "A running frontend in Compose project $project is required."
    verify_frontend || die 'The current frontend failed verification. Deployment was stopped before replacement.'
fi
if [[ "$expected_id" == "$current_id" ]]; then
    if [[ "$request" == --rollback ]]; then
        apply_image "$target" "$expected_id" || die 'The requested frontend failed verification.'
    fi
    printf 'Frontend image %s is running.\n' "$current_id"
    exit 0
fi

before="$rollback_repo:${current_id#sha256:}"
docker image tag "$current_id" "$before" || die 'Could not retain the currently running frontend image.'
write_state pending "$before" "$previous" || die 'Could not record the previous frontend image.'

printf 'Deploying frontend %s.\n' "$target"
apply_image "$target" "$expected_id" || die 'The replacement frontend failed verification.'
write_state ready "$before" || die 'Could not record a successful frontend deployment.'
printf 'Frontend deployment complete. Previous image %s is available for rollback.\n' "$current_id"
