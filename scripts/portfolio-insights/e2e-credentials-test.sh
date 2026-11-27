#!/usr/bin/env bash
# Tests how scripts/portfolio-insights/e2e.sh handles the fixture passwords, the raw HTTP
# responses and its failure reasons, without a running stack:
#   - random_secret takes 16 bytes of /dev/urandom, fails closed without them, and step 3 then
#     stops at its first check before any request;
#   - step 3 takes each of the holder's instrument listings only as a 200 with a results array,
#     and certifies the holdings, writes the fixture and starts the browser check only when both
#     bought instruments are listed once each with a JSON-number amount of at least 1;
#   - write_fixture and signup keep the passwords out of every jq command line and still write
#     the exact fixture file and signup body;
#   - http keeps the raw responses in the private directory, where expect_forbidden compares
#     every byte, those after a NUL included;
#   - body_snippet and jcheck describe a body without any byte of it, and fail redacts both
#     passwords and keeps each FAIL line to one line of printable ASCII;
#   - step 4 writes no copy of the insights response to the run directory, and stops before it
#     when the flag's PUT answer is not this flag with the JSON boolean true;
#   - cleanup removes the fixture and the private directory after a pass, a failure and an
#     interrupt, and fails the run when it cannot; a second interrupt, during cleanup, still
#     removes them and ends the run with FAIL cleanup, the SUMMARY line and exit status 130;
#   - remove_private reports a path as not removed when rm fails, even with nothing left;
#   - restrict_private_dir leaves the current user the only one with access to the private
#     directory (one icacls entry on Windows, mode 700 elsewhere) and fails with its reason when
#     its tool fails or changes nothing, or, on Windows, when the user, the Windows path or the
#     listing cannot be read;
#   - the script's own setup puts the private directory, so restricted, beside the run
#     directory, exits 2 and removes both when setup or the restriction fails, and removes the
#     private one when the first step aborts.
# Each function is read by name from the e2e.sh beside this file and defined exactly as it is
# written there; only the network, the random source, file removal, the permission tools and
# cygpath, Docker and Node are stubbed.
#
# Usage: scripts/portfolio-insights/e2e-credentials-test.sh
#   --help  Show this help and exit
#
# Needs bash, jq, od and sed, and icacls on Windows; no stack, Docker or Node.
# Prints one PASS or FAIL line per check, an INFO line for a check this platform cannot make, and
# a final SUMMARY line. Exits 0 when every check passes, 1 when any check fails, and 2 on a usage
# error or a missing tool. The run's temporary files are removed on exit.

# shellcheck disable=SC2016,SC2034 # Stub lines and jq filters are single-quoted on purpose, and
# the e2e.sh functions this file loads with eval read the globals it sets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="$SCRIPT_DIR/e2e.sh"

usage() {
    cat <<'EOF'
Usage: scripts/portfolio-insights/e2e-credentials-test.sh
  --help  Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for tool in jq od sed; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required on PATH." >&2
        exit 2
    fi
done
if [[ ! -f "$E2E" ]]; then
    echo "e2e.sh not found beside this script: $E2E" >&2
    exit 2
fi
REAL_MKTEMP="$(command -v mktemp)"

# Git Bash and Cygwin emulate file modes rather than enforce them.
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) MODES_ENFORCED=0 ;;
    *) MODES_ENFORCED=1 ;;
esac

tests_passed=0
tests_failed=0
reasons=()
T=""
RC=0

check_pass() {
    tests_passed=$((tests_passed + 1))
    echo "PASS $1"
}

check_fail() {
    tests_failed=$((tests_failed + 1))
    echo "FAIL $1: $2"
}

summarize() {
    echo "SUMMARY ${tests_passed} passed, ${tests_failed} failed"
}

# Reports one PASS or FAIL line for CHECK from the reasons collected since the last call.
conclude() {
    local joined
    if [[ ${#reasons[@]} -eq 0 ]]; then
        check_pass "$1"
    else
        joined="$(printf '%s; ' "${reasons[@]}")"
        check_fail "$1" "${joined%; }"
    fi
    reasons=()
}

cleanup_test() {
    local status=$?
    trap - EXIT
    if [[ -n "$T" ]]; then
        command rm -rf -- "$T"
    fi
    exit "$status"
}
trap cleanup_test EXIT
trap 'exit 130' INT TERM

if ! T="$(mktemp -d "${TMPDIR:-/tmp}/e2e-credentials-test.XXXXXX")"; then
    echo "Could not create a temporary directory under ${TMPDIR:-/tmp}." >&2
    exit 2
fi

# load_functions NAME...: defines each function as e2e.sh defines it, from its "NAME() {" line
# to the next line that is a lone "}".
load_functions() {
    local name text
    for name in "$@"; do
        text="$(sed -n "/^$name() {\$/,/^}\$/p" "$E2E")"
        if [[ -z "$text" ]]; then
            echo "Function $name not found in $E2E" >&2
            exit 2
        fi
        eval "$text"
    done
}

# load_values NAME...: sets each NAME as the one-line top-level assignment in e2e.sh sets it.
load_values() {
    local name text
    for name in "$@"; do
        text="$(sed -n "/^$name=/{p;q;}" "$E2E")"
        if [[ -z "$text" ]]; then
            echo "Assignment $name not found in $E2E" >&2
            exit 2
        fi
        eval "$text"
    done
}

load_functions pass fail info abort http jget jitem jcount lower status_text describe_file \
    body_snippet jcheck expect_forbidden own_alert own_if_created random_secret now_rfc3339 \
    epoch_to_rfc3339 log_since_now remaining_owned delete_alert write_fixture signup \
    step3_fixture step4_enable delete_remaining remove_private on_cleanup_signal cleanup \
    on_signal restrict_private_dir flag_enabled media_type
load_values FLAG_ID HTTP_TIMEOUT_SECONDS LOG_SKEW_MARGIN_SECONDS \
    MAX_CONSECUTIVE_TRANSPORT_ERRORS PACKAGE_ID FORBIDDEN_BODY UUID_RE DEPOSIT_AMOUNT

# Two passwords in random_secret's format, assembled here so no literal resembles a credential.
SECRET_A="Pi-$(printf 'a1%.0s' {1..16})"
SECRET_B="Pi-$(printf 'b2%.0s' {1..16})"
HOLDER_UUID="0f8e6a52-3b1d-4c7e-9a2f-5d6c7b8a9e01"
EMPTY_UUID="1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
ALERT_UUID="2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
INSTRUMENT_A_UUID="3c4d5e6f-7a8b-4c9d-8e0f-2a3b4c5d6e7f"
INSTRUMENT_B_UUID="4d5e6f7a-8b9c-4dae-9f10-3b4c5d6e7f80"

# shellcheck disable=SC2329 # Invoked by the loaded e2e.sh functions.
# jq: records each command line the loaded functions give jq, then runs the real jq. This file
# calls the real one as "command jq".
jq() {
    printf '%s\n' "$*" >>"$T/jq-argv"
    command jq "$@"
}

# fresh_state: a new run directory and private directory, as e2e.sh's setup leaves them, and
# the globals the loaded functions read.
fresh_state() {
    RUN_DIR="$(mktemp -d "$T/run.XXXXXX")"
    PRIVATE_DIR="$(mktemp -d "$T/private.XXXXXX")"
    EVIDENCE_DIR="$RUN_DIR"
    FIXTURE="$PRIVATE_DIR/fixture.json"
    PRIVATE_LEFT=""
    : >"$RUN_DIR/owned"
    : >"$RUN_DIR/deleted"
    passed=0
    failed=0
    IN_CREATE=0
    PENDING_EXIT=""
    FLAG_INITIAL="false"
    FLAG_TOUCHED=0
    INTERVAL=60
    HOLDER_USER="pi-e2e-1-holder"
    EMPTY_USER="pi-e2e-1-empty"
    HOLDER_PASSWORD="$SECRET_A"
    EMPTY_PASSWORD="$SECRET_B"
    HOLDER_ID="$HOLDER_UUID"
    EMPTY_ID="$EMPTY_UUID"
    BASE_URL="http://127.0.0.1:9"
    B="$BASE_URL/broker-service"
    F="$BASE_URL/feature-flag-service/v1/flags/$FLAG_ID"
    U="$BASE_URL/user-service"
    ALERTS_URL="$B/v1/alerts"
    INSIGHTS_URL="$B/v1/portfolio/insights"
    HTTP_STATUS=""
    HTTP_CTYPE=""
    HTTP_BODY=""
    HTTP_ERROR=""
    : >"$T/jq-argv"
    : >"$T/requests"
}

# run_isolated OUT FUNCTION [ARGS...]: runs FUNCTION in a subshell under set -euo pipefail, as
# e2e.sh runs, with stdout in OUT and stderr in OUT.err; sets RC to the subshell's exit status.
run_isolated() {
    local out="$1"
    shift
    set +e
    (
        set -euo pipefail
        "$@"
    ) >"$out" 2>"$out.err"
    RC=$?
    set -e
}

# shellcheck disable=SC2329 # Invoked by the http stand-ins of the scenarios below.
# respond STATUS CONTENT_TYPE BODY: leaves the HTTP_* globals and the private body file as
# e2e.sh's http leaves them after a response.
respond() {
    printf '%s' "$3" >"$PRIVATE_DIR/body"
    : >"$PRIVATE_DIR/headers"
    HTTP_STATUS="$1"
    HTTP_CTYPE="$2"
    HTTP_ERROR=""
    HTTP_BODY="$(cat "$PRIVATE_DIR/body")"
}

file_size() {
    wc -c <"$1" | tr -d ' \r'
}

# has_unprintable FILE: whether FILE holds a byte outside printable ASCII other than a newline.
# Counted with tr, because grep on Git Bash drops the carriage return of a CRLF line.
has_unprintable() {
    [[ "$(LC_ALL=C tr -d '\n\040-\176' <"$1" | wc -c | tr -d ' ')" -ne 0 ]]
}

# expect_secrets_absent FILE WHAT: neither password occurs in FILE.
expect_secrets_absent() {
    if grep -aqF -e "$SECRET_A" -e "$SECRET_B" "$1"; then
        reasons+=("$2 holds a password")
    fi
}

expect_rc() {
    if [[ "$RC" -ne "$1" ]]; then
        reasons+=("exit status $RC, expected $1")
    fi
}

expect_line() {
    if ! grep -qxF -- "$2" "$1"; then
        reasons+=("no line [$2] in the output")
    fi
}

expect_no_line() {
    if grep -qxF -- "$2" "$1"; then
        reasons+=("the output has the line [$2]")
    fi
}

expect_absent() {
    if [[ -e "$1" ]]; then
        reasons+=("$2 still exists")
    fi
}

# entries DIR PATTERN: the names in DIR that match the glob PATTERN, sorted, space separated.
entries() {
    local entry list=""
    for entry in "$1"/$2; do
        if [[ -e "$entry" ]]; then
            list="$list ${entry##*/}"
        fi
    done
    echo "${list# }"
}

# mode_of PATH: the permission bits in octal, by GNU stat or BSD stat.
mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# expect_user_only_acl LISTING WHAT RIGHTS: the icacls LISTING holds exactly one entry, the
# Windows logon user's RIGHTS, such as (OI)(CI)(F).
expect_user_only_acl() {
    local user="${USERDOMAIN:-}\\${USERNAME:-}"
    if [[ "$(grep -c ':(' "$1" || true)" -ne 1 ]] || ! grep -qiF -- "$user:$3" "$1"; then
        reasons+=("$2 lists [$(grep -F ':(' "$1" | sed 's/^ *//' | tr -d '\r' | tr '\n' ' ')], expected only $user:$3")
    fi
}

# list_acl PATH: what icacls lists for PATH, its arguments passed unchanged.
list_acl() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$1")" | tr -d '\r'
}

# ---------------------------------------------------------------------------------------------
# random_secret and step 3

check="randomSecret_osRandomSource_printsPiAnd32LowercaseHexDigits"
fresh_state
: >"$T/secrets"
for _ in {1..20}; do
    random_secret >>"$T/secrets" || reasons+=("a draw failed")
done
if [[ "$(grep -cE '^Pi-[0-9a-f]{32}$' "$T/secrets" || true)" -ne 20 ]]; then
    reasons+=("$(grep -cvE '^Pi-[0-9a-f]{32}$' "$T/secrets" || true) of $(wc -l <"$T/secrets" | tr -d ' ') lines do not match Pi-<32 hex digits>")
fi
conclude "$check"

check="randomSecret_repeatedDraws_neverRepeat"
if [[ "$(sort -u "$T/secrets" | wc -l | tr -d ' ')" -ne 20 ]]; then
    reasons+=("20 draws gave $(sort -u "$T/secrets" | wc -l | tr -d ' ') distinct values")
fi
conclude "$check"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_random_source() {
    od() {
        case "$OD_CASE" in
            sourceUnavailable)
                echo "od: /dev/urandom: No such file or directory" >&2
                return 1
                ;;
            shortRead) echo " 0a 1b 2c 3d" ;;
            notHex) echo " zz zz zz zz zz zz zz zz zz zz zz zz zz zz zz zz" ;;
        esac
    }
    random_secret
}

for OD_CASE in sourceUnavailable shortRead notHex; do
    check="randomSecret_${OD_CASE}_failsWithoutOutput"
    fresh_state
    run_isolated "$T/random.out" scenario_random_source
    if [[ "$RC" -eq 0 ]]; then
        reasons+=("exit status 0, expected a failure")
    fi
    if [[ -s "$T/random.out" ]]; then
        reasons+=("printed [$(tr -d '\n' <"$T/random.out")]")
    fi
    conclude "$check"
done

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_step3_no_random() {
    random_secret() {
        return 1
    }
    http() {
        echo "$1 $2" >>"$T/requests"
        respond 201 application/json "{\"id\":\"$HOLDER_UUID\"}"
    }
    step3_fixture
}

check="step3Fixture_randomSourceUnavailable_abortsAtSignupHolderBeforeAnyRequest"
fresh_state
run_isolated "$T/step3.out" scenario_step3_no_random
expect_rc 1
expect_line "$T/step3.out" "FAIL step 3 signup holder: no password generated: /dev/urandom did not supply 16 random bytes"
if [[ -s "$T/requests" ]]; then
    reasons+=("requests were sent: $(tr '\n' ' ' <"$T/requests")")
fi
conclude "$check"

# shellcheck disable=SC2329 # Invoked through run_isolated.
# scenario_step3_listings: step 3 with every request answered: the holder's instrument listing
# by STEP3_BEFORE before the buys and by STEP3_AFTER after them, each "STATUS BODY", and the
# browser check recorded in place of being run.
scenario_step3_listings() {
    local listings=0
    http() {
        echo "$1 $2" >>"$T/requests"
        case "$1 $2" in
            "POST $U/api/auth/signup")
                if [[ "$3" == *'"lastName":"Holder"'* ]]; then
                    respond 201 application/json "{\"id\":\"$HOLDER_UUID\"}"
                else
                    respond 201 application/json "{\"id\":\"$EMPTY_UUID\"}"
                fi
                ;;
            "GET $B/v1/instrument?accountId=$HOLDER_UUID")
                listings=$((listings + 1))
                if [[ $listings -eq 1 ]]; then
                    respond "${STEP3_BEFORE%% *}" application/json "${STEP3_BEFORE#* }"
                else
                    respond "${STEP3_AFTER%% *}" application/json "${STEP3_AFTER#* }"
                fi
                ;;
            *) respond 200 application/json '{}' ;;
        esac
    }
    run_browser_check() {
        echo "BROWSER $1 $2" >>"$T/requests"
    }
    step3_fixture
}

# with_instrument_ids TEXT: TEXT with every @A and @B replaced by the two instrument ids.
with_instrument_ids() {
    local text="${1//@A/$INSTRUMENT_A_UUID}"
    printf '%s' "${text//@B/$INSTRUMENT_B_UUID}"
}

STEP3_DEFAULT_BEFORE='200 {"results":[{"id":"@A","amount":0},{"id":"@B","amount":0}]}'
STEP3_DEFAULT_AFTER='200 {"results":[{"id":"@A","amount":1},{"id":"@B","amount":1}]}'
# name|buys sent|listing before the buys|listing after them|expected line. A listing is
# "STATUS BODY", and an empty one is the default above. @A and @B stand for the two instrument
# ids, and @SIZE for the size of the last response body.
step3_listing_cases="$(
    cat <<'EOF'
numericAmounts_certifiesHoldingsAndStartsBrowserCheck|2||200 {"results":[{"id":"@A","amount":1},{"id":"@B","amount":2.5}]}|PASS step 3 holdings
amountString_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":"1"},{"id":"@B","amount":1}]}|FAIL step 3 holdings: instrument [@A] shows an amount of JSON type [string], expected a number
amountObject_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":{}},{"id":"@B","amount":1}]}|FAIL step 3 holdings: instrument [@A] shows an amount of JSON type [object], expected a number
amountArray_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":[2]},{"id":"@B","amount":1}]}|FAIL step 3 holdings: instrument [@A] shows an amount of JSON type [array], expected a number
amountZero_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":0},{"id":"@B","amount":1}]}|FAIL step 3 holdings: instrument [@A] shows amount [0], expected at least 1
secondAmountMissing_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":1},{"id":"@B"}]}|FAIL step 3 holdings: instrument [@B] shows an amount of JSON type [null], expected a number
listedTwice_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":1},{"id":"@B","amount":1},{"id":"@A","amount":1}]}|FAIL step 3 holdings: instrument [@A] is listed 2 times, expected once
secondNotListed_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":1}]}|FAIL step 3 holdings: instrument [@B] is listed 0 times, expected once
afterWithoutResults_abortsAtHoldingsBeforeFixture|2||200 {"items":[]}|FAIL step 3 holdings: the holder's instrument listing has results of JSON type [null], expected an array; body [@SIZE bytes, JSON object with 1 key [items]]
afterResultsObject_abortsAtHoldingsBeforeFixture|2||200 {"results":{"a":{"id":"@A","amount":1},"b":{"id":"@B","amount":1}}}|FAIL step 3 holdings: the holder's instrument listing has results of JSON type [object], expected an array; body [@SIZE bytes, JSON object with 1 key [results]]
afterNotJson_abortsAtHoldingsBeforeFixture|2||200 <html></html>|FAIL step 3 holdings: the holder's instrument listing has results of JSON type [unreadable], expected an array; body [@SIZE bytes, not JSON]
afterListingThenGarbage_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":1},{"id":"@B","amount":1}]}garbage|FAIL step 3 holdings: the holder's instrument listing has results of JSON type [unreadable], expected an array; body [@SIZE bytes, not JSON]
afterListingTwice_abortsAtHoldingsBeforeFixture|2||200 {"results":[{"id":"@A","amount":1},{"id":"@B","amount":1}]}{"results":[{"id":"@A","amount":1},{"id":"@B","amount":1}]}|FAIL step 3 holdings: the holder's instrument listing has results of JSON type [unreadable], expected an array; body [@SIZE bytes, not JSON]
afterStatus500_abortsAtHoldingsBeforeFixture|2||500 {}|FAIL step 3 holdings: the holder's instrument listing gave status 500, expected 200
beforeWithoutResults_abortsBeforeAnyBuy|0|200 {}||FAIL step 3 buy instrument 1: the holder's instrument listing has results of JSON type [null], expected an array; body [@SIZE bytes, JSON object with 0 keys]
beforeResultsObject_abortsBeforeAnyBuy|0|200 {"results":{"a":{"id":"@A","amount":0},"b":{"id":"@B","amount":0}}}||FAIL step 3 buy instrument 1: the holder's instrument listing has results of JSON type [object], expected an array; body [@SIZE bytes, JSON object with 1 key [results]]
beforeStatus500_abortsBeforeAnyBuy|0|500 {}||FAIL step 3 buy instrument 1: the holder's instrument listing gave status 500, expected 200
beforeOneInstrument_abortsBeforeAnyBuy|0|200 {"results":[{"id":"@A","amount":0}]}||FAIL step 3 buy instrument 1: the holder's instrument listing does not begin with two distinct canonical instrument ids
beforeListingThenGarbage_abortsBeforeAnyBuy|0|200 {"results":[{"id":"@A","amount":0},{"id":"@B","amount":0}]}garbage||FAIL step 3 buy instrument 1: the holder's instrument listing has results of JSON type [unreadable], expected an array; body [@SIZE bytes, not JSON]
EOF
)"
while IFS='|' read -r name buys before after expected <&3; do
    check="step3Fixture_$name"
    fresh_state
    STEP3_BEFORE="$(with_instrument_ids "${before:-$STEP3_DEFAULT_BEFORE}")"
    STEP3_AFTER="$(with_instrument_ids "${after:-$STEP3_DEFAULT_AFTER}")"
    run_isolated "$T/step3.out" scenario_step3_listings
    expected="$(with_instrument_ids "$expected")"
    expected="${expected//@SIZE/$(file_size "$PRIVATE_DIR/body")}"
    expect_line "$T/step3.out" "$expected"
    sent="$(grep -cxF "POST $B/v1/trade/buy" "$T/requests" || true)"
    if [[ "$sent" -ne "$buys" ]]; then
        reasons+=("$sent buys sent, expected $buys")
    fi
    if [[ "$expected" == PASS* ]]; then
        expect_rc 0
        expect_line "$T/requests" "BROWSER flag-off step 3 browser flag-off"
        if [[ ! -s "$FIXTURE" ]]; then
            reasons+=("no fixture was written")
        fi
    else
        expect_rc 1
        expect_no_line "$T/step3.out" "PASS step 3 holdings"
        expect_no_line "$T/requests" "BROWSER flag-off step 3 browser flag-off"
        expect_absent "$FIXTURE" "the fixture"
    fi
    conclude "$check"
done 3<<<"$step3_listing_cases"

# ---------------------------------------------------------------------------------------------
# write_fixture and signup

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_write_fixture() {
    write_fixture "$1"
}

# expected_fixture ALERTS: the fixture the browser check reads, in jq's default layout.
expected_fixture() {
    printf '{"evaluationIntervalSeconds":60,"holder":{"username":"%s","password":"%s","accountId":"%s"},"empty":{"username":"%s","password":"%s","accountId":"%s"},"alerts":%s}' \
        "pi-e2e-1-holder" "$SECRET_A" "$HOLDER_UUID" "pi-e2e-1-empty" "$SECRET_B" "$EMPTY_UUID" "$1" |
        command jq .
}

# name|ALERTS_JSON argument
fixture_cases='noAlerts|[]
twoAlerts|[{"id":"'"$ALERT_UUID"'","pair":"target_price","type":"TARGET_PRICE","direction":"ABOVE","threshold":"0.12345678","armingRevision":1},{"id":"'"$HOLDER_UUID"'","pair":"profit_loss","type":"PROFIT_LOSS","direction":"BELOW","threshold":"0.00000001","armingRevision":3}]'

while IFS='|' read -r name alerts <&3; do
    fresh_state
    run_isolated "$T/fixture.out" scenario_write_fixture "$alerts"
    expected_fixture "$alerts" >"$T/fixture.expected"

    check="writeFixture_${name}_writesExactFixture"
    expect_rc 0
    if ! cmp -s "$FIXTURE" "$T/fixture.expected"; then
        reasons+=("the fixture differs from $(tr -d '\n' <"$T/fixture.expected")")
    fi
    conclude "$check"

    check="writeFixture_${name}_keepsPasswordsOutOfJqArguments"
    if [[ ! -s "$T/jq-argv" ]]; then
        reasons+=("no jq command line was recorded")
    fi
    expect_secrets_absent "$T/jq-argv" "a jq command line"
    conclude "$check"

    check="writeFixture_${name}_createsOwnerOnlyFile"
    if [[ $MODES_ENFORCED -eq 0 ]]; then
        echo "INFO $check skipped: $(uname -s) does not enforce file modes"
    else
        if [[ "$(mode_of "$FIXTURE")" != 600 ]]; then
            reasons+=("mode $(mode_of "$FIXTURE"), expected 600")
        fi
        conclude "$check"
    fi
done 3<<<"$fixture_cases"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_write_fixture_newline_password() {
    HOLDER_PASSWORD="$SECRET_A"$'\n'"$SECRET_B"
    write_fixture '[]'
}

check="writeFixture_passwordWithNewline_failsWithoutWriting"
fresh_state
run_isolated "$T/fixture.out" scenario_write_fixture_newline_password
if [[ "$RC" -eq 0 ]]; then
    reasons+=("exit status 0, expected a failure")
fi
expect_absent "$FIXTURE" "the fixture"
conclude "$check"

check="writeFixture_alertsNotJson_fails"
fresh_state
run_isolated "$T/fixture.out" scenario_write_fixture '[{"id":'
if [[ "$RC" -eq 0 ]]; then
    reasons+=("exit status 0, expected a failure")
fi
conclude "$check"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_signup() {
    http() {
        printf '%s' "$3" >"$T/signup-body"
        echo "$1 $2" >>"$T/requests"
        case "$SIGNUP_CASE" in
            created) respond 201 application/json "{\"id\":\"${HOLDER_UUID^^}\"}" ;;
            reflectedJson) respond 400 application/json "{\"error\":\"\\u001b[2J bad\",\"password\":\"$SECRET_A\"}" ;;
            reflectedRaw) respond 400 text/plain "bad request "$'\033[2J\033]0;'"$SECRET_A"$'\a\r\n'"end" ;;
        esac
    }
    signup "step 3 signup holder" "pi-e2e-1-holder" "$SECRET_A" "Holder"
    echo "SIGNUP_ID $SIGNUP_ID"
}

check="signup_created_sendsEveryFieldAndPasses"
SIGNUP_CASE=created
fresh_state
run_isolated "$T/signup.out" scenario_signup
expect_rc 0
expect_line "$T/signup.out" "PASS step 3 signup holder"
expect_line "$T/signup.out" "SIGNUP_ID $HOLDER_UUID"
expect_line "$T/requests" "POST $U/api/auth/signup"
expected_body="{\"packageId\":\"$PACKAGE_ID\",\"firstName\":\"Portfolio\",\"lastName\":\"Holder\",\"username\":\"pi-e2e-1-holder\",\"email\":\"pi-e2e-1-holder@example.com\",\"password\":\"$SECRET_A\",\"origin\":\"WEB\",\"address\":\"1 Test Street, Springfield\"}"
if [[ "$(cat "$T/signup-body")" != "$expected_body" ]]; then
    reasons+=("the request body differs from $expected_body")
fi
conclude "$check"

check="signup_created_keepsPasswordOutOfJqArguments"
if [[ ! -s "$T/jq-argv" ]]; then
    reasons+=("no jq command line was recorded")
fi
expect_secrets_absent "$T/jq-argv" "a jq command line"
conclude "$check"

# name|description of the reflected body after "<size> bytes, "
signup_failures='reflectedJson|JSON object with 2 keys, names withheld: the body holds a fixture password
reflectedRaw|not JSON'
while IFS='|' read -r SIGNUP_CASE shape <&3; do
    check="signup_${SIGNUP_CASE}_abortsWithBodyDescriptionOnly"
    fresh_state
    run_isolated "$T/signup.out" scenario_signup
    expect_rc 1
    expect_line "$T/signup.out" \
        "FAIL step 3 signup holder: status 400, expected 201 with an id; body [$(file_size "$PRIVATE_DIR/body") bytes, $shape]"
    expect_secrets_absent "$T/signup.out" "the output"
    if has_unprintable "$T/signup.out"; then
        reasons+=("the output holds a byte outside printable ASCII")
    fi
    conclude "$check"
done 3<<<"$signup_failures"

# ---------------------------------------------------------------------------------------------
# http and expect_forbidden

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_http() {
    curl() {
        local body_file="" header_file=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o)
                    body_file="$2"
                    shift 2
                    ;;
                -D)
                    header_file="$2"
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        if [[ "$CURL_CASE" == transportError ]]; then
            echo "curl: (7) Failed to connect to 127.0.0.1 port 9" >&2
            return 7
        fi
        printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' >"$header_file"
        printf '{"raw":"\\u001b"}\033\000end' >"$body_file"
        printf '200 application/json'
    }
    http GET "$ALERTS_URL?accountId=$HOLDER_UUID"
    echo "STATUS $HTTP_STATUS ERROR $HTTP_ERROR"
    LC_ALL=C
    echo "BODY_LENGTH ${#HTTP_BODY}"
}

# name|status and error line http leaves|private file that must hold the response|length of
# HTTP_BODY, the body without its NUL byte
http_cases='response|STATUS 200 ERROR |body|20
transportError|STATUS 000 ERROR curl: (7) Failed to connect to 127.0.0.1 port 9|curl-error|0'
while IFS='|' read -r CURL_CASE status_line private_file body_length <&3; do
    check="http_${CURL_CASE}_keepsRawFilesInPrivateDirOnly"
    fresh_state
    run_isolated "$T/http.out" scenario_http
    expect_rc 0
    expect_line "$T/http.out" "$status_line"
    if [[ ! -s "$PRIVATE_DIR/$private_file" ]]; then
        reasons+=("$PRIVATE_DIR/$private_file is missing or empty")
    fi
    if [[ "$(entries "$RUN_DIR" '*')" != "deleted owned" || -n "$(entries "$RUN_DIR" '.[!.]*')" ]]; then
        reasons+=("the run directory holds [$(entries "$RUN_DIR" '*') $(entries "$RUN_DIR" '.[!.]*')], expected only deleted and owned")
    fi
    conclude "$check"

    check="http_${CURL_CASE}_leavesBodyTextWithoutNulOrWarning"
    expect_line "$T/http.out" "BODY_LENGTH $body_length"
    if [[ -s "$T/http.out.err" ]]; then
        reasons+=("stderr holds [$(LC_ALL=C tr -c '\040-\176' '?' <"$T/http.out.err")]")
    fi
    conclude "$check"
done 3<<<"$http_cases"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_forbidden() {
    http() {
        respond 403 application/json "$FORBIDDEN_BODY"
        # shellcheck disable=SC2059 # The suffix is a printf format, so it can hold a NUL byte.
        printf "$FORBIDDEN_CASE_SUFFIX" >>"$PRIVATE_DIR/body"
        HTTP_BODY="$(tr -d '\000' <"$PRIVATE_DIR/body")"
    }
    expect_forbidden "step 2 GET insights forbidden" GET "$INSIGHTS_URL/$HOLDER_UUID"
}

# Each case's body is the exact forbidden body followed by the printf format FORBIDDEN_CASE_SUFFIX.
for forbidden_case in exactBody trailingNewline trailingEscape nulAndSuffix; do
    case "$forbidden_case" in
        exactBody) FORBIDDEN_CASE_SUFFIX='' ;;
        trailingNewline) FORBIDDEN_CASE_SUFFIX='\n' ;;
        trailingEscape) FORBIDDEN_CASE_SUFFIX='\033' ;;
        nulAndSuffix) FORBIDDEN_CASE_SUFFIX='\000{"extra":1}' ;;
    esac
    fresh_state
    run_isolated "$T/forbidden.out" scenario_forbidden
    if [[ "$forbidden_case" == exactBody ]]; then
        check="expectForbidden_exactBody_passes"
        expect_line "$T/forbidden.out" "PASS step 2 GET insights forbidden"
    else
        check="expectForbidden_${forbidden_case}_failsOnExactBytesWithDescription"
        if [[ "$forbidden_case" == trailingNewline ]]; then
            shape="JSON object with 1 key [error]"
        else
            shape="not JSON"
        fi
        expect_line "$T/forbidden.out" \
            "FAIL step 2 GET insights forbidden: status 403, content type [application/json], body [$(file_size "$PRIVATE_DIR/body") bytes, $shape]; expected 403 application/json $FORBIDDEN_BODY"
    fi
    conclude "$check"
done

# ---------------------------------------------------------------------------------------------
# body_snippet, describe_file, jcheck and fail

check="bodySnippet_emptyBody_printsEmpty"
fresh_state
: >"$PRIVATE_DIR/body"
if [[ "$(body_snippet)" != "empty" ]]; then
    reasons+=("printed [$(body_snippet)], expected [empty]")
fi
conclude "$check"

# name|printf format of the body, %s standing for the holder password|description after
# "<size> bytes, "
body_cases='controlBytesAndSecretNotJson|error \033[31m%s\a\r\n|not JSON
reflectedSecretValue|{"error":"bad","password":"%s"}|JSON object with 2 keys, names withheld: the body holds a fixture password
reflectedSecretKey|{"%s":1}|JSON object with 1 key, names withheld: the body holds a fixture password
hostileKeyNames|{"\\u001b[2J":1,"a b,c":2,"\\u00e9t\\u00e9":3,"ok_key.x-y":4}|JSON object with 4 keys [??2J,a?b?c,?t?,ok_key.x-y]
longKeyName|{"0123456789012345678901234567890123456789":1}|JSON object with 1 key [01234567890123456789012345678901]
twelveKeys|{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,"k":11,"l":12}|JSON object with 12 keys [a,b,c,d,e,f,g,h,i,j,...]
emptyObject|{}|JSON object with 0 keys
arrayOfThree|[1,2,3]|JSON array of 3 items
arrayOfOne|[{"password":"%s"}]|JSON array of 1 item
reflectedSecretString|"%s"|JSON string
twoDocuments|{} {}|not JSON
rawControlInString|{"a":"\033[2J"}|not JSON'
while IFS='|' read -r name format shape <&3; do
    check="bodySnippet_${name}_describesWithoutBodyBytes"
    fresh_state
    # shellcheck disable=SC2059 # The case's format is the body's template.
    printf "$format" "$SECRET_A" >"$PRIVATE_DIR/body"
    expected="$(file_size "$PRIVATE_DIR/body") bytes, $shape"
    actual="$(body_snippet)"
    if [[ "$actual" != "$expected" ]]; then
        reasons+=("printed [$(printf '%s' "$actual" | LC_ALL=C tr -c '\040-\176' '?')], expected [$expected]")
    fi
    conclude "$check"
done 3<<<"$body_cases"

check="describeFile_missingFile_printsUnreadable"
fresh_state
if [[ "$(describe_file "$PRIVATE_DIR/missing" 2>/dev/null)" != "unreadable" ]]; then
    reasons+=("printed [$(describe_file "$PRIVATE_DIR/missing" 2>/dev/null)], expected [unreadable]")
fi
conclude "$check"

# name|jq filter|printf format of the text, %s standing for the holder password|description
jcheck_cases='notJsonWithSecret|.a|oops \033]0;%s\a|not JSON
filterErrorOnArray|.a.b|[1,2]|JSON array of 2 items'
while IFS='|' read -r name filter format shape <&3; do
    check="jcheck_${name}_failsWithTextDescriptionOnly"
    fresh_state
    # shellcheck disable=SC2059 # The case's format is the text's template.
    text="$(printf "$format" "$SECRET_A")"
    printf '%s' "$text" >"$T/jcheck.text"
    jcheck "step 5 two allocations" "$filter" "$text" >"$T/jcheck.out"
    expect_line "$T/jcheck.out" \
        "FAIL step 5 two allocations: unreadable JSON [$(file_size "$T/jcheck.text") bytes, $shape]"
    conclude "$check"
done 3<<<"$jcheck_cases"

for name in controlAndUtf8Bytes printableAscii; do
    case "$name" in
        controlAndUtf8Bytes)
            reason="a"$'\033'"[31mb"$'\a'"c"$'\r'"d"$'\n'"e"$'\t'"f"$'\177'"g"$'\303\251'"h"
            expected="FAIL check: a?[31mb?c?d?e?f?g??h"
            ;;
        printableAscii)
            reason="status 400; body [12 bytes, not JSON] ~!"
            expected="FAIL check: $reason"
            ;;
    esac
    check="fail_${name}_printsOnePrintableAsciiLine"
    fresh_state
    fail "check" "$reason" >"$T/fail.out"
    if [[ "$(cat "$T/fail.out")" != "$expected" || "$(wc -l <"$T/fail.out" | tr -d ' ')" -ne 1 ]]; then
        reasons+=("printed [$(LC_ALL=C tr -c '\040-\176' '?' <"$T/fail.out")], expected [$expected] on one line")
    fi
    conclude "$check"
done

for name in holderPasswordAmidControlBytes emptyPasswordInJson bothPasswordsRepeated \
    globCharactersInPassword passwordsNotGenerated; do
    fresh_state
    check="fail_${name}_redactsPasswordsOnOnePrintableAsciiLine"
    case "$name" in
        holderPasswordAmidControlBytes)
            reason="riskLevel ["$'\033'"[2J$SECRET_A"$'\a'"]"
            expected="FAIL check: riskLevel [?[2J<redacted>?]"
            ;;
        emptyPasswordInJson)
            reason="got {\"note\":\"$SECRET_B\"}"
            expected="FAIL check: got {\"note\":\"<redacted>\"}"
            ;;
        bothPasswordsRepeated)
            reason="$SECRET_A $SECRET_B $SECRET_A$SECRET_B"
            expected="FAIL check: <redacted> <redacted> <redacted><redacted>"
            ;;
        globCharactersInPassword)
            HOLDER_PASSWORD='Pi-*?[a]'
            reason="Pi-abc Pi-*?[a] Pi-a"
            expected="FAIL check: Pi-abc <redacted> Pi-a"
            ;;
        passwordsNotGenerated)
            check="fail_${name}_printsReasonUnchanged"
            HOLDER_PASSWORD=""
            EMPTY_PASSWORD=""
            reason="status 400 Pi-"
            expected="FAIL check: $reason"
            ;;
    esac
    fail "check" "$reason" >"$T/fail.out"
    if [[ "$(cat "$T/fail.out")" != "$expected" || "$(wc -l <"$T/fail.out" | tr -d ' ')" -ne 1 ]]; then
        reasons+=("printed [$(LC_ALL=C tr -c '\040-\176' '?' <"$T/fail.out")], expected [$expected] on one line")
    fi
    conclude "$check"
done

check="fail_called_countsInCurrentShell"
fresh_state
fail "check" "reason" >/dev/null
fail "check" "reason" >/dev/null
if [[ "$failed" -ne 2 ]]; then
    reasons+=("failed is $failed after two calls, expected 2")
fi
conclude "$check"

# ---------------------------------------------------------------------------------------------
# Step 4 evidence

# The flag service's answer to step 4's PUT: the flag, as feature-flag-service returns it.
STEP4_ACK="{\"id\":\"$FLAG_ID\",\"enabled\":true}"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_step4() {
    http() {
        if [[ "$1" == PUT ]]; then
            respond 200 application/json "$STEP4_ACK"
        else
            respond 200 application/json "$INSIGHTS_CASE_BODY"
        fi
    }
    step4_enable
    printf '%s' "$HOLDER_INSIGHTS" >"$T/holder-insights"
}

# name|printf format of the insights response, %s standing for the holder password
step4_cases='jsonInsights|{"totalValue":1.5,"note":"\\u001b[2J %s","allocations":[]}
insightsNotJson|<html>\033[2J%s</html>'
while IFS='|' read -r name format <&3; do
    check="step4Enable_${name}_writesNoResponseCopyToRunDir"
    fresh_state
    # shellcheck disable=SC2059 # The case's format is the body's template.
    INSIGHTS_CASE_BODY="$(printf "$format" "$SECRET_A")"
    run_isolated "$T/step4.out" scenario_step4
    expect_rc 0
    expect_line "$T/step4.out" "PASS step 4 first insights request"
    if [[ "$(cat "$T/holder-insights")" != "$INSIGHTS_CASE_BODY" ]]; then
        reasons+=("HOLDER_INSIGHTS is not the response body step 5 reads")
    fi
    expect_absent "$RUN_DIR/insights-holder.json" "insights-holder.json"
    if [[ "$(entries "$RUN_DIR" '*')" != "deleted owned" || -n "$(entries "$RUN_DIR" '.[!.]*')" ]]; then
        reasons+=("the run directory holds [$(entries "$RUN_DIR" '*') $(entries "$RUN_DIR" '.[!.]*')], expected only deleted and owned")
    fi
    conclude "$check"
done 3<<<"$step4_cases"

# name|the PUT's 200 answer, which does not report this flag's JSON boolean true: step 4 stops
# before its insights request, and the reason describes the body without its text.
step4_ack_cases='enabledString|{"id":"portfolio-insights-enabled","enabled":"true"}
otherFlag|{"id":"db_not_responding","enabled":true}
enabledFalse|{"id":"portfolio-insights-enabled","enabled":false}'
while IFS='|' read -r name ack <&3; do
    check="step4Enable_${name}Acknowledgement_abortsBeforeInsightsRequest"
    fresh_state
    STEP4_ACK="$ack"
    INSIGHTS_CASE_BODY='{"totalValue":0,"allocations":[]}'
    run_isolated "$T/step4.out" scenario_step4
    expect_rc 1
    expect_line "$T/step4.out" \
        "FAIL step 4 enable flag: PUT {\"enabled\": true} gave status 200; body [${#ack} bytes, JSON object with 2 keys [id,enabled]]"
    expect_no_line "$T/step4.out" "PASS step 4 enable flag"
    expect_no_line "$T/step4.out" "PASS step 4 first insights request"
    conclude "$check"
done 3<<<"$step4_ack_cases"
STEP4_ACK="{\"id\":\"$FLAG_ID\",\"enabled\":true}"

# ---------------------------------------------------------------------------------------------
# cleanup

# seed_private: a fixture holding both passwords and a raw response in the private directory.
seed_private() {
    printf '{"holder":{"password":"%s"},"empty":{"password":"%s"}}\n' "$SECRET_A" "$SECRET_B" >"$FIXTURE"
    printf 'raw %s\n' "$SECRET_A" >"$PRIVATE_DIR/body"
    : >"$PRIVATE_DIR/headers"
}

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_cleanup() {
    case "$1" in
        passingRun)
            trap cleanup EXIT
            exit 0
            ;;
        failedRun)
            trap cleanup EXIT
            abort "step 1 readiness" "deadline 300 s expired"
            ;;
        interruptedRun)
            trap cleanup EXIT
            trap on_signal INT TERM
            kill -TERM "$BASHPID"
            echo "INFO not reached"
            ;;
        interruptedDuringCleanup)
            http() {
                kill -TERM "$BASHPID"
                respond 200 application/json '{"enabled":true}'
            }
            echo "$ALERT_UUID" >"$RUN_DIR/owned"
            trap cleanup EXIT
            trap on_signal INT TERM
            exit 0
            ;;
        removalFails)
            rm() {
                return 1
            }
            trap cleanup EXIT
            exit 0
            ;;
        interruptedDuringCleanupRemovalFails)
            rm() {
                return 1
            }
            http() {
                kill -TERM "$BASHPID"
                respond 200 application/json '{"enabled":true}'
            }
            echo "$ALERT_UUID" >"$RUN_DIR/owned"
            trap cleanup EXIT
            trap on_signal INT TERM
            exit 0
            ;;
    esac
}

removed_line="INFO cleanup: fixture and private working files removed"
interrupted_line="FAIL cleanup: interrupted before it finished: owned alerts may be left in place and flag $FLAG_ID may not be restored"
for cleanup_case in passingRun failedRun interruptedRun interruptedDuringCleanup removalFails \
    interruptedDuringCleanupRemovalFails; do
    fresh_state
    seed_private
    run_isolated "$T/cleanup.out" scenario_cleanup "$cleanup_case"
    case "$cleanup_case" in
        passingRun)
            check="cleanup_passingRun_removesFixtureAndPrivateDir"
            expect_rc 0
            ;;
        failedRun)
            check="cleanup_failedRun_removesFixtureAndKeepsFailure"
            expect_rc 1
            ;;
        interruptedRun)
            check="cleanup_interruptedRun_removesFixtureAndExits130"
            expect_rc 130
            expect_no_line "$T/cleanup.out" "INFO not reached"
            ;;
        interruptedDuringCleanup)
            check="cleanup_interruptedDuringCleanup_removesPrivateDirAndExits130"
            expect_rc 130
            expect_line "$T/cleanup.out" "$interrupted_line"
            ;;
        removalFails)
            check="cleanup_removalFails_failsCleanupAndRun"
            expect_rc 1
            expect_line "$T/cleanup.out" \
                "FAIL cleanup: fixture $FIXTURE and private directory $PRIVATE_DIR not removed"
            expect_no_line "$T/cleanup.out" "$removed_line"
            ;;
        interruptedDuringCleanupRemovalFails)
            check="cleanup_interruptedDuringCleanupRemovalFails_reportsWhatRemainsAndExits130"
            expect_rc 130
            expect_line "$T/cleanup.out" \
                "$interrupted_line; fixture $FIXTURE and private directory $PRIVATE_DIR not removed"
            ;;
    esac
    case "$cleanup_case" in
        passingRun | failedRun | interruptedRun)
            expect_line "$T/cleanup.out" "$removed_line"
            expect_line "$T/cleanup.out" "PASS cleanup"
            expect_absent "$PRIVATE_DIR" "the private directory"
            ;;
        interruptedDuringCleanup)
            expect_absent "$PRIVATE_DIR" "the private directory"
            ;;
        removalFails | interruptedDuringCleanupRemovalFails)
            if [[ ! -f "$FIXTURE" ]]; then
                reasons+=("the fixture is gone although rm failed, so the stub was not used")
            fi
            ;;
    esac
    case "$cleanup_case" in
        interruptedDuringCleanup | interruptedDuringCleanupRemovalFails)
            # The second interrupt still ends the run with one verdict and one SUMMARY line.
            expect_no_line "$T/cleanup.out" "PASS cleanup"
            expect_line "$T/cleanup.out" "INFO run dir $RUN_DIR"
            expect_line "$T/cleanup.out" "SUMMARY 0 passed, 1 failed"
            if [[ "$(grep -c '^FAIL cleanup: ' "$T/cleanup.out" || true)" -ne 1 ||
                "$(grep -c '^SUMMARY ' "$T/cleanup.out" || true)" -ne 1 ]]; then
                reasons+=("expected one FAIL cleanup line and one SUMMARY line")
            fi
            ;;
    esac
    if [[ ! -d "$RUN_DIR" ]]; then
        reasons+=("the run directory was removed")
    fi
    expect_secrets_absent "$T/cleanup.out" "the output"
    conclude "$check"
done

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_remove_private() {
    # rm stand-in: removes what it is given, then fails for the path RM_CASE names, so that
    # path is gone although rm reports it was not removed.
    rm() {
        command rm "$@"
        case "$RM_CASE" in
            fixtureRmFails) [[ "${!#}" != "$FIXTURE" ]] ;;
            directoryRmFails) [[ "${!#}" != "$PRIVATE_DIR" ]] ;;
            bothRmFail) return 1 ;;
        esac
    }
    remove_private
    echo "PRIVATE_LEFT [$PRIVATE_LEFT]"
}

for RM_CASE in fixtureRmFails directoryRmFails bothRmFail; do
    check="removePrivate_${RM_CASE}_reportsNotRemovedThoughNothingRemains"
    fresh_state
    seed_private
    case "$RM_CASE" in
        fixtureRmFails) expected="fixture $FIXTURE" ;;
        directoryRmFails) expected="private directory $PRIVATE_DIR" ;;
        bothRmFail) expected="fixture $FIXTURE and private directory $PRIVATE_DIR" ;;
    esac
    run_isolated "$T/remove.out" scenario_remove_private
    expect_rc 0
    expect_line "$T/remove.out" "PRIVATE_LEFT [$expected]"
    expect_absent "$PRIVATE_DIR" "the private directory"
    conclude "$check"
done

# ---------------------------------------------------------------------------------------------
# restrict_private_dir

# open_private_dir: a new PRIVATE_DIR that others can open, as a directory under a shared
# temporary directory starts out: inherited ACL entries on Windows, mode 755 elsewhere.
open_private_dir() {
    PRIVATE_DIR="$(mktemp -d "$T/restrict.XXXXXX")"
    if [[ $MODES_ENFORCED -eq 1 ]]; then
        command chmod 755 "$PRIVATE_DIR"
    fi
}

check="restrictPrivateDir_openDir_leavesOnlyCurrentUser"
fresh_state
open_private_dir
if [[ $MODES_ENFORCED -eq 0 ]] && [[ "$(list_acl "$PRIVATE_DIR" | grep -c ':(' || true)" -le 1 ]]; then
    reasons+=("the new directory already lists at most one entry, so the check proves nothing")
fi
run_isolated "$T/restrict.out" restrict_private_dir
expect_rc 0
if [[ -s "$T/restrict.out.err" ]]; then
    reasons+=("stderr holds [$(LC_ALL=C tr -c '\040-\176' '?' <"$T/restrict.out.err")]")
fi
if [[ $MODES_ENFORCED -eq 0 ]]; then
    list_acl "$PRIVATE_DIR" >"$T/restrict.acl"
    expect_user_only_acl "$T/restrict.acl" "the directory" "(OI)(CI)(F)"
    : >"$PRIVATE_DIR/fixture.json"
    list_acl "$PRIVATE_DIR/fixture.json" >"$T/restrict-file.acl"
    expect_user_only_acl "$T/restrict-file.acl" "a file created inside" "(I)(F)"
elif [[ "$(mode_of "$PRIVATE_DIR")" != 700 ]]; then
    reasons+=("mode $(mode_of "$PRIVATE_DIR"), expected 700")
fi
conclude "$check"

# shellcheck disable=SC2329 # Invoked through run_isolated.
scenario_restrict() {
    # Stand-ins for the permission tool of each platform; the platform calls only its own.
    case "$RESTRICT_CASE" in
        toolFails)
            icacls() {
                echo "icacls stand-in: Access is denied."
                return 5
            }
            chmod() {
                return 1
            }
            ;;
        toolChangesNothing)
            icacls() {
                if [[ " $* " == *" /inheritance:r "* ]]; then
                    return 0
                fi
                command icacls "$@"
            }
            chmod() {
                return 0
            }
            ;;
        whoamiUnavailable)
            cygpath() {
                if [[ "$1" == -S ]]; then
                    echo "$T/no-system-dir"
                    return 0
                fi
                command cygpath "$@"
            }
            ;;
        windowsPathUnavailable)
            cygpath() {
                if [[ "$1" == -w ]]; then
                    return 1
                fi
                command cygpath "$@"
            }
            ;;
        listingFails)
            icacls() {
                if [[ " $* " == *" /inheritance:r "* ]]; then
                    command icacls "$@"
                    return
                fi
                return 1
            }
            ;;
    esac
    restrict_private_dir
}

for RESTRICT_CASE in toolFails toolChangesNothing whoamiUnavailable windowsPathUnavailable \
    listingFails; do
    check="restrictPrivateDir_${RESTRICT_CASE}_failsWithReason"
    if [[ $MODES_ENFORCED -eq 1 && "$RESTRICT_CASE" != tool* ]]; then
        echo "INFO $check skipped: only Windows identifies the user and lists the ACL"
        continue
    fi
    fresh_state
    open_private_dir
    # The start of the reason each case must give, after the common prefix.
    case "$MODES_ENFORCED $RESTRICT_CASE" in
        "0 toolFails") reason="icacls failed: icacls stand-in: Access is denied." ;;
        "0 toolChangesNothing") reason="icacls lists [" ;;
        "0 whoamiUnavailable") reason="whoami /user did not report the current user and SID." ;;
        "0 windowsPathUnavailable") reason="cygpath -w gave no Windows path." ;;
        "0 listingFails") reason="icacls could not list its entries." ;;
        "1 toolFails") reason="chmod 700 failed." ;;
        "1 toolChangesNothing") reason="it shows [drwxr-xr-x], not drwx------" ;;
    esac
    run_isolated "$T/restrict.out" scenario_restrict
    if [[ "$RC" -eq 0 ]]; then
        reasons+=("exit status 0, expected a failure")
    fi
    if ! grep -qF "Could not restrict the private working directory $PRIVATE_DIR to this user: $reason" \
        "$T/restrict.out.err"; then
        reasons+=("stderr holds [$(LC_ALL=C tr -c '\040-\176' '?' <"$T/restrict.out.err")], expected the reason [$reason]")
    fi
    conclude "$check"
done

# ---------------------------------------------------------------------------------------------
# e2e.sh setup, run as a whole with docker and node stubbed and no stack

# write_stub PATH LINE...: an executable script made of the given lines.
write_stub() {
    local path="$1"
    shift
    printf '%s\n' '#!/usr/bin/env bash' "$@" >"$path"
    chmod +x "$path"
}

mkdir -p "$T/bin" "$T/bin-mktemp"
write_stub "$T/bin/docker" \
    '# docker stand-in: "compose version" succeeds; "compose ps" lists no service and records' \
    '# the mode of each private directory the script under test has created, and on Windows' \
    '# its icacls listing.' \
    'if [[ " $* " == *" ps "* ]]; then' \
    '    for dir in "${TMPDIR:-/tmp}"/pi-e2e-private.*; do' \
    '        if [[ -d "$dir" ]]; then' \
    '            stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir"' \
    '            if command -v cygpath >/dev/null 2>&1; then' \
    '                acls="${TMPDIR:-/tmp}/private-acls"' \
    '                MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" icacls "$(cygpath -w "$dir")" >>"$acls"' \
    '            fi' \
    '        fi' \
    '    done >>"${TMPDIR:-/tmp}/private-modes"' \
    'fi' \
    'exit 0'
write_stub "$T/bin/node" 'exit 0'
write_stub "$T/bin-mktemp/mktemp" \
    '# mktemp stand-in: refuses the private directory, creates everything else.' \
    'case "$*" in *pi-e2e-private.*) exit 1 ;; esac' \
    "exec '$REAL_MKTEMP' \"\$@\""
mkdir -p "$T/bin-restrict"
write_stub "$T/bin-restrict/icacls" \
    '# icacls stand-in: every call fails, as when the ACL cannot be changed.' \
    'echo "icacls stand-in: Access is denied."' \
    'exit 5'
write_stub "$T/bin-restrict/chmod" \
    '# chmod stand-in: every call fails, as when the mode cannot be changed.' \
    'echo "chmod stand-in: Operation not permitted" >&2' \
    'exit 1'

# run_e2e_setup PATH_PREFIX [OPTION...]: runs e2e.sh with PATH_PREFIX first on PATH and TMPDIR
# set to a new directory of its own, CASE_TMP; sets RC and leaves the output in CASE_OUT.
run_e2e_setup() {
    local prefix="$1"
    shift
    CASE_TMP="$(mktemp -d "$T/setup.XXXXXX")"
    CASE_OUT="$CASE_TMP.out"
    set +e
    TMPDIR="$CASE_TMP" PATH="$prefix:$PATH" "$BASH" "$E2E" --project pi-credentials-test \
        --compose-file "$E2E" --base-url http://127.0.0.1:9 "$@" >"$CASE_OUT" 2>&1
    RC=$?
    set -e
}

check="e2eSetup_evidenceDirUncreatable_exits2AndRemovesBothDirs"
: >"$T/not-a-dir"
run_e2e_setup "$T/bin" --evidence-dir "$T/not-a-dir/evidence"
expect_rc 2
if ! grep -qF "Could not create the evidence directory: $T/not-a-dir/evidence" "$CASE_OUT"; then
    reasons+=("no evidence-directory error in the output")
fi
if [[ -n "$(entries "$CASE_TMP" 'pi-e2e*')" ]]; then
    reasons+=("left behind: $(entries "$CASE_TMP" 'pi-e2e*')")
fi
conclude "$check"

check="e2eSetup_privateDirUncreatable_exits2AndRemovesRunDir"
run_e2e_setup "$T/bin-mktemp:$T/bin"
expect_rc 2
if ! grep -qF "Could not create a private working directory under $CASE_TMP." "$CASE_OUT"; then
    reasons+=("no private-directory error in the output")
fi
if [[ -n "$(entries "$CASE_TMP" 'pi-e2e*')" ]]; then
    reasons+=("left behind: $(entries "$CASE_TMP" 'pi-e2e*')")
fi
conclude "$check"

check="e2eSetup_privateDirUnrestrictable_exits2AndRemovesBothDirs"
run_e2e_setup "$T/bin-restrict:$T/bin"
expect_rc 2
if ! grep -qF "Could not restrict the private working directory $CASE_TMP/pi-e2e-private." "$CASE_OUT"; then
    reasons+=("no restriction error in the output")
fi
if grep -q '^\(PASS\|FAIL\|INFO\) ' "$CASE_OUT"; then
    reasons+=("the run went on past setup")
fi
if [[ -n "$(entries "$CASE_TMP" 'pi-e2e*')" ]]; then
    reasons+=("left behind: $(entries "$CASE_TMP" 'pi-e2e*')")
fi
conclude "$check"

check="e2eSetup_firstStepAborts_removesPrivateDirAndKeepsRunDir"
run_e2e_setup "$T/bin"
expect_rc 1
if ! grep -q '^FAIL step 1 ' "$CASE_OUT"; then
    reasons+=("no FAIL line for step 1 in the output")
fi
expect_line "$CASE_OUT" "$removed_line"
expect_line "$CASE_OUT" "PASS cleanup"
if [[ ! -s "$CASE_TMP/private-modes" ]]; then
    reasons+=("no private directory existed beside the run directory during step 1")
fi
if [[ -n "$(entries "$CASE_TMP" 'pi-e2e-private.*')" ]]; then
    reasons+=("left behind: $(entries "$CASE_TMP" 'pi-e2e-private.*')")
fi
if [[ ! "$(entries "$CASE_TMP" 'pi-e2e.*')" =~ ^pi-e2e\.[^\ ]+$ ]]; then
    reasons+=("run directories left: [$(entries "$CASE_TMP" 'pi-e2e.*')], expected one")
fi
conclude "$check"

check="e2eSetup_privateDir_isOwnerOnly"
if [[ $MODES_ENFORCED -eq 0 ]]; then
    if [[ ! -s "$CASE_TMP/private-acls" ]]; then
        reasons+=("no icacls listing of the private directory was recorded during step 1")
    else
        expect_user_only_acl "$CASE_TMP/private-acls" "the private directory" "(OI)(CI)(F)"
    fi
elif [[ "$(sed -n '1p' "$CASE_TMP/private-modes" 2>/dev/null)" != 700 ]]; then
    reasons+=("mode [$(sed -n '1p' "$CASE_TMP/private-modes" 2>/dev/null)], expected 700")
fi
conclude "$check"

summarize
if [[ "$tests_failed" -ne 0 ]]; then
    exit 1
fi
