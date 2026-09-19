#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
recipient="recipient@example.com"
sender_account_id="24C7BB8E-E734-4F02-AF7A-5E0420B38477"
port="${RELAY_TEST_PORT:-18080}"
base_url="http://127.0.0.1:${port}"
relay_token="${RELAY_TOKEN:-manual-relay-$(uuidgen)}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
message_text="Manual relay text test ${run_id}"
idempotency_key="lucas-text-${run_id}"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/imessage-relay-test.XXXXXX")"
server_log="${temporary_directory}/relay-server.log"
server_pid=""

cleanup() {
    if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$1" >&2
        exit 1
    fi
}

print_json_file() {
    if ! jq . "$1"; then
        printf 'Response was not valid JSON:\n' >&2
        sed -n '1,120p' "$1" >&2
        return 1
    fi
}

api_get() {
    curl -sS "$1" -H "Authorization: Bearer ${relay_token}"
}

require_command curl
require_command jq
require_command swift
require_command uuidgen

printf 'This script will send one real text message, then verify search and thread reads.\n'
printf 'Recipient: %s\n' "${recipient}"
printf 'Text: %s\n' "${message_text}"
printf 'Type SEND to continue: '
read -r confirmation
if [[ "${confirmation}" != "SEND" ]]; then
    printf 'Cancelled. Nothing was started or sent.\n'
    exit 0
fi
export RELAY_TOKEN="${relay_token}"
export RELAY_SENDER_ACCOUNT_ID="${sender_account_id}"
export RELAY_ALLOWED_RECIPIENTS="${recipient}"

printf '\nStarting relay-server on %s...\n' "${base_url}"
cd "${repo_root}"
swift run relay-server --hostname 127.0.0.1 --port "${port}" >"${server_log}" 2>&1 &
server_pid="$!"

server_ready=false
attempt=0
while [[ "${attempt}" -lt 120 ]]; do
    if ! kill -0 "${server_pid}" 2>/dev/null; then
        printf 'relay-server exited before it became ready. Log output:\n' >&2
        sed -n '1,240p' "${server_log}" >&2
        exit 1
    fi
    if api_get "${base_url}/v1/status" >"${temporary_directory}/status.json" 2>/dev/null; then
        if jq -e '.database.ready == true' "${temporary_directory}/status.json" >/dev/null 2>&1; then
            server_ready=true
            break
        fi
    fi
    attempt=$((attempt + 1))
    sleep 1
done

if [[ "${server_ready}" != "true" ]]; then
    printf 'relay-server did not report a ready database within 120 seconds.\n' >&2
    print_json_file "${temporary_directory}/status.json" >&2 || true
    printf 'Server log:\n' >&2
    sed -n '1,240p' "${server_log}" >&2
    exit 1
fi

printf '\nService status:\n'
print_json_file "${temporary_directory}/status.json"

printf '\nSender status:\n'
api_get "${base_url}/v1/sender" >"${temporary_directory}/sender.json"
print_json_file "${temporary_directory}/sender.json"
native_reply_capability="$(jq -r '.capabilities.native_reply // "unknown"' "${temporary_directory}/sender.json")"

jq -n --arg recipient "${recipient}" --arg text "${message_text}" \
    '{to: $recipient, text: $text}' \
    >"${temporary_directory}/send-request.json"

printf '\nSending the text request...\n'
send_status="$({
    curl -sS -o "${temporary_directory}/send.json" -w '%{http_code}' \
        -X POST "${base_url}/v1/messages" \
        -H "Authorization: Bearer ${relay_token}" \
        -H 'Content-Type: application/json' \
        -H "Idempotency-Key: ${idempotency_key}" \
        --data-binary "@${temporary_directory}/send-request.json"
})"
print_json_file "${temporary_directory}/send.json"

request_id="$(jq -er '.request_id' "${temporary_directory}/send.json")"
if [[ "${send_status}" == "202" ]]; then
    printf '\nReplaying the identical idempotent request. This must not send again...\n'
    replay_status="$({
        curl -sS -o "${temporary_directory}/replay.json" -w '%{http_code}' \
            -X POST "${base_url}/v1/messages" \
            -H "Authorization: Bearer ${relay_token}" \
            -H 'Content-Type: application/json' \
            -H "Idempotency-Key: ${idempotency_key}" \
            --data-binary "@${temporary_directory}/send-request.json"
    })"
    print_json_file "${temporary_directory}/replay.json"
    if [[ "${replay_status}" != "202" ]] || ! cmp -s \
        "${temporary_directory}/send.json" "${temporary_directory}/replay.json"; then
        printf 'The idempotent replay did not return the original response.\n' >&2
        exit 1
    fi
elif [[ "${send_status}" == "502" ]]; then
    printf '\nThe send result is uncertain. The script will poll it but will not retry.\n' >&2
else
    printf 'Send request failed with HTTP %s.\n' "${send_status}" >&2
    exit 1
fi

printf '\nDurable request status:\n'
api_get "${base_url}/v1/requests/${request_id}" >"${temporary_directory}/request-status.json"
print_json_file "${temporary_directory}/request-status.json"

printf '\nWaiting for the conversation to appear in chat.db...\n'
conversation_id=""
attempt=0
while [[ "${attempt}" -lt 20 ]]; do
    api_get "${base_url}/v1/conversations?limit=200" >"${temporary_directory}/conversations.json"
    conversation_id="$(
        jq -r --arg recipient "${recipient}" '
            .items[]?
            | select(any(.participants[]?; (.value | ascii_downcase) == ($recipient | ascii_downcase)))
            | .id
        ' "${temporary_directory}/conversations.json" | head -n 1
    )"
    if [[ -n "${conversation_id}" ]]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done

if [[ -z "${conversation_id}" ]]; then
    printf 'No conversation for %s was found. Raw conversation response:\n' "${recipient}" >&2
    print_json_file "${temporary_directory}/conversations.json" >&2 || true
    exit 1
fi

conversation_path="$(jq -rn --arg value "${conversation_id}" '$value | @uri')"
printf 'Conversation ID: %s\n' "${conversation_id}"

printf '\nWaiting for the unique text in chat.db...\n'
encoded_text="$(jq -rn --arg value "${message_text}" '$value | @uri')"
text_delivered=false
attempt=0
while [[ "${attempt}" -lt 60 ]]; do
    api_get \
        "${base_url}/v1/conversations/${conversation_path}/messages?limit=50&q=${encoded_text}&search_mode=exact" \
        >"${temporary_directory}/search.json"
    if jq -e '(.items | type) == "array" and (.items | length) == 1' \
        "${temporary_directory}/search.json" >/dev/null 2>&1; then
        text_state="$(jq -r '.items[0].delivery_state' "${temporary_directory}/search.json")"
        if [[ "${text_state}" == "delivered" ]]; then
            text_delivered=true
            break
        fi
        if [[ "${text_state}" == "failed" ]]; then
            printf 'The text message failed:\n' >&2
            print_json_file "${temporary_directory}/search.json" >&2
            exit 1
        fi
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [[ "${text_delivered}" != "true" ]]; then
    printf 'The unique text did not become delivered within 60 seconds. Last response:\n' >&2
    print_json_file "${temporary_directory}/search.json" >&2 || true
    exit 1
fi
if ! jq -e '.items[0].thread == null' "${temporary_directory}/search.json" >/dev/null; then
    printf 'The top-level text was incorrectly mapped as a thread reply:\n' >&2
    print_json_file "${temporary_directory}/search.json" >&2
    exit 1
fi
print_json_file "${temporary_directory}/search.json"

printf '\nFetching the most recent message in the conversation...\n'
api_get \
    "${base_url}/v1/conversations/${conversation_path}/messages?limit=1&include_attachments=true" \
    >"${temporary_directory}/latest-message.json"
if ! jq -e '.items | length == 1' "${temporary_directory}/latest-message.json" >/dev/null; then
    printf 'The conversation did not return its most recent message:\n' >&2
    print_json_file "${temporary_directory}/latest-message.json" >&2 || true
    exit 1
fi
print_json_file "${temporary_directory}/latest-message.json"

printf '\nChecking native thread creation capability...\n'
if [[ "${native_reply_capability}" == "available" ]]; then
    printf 'The sender advertises native replies. This script currently requires a provider-specific thread-send implementation before attempting one.\n' >&2
    exit 1
fi

thread_probe_text="Thread capability probe ${run_id}"
jq -n \
    --arg conversation_id "${conversation_id}" \
    --arg text "${thread_probe_text}" \
    --arg message_id "$(jq -er '.items[0].id' "${temporary_directory}/search.json")" \
    '{conversation_id: $conversation_id, text: $text, reply_to: {message_id: $message_id}}' \
    >"${temporary_directory}/thread-probe-request.json"
thread_probe_status="$({
    curl -sS -o "${temporary_directory}/thread-probe.json" -w '%{http_code}' \
        -X POST "${base_url}/v1/messages" \
        -H "Authorization: Bearer ${relay_token}" \
        -H 'Content-Type: application/json' \
        -H "Idempotency-Key: lucas-thread-probe-${run_id}" \
        --data-binary "@${temporary_directory}/thread-probe-request.json"
})"
print_json_file "${temporary_directory}/thread-probe.json"
if [[ "${thread_probe_status}" != "501" ]] || \
    ! jq -e '.code == "unsupported_capability"' "${temporary_directory}/thread-probe.json" >/dev/null; then
    printf 'The sender did not fail closed for an unsupported native thread reply (HTTP %s).\n' "${thread_probe_status}" >&2
    exit 1
fi
printf 'Native thread creation is unavailable on this Mac; no probe message was sent.\n'

printf '\nChecking an existing root, reply, and nested reply in this conversation...\n'
api_get \
    "${base_url}/v1/conversations/${conversation_path}/messages?limit=200" \
    >"${temporary_directory}/thread-page.json"
if ! jq -e '(.items | type) == "array"' \
    "${temporary_directory}/thread-page.json" >/dev/null 2>&1; then
    printf 'The thread lookup did not return a message page:\n' >&2
    print_json_file "${temporary_directory}/thread-page.json" >&2 || true
    exit 1
fi

if ! jq -e '
    [
        .items[]?
        | select(
            .thread.reply_to_message_id != null
            and .thread.thread_originator_message_id != null
            and .thread.reply_to_message_id != .thread.thread_originator_message_id
        )
    ]
    | first
' "${temporary_directory}/thread-page.json" >"${temporary_directory}/nested-thread.json"; then
    printf 'No nested reply was found among the latest 200 messages.\n' >&2
    printf 'Create a root, a reply to it, and a reply to that reply in Messages, then rerun this script.\n' >&2
    exit 1
fi

nested_message_id="$(jq -er '.id' "${temporary_directory}/nested-thread.json")"
parent_message_id="$(jq -er '.thread.reply_to_message_id' "${temporary_directory}/nested-thread.json")"
root_message_id="$(jq -er '.thread.thread_originator_message_id' "${temporary_directory}/nested-thread.json")"
nested_message_path="$(jq -rn --arg value "${nested_message_id}" '$value | @uri')"
parent_message_path="$(jq -rn --arg value "${parent_message_id}" '$value | @uri')"
root_message_path="$(jq -rn --arg value "${root_message_id}" '$value | @uri')"

api_get "${base_url}/v1/messages/${nested_message_path}" \
    >"${temporary_directory}/nested-message.json"
api_get "${base_url}/v1/messages/${parent_message_path}" \
    >"${temporary_directory}/parent-message.json"
api_get "${base_url}/v1/messages/${root_message_path}" \
    >"${temporary_directory}/root-message.json"

if ! jq -e \
    --arg id "${nested_message_id}" \
    --arg parent "${parent_message_id}" \
    --arg root "${root_message_id}" '
        .id == $id
        and .thread.reply_to_message_id == $parent
        and .thread.thread_originator_message_id == $root
    ' "${temporary_directory}/nested-message.json" >/dev/null; then
    printf 'The nested reply did not preserve its immediate parent and thread root:\n' >&2
    print_json_file "${temporary_directory}/nested-message.json" >&2 || true
    exit 1
fi
if ! jq -e \
    --arg id "${parent_message_id}" \
    --arg root "${root_message_id}" '
        .id == $id
        and .thread.thread_originator_message_id == $root
    ' "${temporary_directory}/parent-message.json" >/dev/null; then
    printf 'The immediate reply did not preserve the same thread root:\n' >&2
    print_json_file "${temporary_directory}/parent-message.json" >&2 || true
    exit 1
fi
if ! jq -e \
    --arg id "${root_message_id}" '
        .id == $id and .thread == null
    ' "${temporary_directory}/root-message.json" >/dev/null; then
    printf 'The thread root was incorrectly mapped as a reply:\n' >&2
    print_json_file "${temporary_directory}/root-message.json" >&2 || true
    exit 1
fi

jq -s '
    {
        root: (.[0] | {id, text, thread}),
        reply: (.[1] | {id, text, thread}),
        nested_reply: (.[2] | {id, text, thread})
    }
' \
    "${temporary_directory}/root-message.json" \
    "${temporary_directory}/parent-message.json" \
    "${temporary_directory}/nested-message.json"

printf '\nManual test complete. The server will now stop.\n'
printf 'Request ID: %s\n' "${request_id}"
printf 'Idempotency key: %s\n' "${idempotency_key}"
printf 'Verified one existing thread and the unsupported native-reply contract.\n'
