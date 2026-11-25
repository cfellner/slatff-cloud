#!/usr/bin/env bash
# Creates a demo user in the slatff realm and adds them to a group.
# Usage: ./scripts/create-demo-user.sh <username> <email> <groups|none>
#   groups: one or more of ai-users, ai-admins, files-users, comma-separated
#   example: ./scripts/create-demo-user.sh alice alice@example.org ai-users,files-users
# Passwords never appear in a command line: the user's password is read from the
# terminal and sent on standard input, and the admin password is read from the
# Keycloak container's own environment.
set -euo pipefail
cd "$(dirname "$0")/.."
# Docker Desktop and Homebrew paths, in case the shell does not have them.
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"

user="${1:?username}"; email="${2:?email}"; groups="${3:?groups (ai-users, ai-admins, files-users, comma-separated) or none}"
IFS=',' read -r -a glist <<< "$groups"
for g in "${glist[@]}"; do
  case "$g" in
    ai-users|ai-admins|files-users) ;;
    none) [ "${#glist[@]}" -eq 1 ] || { echo "none cannot be combined with groups." >&2; exit 1; } ;;
    *) echo "Unknown group: $g (use ai-users, ai-admins, files-users or none)." >&2; exit 1 ;;
  esac
done
read -r -s -p "Password for $user: " pw; echo
[ -n "$pw" ] || { echo "Empty password." >&2; exit 1; }

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# Single quotes: the variables are expanded inside the container, not here.
docker compose exec -T keycloak bash -c \
  'KC_CLI_PASSWORD="$KC_BOOTSTRAP_ADMIN_PASSWORD" /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME"' >/dev/null

# -i prints the new user's id, so no search by name is needed.
uid=$(kc create users -r slatff -s "username=$user" -s "email=$email" -s emailVerified=true \
  -s enabled=true -s firstName="$user" -s lastName=Demo -i)

# Escape backslash and double quote for JSON, then send the body on standard input.
pw_json=$(printf '%s' "$pw" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
printf '{"type":"password","value":"%s","temporary":false}' "$pw_json" |
  kc update "users/$uid/reset-password" -r slatff -n -f -

if [ "$groups" != "none" ]; then
  for group in "${glist[@]}"; do
    gid=$(kc get groups -r slatff -q "search=$group" -q exact=true --fields id --format csv --noquotes | head -1)
    [ -n "$gid" ] || { echo "Group $group not found in realm slatff." >&2; exit 1; }
    kc update "users/$uid/groups/$gid" -r slatff -s realm=slatff -s userId="$uid" -s groupId="$gid" -n
    echo "Added $user to $group."
  done
else
  echo "Created $user with no group. Open WebUI and Files should refuse the sign-in."
fi
