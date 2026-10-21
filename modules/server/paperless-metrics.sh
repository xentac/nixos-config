# Paperless health for alerting (paperless.nix): how stale the review
# inbox is, which documents are about to expire, and whether mail fetching
# keeps failing. Pushed straight into VictoriaMetrics; the alert rules read
# it through last_over_time(), so a run that stops pushing goes NoData.
#
# Env: PAPERLESS (base URL), VM (VictoriaMetrics), VL (VictoriaLogs),
# $CREDENTIALS_DIRECTORY/token (API token of the read-only `metrics` user).

token=$(<"$CREDENTIALS_DIRECTORY/token")
if [[ $token == unset ]]; then
  echo "paperless/metrics-token is still the placeholder; see docs/alba-nix.md" >&2
  exit 1
fi

# The token goes in through stdin (-H @-), never argv: journald records
# the command line (_CMDLINE) of every process that logs, so a curl error
# would ship it into VictoriaLogs. Retries ride out paperless restarting.
get() {
  curl -fsS --max-time 60 \
    --retry 6 --retry-delay 10 --retry-connrefused \
    -H @- <<<"Authorization: Token $token" \
    -H "Accept: application/json; version=9" \
    "$PAPERLESS/api/$1"
}

now=$(date +%s)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

# Review inbox: documents carrying any inbox tag, oldest first.
inbox=$(get 'documents/?is_in_inbox=true&ordering=added&page_size=1&fields=id,added')
oldest=$(jq -r '.results[0].added // empty' <<<"$inbox")
age=0
if [[ -n $oldest ]]; then
  age=$((now - $(date -d "$oldest" +%s)))
fi
{
  echo "paperless_inbox_documents $(jq .count <<<"$inbox")"
  echo "paperless_inbox_oldest_age_seconds $age"
} >>"$out"

# Expiry: one series per document whose `expires` date is today or later.
field=$(get 'custom_fields/?name__iexact=expires' | jq '.results[0].id // empty')
if [[ -n $field ]]; then
  query=$(jq -rn --arg d "$(date +%F)" '["expires", "gte", $d] | tojson | @uri')
  get "documents/?custom_field_query=$query&page_size=1000&fields=id,title,custom_fields" |
    jq -r --argjson f "$field" '
      .results[]
      | (.custom_fields[] | select(.field == $f) | .value) as $d
      | "paperless_document_expires_timestamp_seconds{id=\"\(.id)\",title=\"\(.title | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; " "))\"} \($d + "T00:00:00Z" | fromdateiso8601)"
    ' >>"$out"
fi

# Mail: ERROR lines from the paperless_mail / paperless.mail.* loggers,
# which run in the celery worker. A dead GMX login logs every check
# (PAPERLESS_EMAIL_TASK_CRON, default every 10 min).
# shellcheck disable=SC2016 # the backticks are LogsQL, not shell
errors=$(curl -fsS --max-time 60 "$VL/select/logsql/query" \
  --data-urlencode 'query=_time:6h _SYSTEMD_UNIT:paperless-task-queue.service ~`\[(ERROR|CRITICAL)\] \[paperless[._]mail` | stats count() as n' |
  jq -r '.n // 0')
echo "paperless_mail_errors_6h ${errors:-0}" >>"$out"

curl -fsS --max-time 60 --data-binary @"$out" \
  "$VM/api/v1/import/prometheus?extra_label=job=paperless"
