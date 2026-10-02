#!/bin/bash
# Track progress through the store-setup checklist: which of the ~40 console
# steps that take a freshly generated app from unsigned builds to a
# submittable App Store Connect and Google Play listing are done, which mode
# the human picked, and the handful of account-identifying facts worth
# remembering (never credentials — see `note` below). The table also carries
# the steps of the optional extra stores, which hang off `toggle-uploads` and
# are reached only once the Apple and Google path works; a repository that
# does not ship on them settles those steps with
# `state.sh set <id> skipped`.
#
# Usage:
#   state.sh init [--force]
#   state.sh mode <guided|browser-pause|browser-full>
#   state.sh set <step> <todo|doing|done|skipped> [note]
#   state.sh get <step>
#   state.sh next [--all]
#   state.sh note <key> <value>
#   state.sh render [--markdown]
#   state.sh --list-steps
#
#   STORE_SETUP_DIR   defaults to <repo>/.store-setup
#   REPO_ROOT         defaults to `git rev-parse --show-toplevel`
#
# Exit codes: 0 ok, 1 validation failed (or a `note` refused as
# credential-shaped), 2 gated (no state.json yet, or the step is missing from
# an older one), 3 nothing to do (`next` found no eligible step), 64 usage.

set -uo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }
usage() { echo "FATAL: $*" >&2; exit 64; }
gated() { echo "FATAL: $*" >&2; exit 2; }

# The step vocabulary: id|owner|needs (needs is a comma-separated list of ids,
# empty for none). This exact table, in this exact order, is the interface
# other skills and their tests depend on — do not reorder or rename entries.
STEPS_TABLE="
preflight|setup|
identifiers|setup|preflight
apple-enrolment|consoles|identifiers
apple-agreements|consoles|apple-enrolment
apple-bundle-id|consoles|apple-agreements
apple-app-record|consoles|apple-bundle-id
apple-asc-key|consoles|apple-agreements
cred-asc-key|credentials|apple-asc-key
apple-match-repo|consoles|apple-agreements
cred-match|credentials|apple-match-repo
apple-testflight-groups|consoles|apple-app-record
apple-privacy-labels|consoles|apple-app-record
apple-pricing|consoles|apple-app-record
google-account|consoles|identifiers
google-app-record|consoles|google-account
cred-upload-keystore|credentials|identifiers
google-play-app-signing|consoles|google-app-record,cred-upload-keystore
google-service-account|consoles|google-account
google-play-grant|consoles|google-app-record,google-service-account
cred-play-json|credentials|google-play-grant
google-tracks|consoles|google-app-record
google-store-listing-fields|consoles|google-app-record
google-content-rating|consoles|google-app-record
google-data-safety|consoles|google-app-record
google-target-audience|consoles|google-app-record
google-app-access|consoles|google-app-record
google-pricing|consoles|google-app-record
meta-scaffold|metadata|identifiers
meta-ios-copy|metadata|meta-scaffold
meta-android-copy|metadata|meta-scaffold
meta-images|metadata|meta-scaffold
meta-age-rating|metadata|meta-scaffold
meta-review-info|metadata|meta-scaffold
cred-push|credentials|cred-asc-key,cred-match,cred-upload-keystore,cred-play-json
gh-environments|setup|cred-push
toggle-signing|setup|cred-push
rehearse-dry-run|setup|toggle-signing
meta-sync|metadata|meta-ios-copy,meta-android-copy,meta-images,meta-age-rating,meta-review-info,cred-push
first-play-upload|setup|google-play-app-signing,google-tracks,rehearse-dry-run
toggle-uploads|setup|rehearse-dry-run,first-play-upload
store-ready|setup|toggle-uploads,meta-sync,apple-testflight-groups,apple-privacy-labels,apple-pricing,google-content-rating,google-data-safety,google-target-audience,google-app-access,google-pricing,google-store-listing-fields,gh-environments
huawei-account|consoles|toggle-uploads
huawei-app-record|consoles|huawei-account
huawei-api-client|consoles|huawei-account
cred-huawei|credentials|huawei-api-client,huawei-app-record
huawei-app-signing|consoles|huawei-app-record
huawei-listing|consoles|huawei-app-record
toggle-huawei|setup|cred-huawei,huawei-listing,huawei-app-signing
huawei-testers|consoles|huawei-app-record
"

# Associative arrays need bash 4+, and macOS ships bash 3.2 as /bin/bash, so
# owner/needs lookups go through awk against STEPS_TABLE instead of a map.
STEP_IDS=()
while IFS='|' read -r id _owner _needs; do
  [ -n "$id" ] || continue
  STEP_IDS+=("$id")
done <<<"$STEPS_TABLE"

step_owner() {
  printf '%s\n' "$STEPS_TABLE" | awk -F'|' -v id="$1" '$1==id{print $2}'
}

step_needs() {
  printf '%s\n' "$STEPS_TABLE" | awk -F'|' -v id="$1" '$1==id{print $3}'
}

is_valid_step() {
  local want="$1" id
  for id in "${STEP_IDS[@]}"; do [ "$id" = "$want" ] && return 0; done
  return 1
}

is_valid_status() {
  case "$1" in
    todo | doing | done | skipped) return 0 ;;
    *) return 1 ;;
  esac
}

# A `note` key is refused when it looks like it holds a credential rather than
# a fact worth remembering (an account id, a team id, a bundle id). Matched
# case-insensitively without bash 4's ${var,,} (macOS's /bin/bash is 3.2).
is_credential_shaped_key() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" =~ (pass|secret|token|p8|private|_base64|json|auth) ]]
}

# --- STORE_SETUP_DIR / REPO_ROOT --------------------------------------------
if [ -z "${STORE_SETUP_DIR:-}" ]; then
  REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [ -n "$REPO_ROOT" ] || die "not inside a git repo; set REPO_ROOT or STORE_SETUP_DIR"
  STORE_SETUP_DIR="$REPO_ROOT/.store-setup"
fi
STATE_FILE="$STORE_SETUP_DIR/state.json"

# The steps table, as JSON, built once per invocation for the ops that need
# it inside node (next, render, list-steps).
steps_json() {
  local id first=1 owner needs needs_json
  printf '['
  for id in "${STEP_IDS[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    owner="$(step_owner "$id")"
    needs="$(step_needs "$id")"
    needs_json="[]"
    if [ -n "$needs" ]; then
      needs_json="[\"${needs//,/\",\"}\"]"
    fi
    printf '{"id":"%s","owner":"%s","needs":%s}' "$id" "$owner" "$needs_json"
  done
  printf ']'
}

# The single JSON reader/writer: every mutation of state.json goes through
# this one `node -e` call so the file stays pretty-printed with a trailing
# newline, and there is exactly one place that knows its shape.
node_json() {
  # shellcheck disable=SC2016 # single quotes are deliberate: this is JS, and must reach node unexpanded.
  STATE_FILE="$STATE_FILE" STEPS_JSON="$(steps_json)" node -e '
const fs = require("fs");
const path = require("path");

const file = process.env.STATE_FILE;
const steps = JSON.parse(process.env.STEPS_JSON);
const op = process.argv[1];
const args = process.argv.slice(2);

function load() { return JSON.parse(fs.readFileSync(file, "utf8")); }
function save(state) { fs.writeFileSync(file, JSON.stringify(state, null, 2) + "\n"); }
function settled(status) { return status === "done" || status === "skipped"; }

if (op === "init") {
  const force = args[0] === "1";
  if (fs.existsSync(file) && !force) {
    process.stdout.write(file + "\n");
    process.exit(0);
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const state = { schema: 1, mode: null, steps: {}, facts: {} };
  for (const s of steps) state.steps[s.id] = { status: "todo", note: null };
  save(state);
  process.stdout.write(file + "\n");
  process.exit(0);
}

const state = load();

if (op === "mode") {
  state.mode = args[0];
  save(state);
  process.exit(0);
}

if (op === "set") {
  const [step, status, note] = args;
  if (!state.steps[step]) {
    process.stderr.write(
      "FATAL: step \"" + step + "\" is not present in " + file + " - run state.sh init (or init --force) to add it\n"
    );
    process.exit(2);
  }
  state.steps[step].status = status;
  if (note !== undefined) state.steps[step].note = note;
  save(state);
  process.exit(0);
}

if (op === "get") {
  const st = state.steps[args[0]];
  if (!st) {
    process.stderr.write(
      "FATAL: step \"" + args[0] + "\" is not present in " + file + " - run state.sh init (or init --force) to add it\n"
    );
    process.exit(2);
  }
  process.stdout.write(st.status + "\n");
  process.exit(0);
}

if (op === "note") {
  const [key, value] = args;
  state.facts[key] = value;
  save(state);
  process.exit(0);
}

if (op === "next") {
  const all = args[0] === "1";
  const eligible = steps.filter((s) => {
    const st = state.steps[s.id];
    if (!st || settled(st.status)) return false;
    return s.needs.every((n) => state.steps[n] && settled(state.steps[n].status));
  });
  if (eligible.length === 0) process.exit(3);
  const ids = eligible.map((s) => s.id);
  process.stdout.write((all ? ids.join("\n") : ids[0]) + "\n");
  process.exit(0);
}

if (op === "render") {
  const markdown = args[0] === "1";
  for (const s of steps) {
    const st = state.steps[s.id];
    if (markdown) {
      const mark =
        st.status === "done" ? "x" : st.status === "doing" ? "~" : st.status === "skipped" ? "-" : " ";
      let line = `- [${mark}] ${s.id}`;
      if (st.note) line += ` - ${st.note}`;
      process.stdout.write(line + "\n");
    } else {
      process.stdout.write(`${s.id}: ${st.status}\n`);
    }
  }
  process.exit(0);
}

process.stderr.write("FATAL: unknown internal op " + op + "\n");
process.exit(70);
' -- "$@"
}

# --- CLI ---------------------------------------------------------------------

CMD="${1:-}"
[ $# -ge 1 ] && shift

# Every subcommand but `init` and `--list-steps` reads state.json; run
# straight into a node TypeError otherwise (and exit 1, which collides with
# the credential-refusal exit code) rather than a clear, gated failure.
case "$CMD" in
  init | --list-steps | '') : ;;
  *) [ -f "$STATE_FILE" ] || gated "no state.json at $STATE_FILE - run state.sh init first" ;;
esac

case "$CMD" in
  --list-steps)
    printf '%s\n' "${STEP_IDS[@]}"
    ;;

  init)
    FORCE=0
    for a in "$@"; do
      case "$a" in
        --force) FORCE=1 ;;
        *) usage "init: unknown option '$a'" ;;
      esac
    done
    node_json init "$FORCE"
    ;;

  mode)
    [ $# -eq 1 ] || usage "mode: usage: state.sh mode <guided|browser-pause|browser-full>"
    case "$1" in
      guided | browser-pause | browser-full) : ;;
      *) usage "mode: unknown mode '$1'" ;;
    esac
    node_json mode "$1"
    ;;

  set)
    [ $# -ge 2 ] || usage "set: usage: state.sh set <step> <todo|doing|done|skipped> [note]"
    STEP="$1"
    STATUS="$2"
    NOTE="${3-}"
    is_valid_step "$STEP" || usage "set: unknown step '$STEP'"
    is_valid_status "$STATUS" || usage "set: unknown status '$STATUS'"
    if [ $# -ge 3 ]; then
      node_json set "$STEP" "$STATUS" "$NOTE"
    else
      node_json set "$STEP" "$STATUS"
    fi
    ;;

  get)
    [ $# -eq 1 ] || usage "get: usage: state.sh get <step>"
    is_valid_step "$1" || usage "get: unknown step '$1'"
    node_json get "$1"
    ;;

  next)
    ALL=0
    for a in "$@"; do
      case "$a" in
        --all) ALL=1 ;;
        *) usage "next: unknown option '$a'" ;;
      esac
    done
    node_json next "$ALL"
    ;;

  note)
    [ $# -eq 2 ] || usage "note: usage: state.sh note <key> <value>"
    KEY="$1"
    VALUE="$2"
    if is_credential_shaped_key "$KEY"; then
      die "state.json is a progress file, not a secret store - that value belongs in gh secret set"
    fi
    node_json note "$KEY" "$VALUE"
    ;;

  render)
    MARKDOWN=0
    for a in "$@"; do
      case "$a" in
        --markdown) MARKDOWN=1 ;;
        *) usage "render: unknown option '$a'" ;;
      esac
    done
    node_json render "$MARKDOWN"
    ;;

  '')
    usage "no command given (init|mode|set|get|next|note|render|--list-steps)"
    ;;

  *)
    usage "unknown command '$CMD'"
    ;;
esac
