#!/usr/bin/env bash
# Post-upgrade smoke test for openDemocracy's Coral Talk and the services that
# depend on it. Read-only: it only makes GET requests.
#
# Usage:
#   scripts/od-post-upgrade-check.sh                      # production
#   CORAL_URL=https://<staging-host> scripts/od-post-upgrade-check.sh
#   CORAL_URL=http://localhost:5055 CORAL_HOST=comment-talk.comment.opendemocracy.net \
#     scripts/od-post-upgrade-check.sh                   # local test instance
#
# See OD-UPGRADE-v9.11.md for the manual checks this can't automate.

set -u

CORAL_URL="${CORAL_URL:-https://comment-talk.comment.opendemocracy.net}"
# A live article whose comments should load. Override if it's ever unpublished.
STORY_URL="${STORY_URL:-https://www.opendemocracy.net/en/nhs-pulls-trans-conference-after-speakers-links-exposed/}"
# Coral picks the tenant by Host header; set this when CORAL_URL isn't the tenant domain.
CORAL_HOST="${CORAL_HOST:-}"
WIDGET_URL="${WIDGET_URL:-https://coral-comment-from-slack-widget.opendemocracy.workers.dev}"

fails=0

check() {
  local name="$1" url="$2" want="$3" match="${4:-}"
  local body code hdr=()
  [[ -n "$CORAL_HOST" && "$url" == "$CORAL_URL"* ]] && hdr=(-H "Host: $CORAL_HOST")
  body=$(curl -sS -m 20 ${hdr[@]+"${hdr[@]}"} -w '\n%{http_code}' "$url" 2>&1)
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "$code" != "$want" ]]; then
    echo "FAIL  $name: HTTP $code (want $want)  $url"
    fails=$((fails + 1))
  elif [[ -n "$match" ]] && ! grep -qE "$match" <<<"$body"; then
    echo "FAIL  $name: response missing /$match/  $url"
    fails=$((fails + 1))
  else
    echo "ok    $name"
  fi
}

enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

echo "Coral: $CORAL_URL"
check "health"            "$CORAL_URL/api/health"                                  200
check "embed script"      "$CORAL_URL/assets/js/embed.js"                          200 "createStreamEmbed"
check "embed bootstrap"   "$CORAL_URL/embed/bootstrap?storyURL=$(enc "$STORY_URL")" 200
check "AMP embed"         "$CORAL_URL/embed/stream/amp?storyURL=$(enc "$STORY_URL")" 200
check "admin page"        "$CORAL_URL/admin"                                       200
check "moderation page"   "$CORAL_URL/admin/moderate"                              200

echo
echo "Slack featured-comments widget: $WIDGET_URL"
check "featured (homepage)" "$WIDGET_URL/api/featured" 200 '"comments"'

echo
if (( fails )); then
  echo "$fails check(s) failed."
  exit 1
fi
echo "All automated checks passed. Now do the manual checks in OD-UPGRADE-v9.11.md."
