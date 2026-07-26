#!/bin/bash
# Program coordinator for the VM-resident orchestration loop. Runs ONLY on
# worker 0, inside tmux session "sweep". The workstation may die at any point;
# this loop, the agents, and the GCS journal carry the program.
#
# Per run: publish spec-<gen>.env -> agents (this host included) launch it ->
# watch the LOCAL /tmp/train.log tag-scoped segment for a verdict -> journal
# -> next. Stage failure stops the program (later stages depend on earlier
# verdicts); DIVERGED is a verdict, not a failure.
#
# Resume: the GCS journal keys completed runs as "<runs-file>:<run-name>"; a
# reboot (startup_script re-starts this) skips them and republishes only what
# is left.
set -uo pipefail

REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
CONTROL="${CONTROL:-gs://llm-architectures-eu/nanogptjax/control}"
TRAIN_LOG="/tmp/train.log"
COORD_LOG="/tmp/coordinator.log"
EXPECT_WORKERS="${EXPECT_WORKERS:-}"   # resolved below from control plane
RUN_TIMEOUT_SECONDS_DEFAULT="${RUN_TIMEOUT_SECONDS:-3600}"
HEARTBEAT_EVERY_S="${HEARTBEAT_EVERY_S:-1800}"

_ts() { date -Is; }
log() { echo "[coord $(_ts)] $*" | tee -a "$COORD_LOG"; }

# ntfy straight from the VM (.env ships in the code tarball). No-op if unset.
NTFY_TOPIC="$(grep -m1 '^NTFY_TOPIC=' "$REPO_DIR/.env" 2>/dev/null | cut -d= -f2)"
notify() {
    [ -n "$NTFY_TOPIC" ] || return 0
    curl -fsS -o /dev/null -m 15 -d "$1" "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

# ---- one-coordinator guard + program resolution ----
PROGRAM="$(gcloud storage cat "$CONTROL/ACTIVE_PROGRAM" 2>/dev/null | tr -d '[:space:]')"
case "$PROGRAM" in
    ""|done:*) log "no active program ('$PROGRAM') — exiting"; exit 0 ;;
esac
PREFIX="$CONTROL/$PROGRAM"

# Ship the coordinator log to GCS. Called from both gates and every heartbeat.
# Previously this happened ONLY inside the heartbeat loop, which runs after the
# readiness gate closes — so a stall before that point left nothing in GCS at
# all (2026-07-25: a landing came up 7/8, stalled the gate, was preempted, and
# left no journal/heartbeat/log to diagnose from). Landings are the scarce
# resource in a drought; every one must leave evidence.
push_log() { gcloud storage cp "$COORD_LOG" "$PREFIX/logs/coordinator.log" 2>/dev/null || true; }
# Every script-controlled exit ships the log, including the ABORT paths below
# (missing runs file, run failure, run timeout) which previously exited silent.
trap push_log EXIT

# Worker count: env override > control-plane file > default 16. An 8-host
# v5e-32 slice needs 8 or the readiness & quiescence gates (which wait for
# EXPECT_WORKERS) never close. Kept in GCS so self-heal reboots read it too.
if [ -z "$EXPECT_WORKERS" ]; then
    EXPECT_WORKERS="$(gcloud storage cat "$PREFIX/expect_workers" 2>/dev/null | tr -d '[:space:]')"
fi
EXPECT_WORKERS="${EXPECT_WORKERS:-16}"
log "expect_workers=$EXPECT_WORKERS"

# Test the alerting pipe BEFORE trusting it (the dead-pipe lesson: a silent
# notifier is worse than none).
notify "vm-coordinator: starting program '$PROGRAM' on $(hostname) $(_ts)"
log "program=$PROGRAM prefix=$PREFIX ntfy=$([ -n "$NTFY_TOPIC" ] && echo on || echo OFF)"

# ---- readiness gate: all agents booted ----
# Log WHICH workers reported, not just how many: a stalled gate is almost always
# one named host that never came up, and the missing id is the whole diagnosis.
for _i in $(seq 1 60); do
    booted="$(gcloud storage ls "$PREFIX/boot/w*" 2>/dev/null | sed 's#.*/##' | sort -V | tr '\n' ' ')"
    booted="${booted% }"
    n="$(printf '%s' "$booted" | wc -w)"
    log "readiness: $n/$EXPECT_WORKERS agents booted [$booted]"
    push_log
    [ "$n" -ge "$EXPECT_WORKERS" ] && break
    if [ "$_i" -eq 60 ]; then
        log "ABORT: agents never became ready — booted [$booted]"
        push_log
        notify "vm-coordinator ABORT: only $n/$EXPECT_WORKERS agents booted [$booted]"
        exit 1
    fi
    sleep 20
done

# ---- resume state ----
journal="$(gcloud storage cat "$PREFIX/journal" 2>/dev/null || true)"
gen=0
for u in $(gcloud storage ls "$PREFIX/spec-*.env" 2>/dev/null); do
    n="${u##*/spec-}"; n="${n%.env}"
    [ "$n" -gt "$gen" ] 2>/dev/null && gen="$n"
done
log "resume: generation=$gen, journal has $(printf '%s' "$journal" | grep -c . || true) entries"

journal_add() { # key
    journal="$(printf '%s\n%s' "$journal" "$1")"
    printf '%s\n' "$journal" | gcloud storage cp - "$PREFIX/journal"
}

last_heartbeat=0
heartbeat() {
    now=$(date +%s)
    echo "$(_ts) gen=$gen" | gcloud storage cp - "$PREFIX/heartbeat" 2>/dev/null
    push_log
    if [ $(( now - last_heartbeat )) -ge "$HEARTBEAT_EVERY_S" ]; then
        notify "vm-coordinator heartbeat: program=$PROGRAM gen=$gen $(_ts)"
        last_heartbeat=$now
    fi
}

# ---- quiescence gate ----
# Never publish a spec while any host is still executing (or crashing out
# of) an older one: a recovery republish that races the survivors' collective
# failure detection produces a rendezvous the late hosts can't join in time
# (2026-07-20 drill: DEADLINE_EXCEEDED at +5 min). All 16 agents must report
# "idle" at the current generation first; the survivors' crash-out takes a
# few minutes and this gate simply absorbs it.
wait_quiescent() { # current-gen
    for _q in $(seq 1 60); do
        n="$(gcloud storage cat "$PREFIX/state/w*" 2>/dev/null | grep -c "^idle gen=$1 ")"
        [ "$n" -ge "$EXPECT_WORKERS" ] && return 0
        log "quiescence: $n/$EXPECT_WORKERS idle at gen=$1 (waiting)"
        sleep 20
    done
    log "ABORT: fleet never became quiescent at gen=$1"
    push_log
    notify "vm-coordinator ABORT: fleet stuck — $n/$EXPECT_WORKERS idle at gen=$1"
    exit 1
}

# ---- verdict probes: local log, tag-scoped, tail-not-head ----
seg() { awk -v t="tag=$1" 'index($0, t){m=NR} m && NR>=m' "$TRAIN_LOG"; }
run_status() { seg "$1" | grep -E 'exited with status|Reached maximum training steps|DIVERGED at step|Traceback|DEADLINE_EXCEEDED|RESOURCE_EXHAUSTED' | tail -6; }
run_best_loss() { seg "$1" | grep 'Best loss' | tail -1; }

# ---- main loop over program.list (fd 3: loop body shells out) ----
mapfile -t RUNS_FILES < <(gcloud storage cat "$PREFIX/program.list")
log "program.list: ${RUNS_FILES[*]}"

for rf in "${RUNS_FILES[@]}"; do
    [ -n "$rf" ] || continue
    if [ ! -f "$REPO_DIR/$rf" ]; then
        log "ABORT: missing runs file $rf"
        notify "vm-coordinator ABORT: missing runs file $rf"
        exit 1
    fi
    log "=== stage $rf ==="
    run_no=0
    while IFS= read -r -u3 line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        run_no=$(( run_no + 1 ))
        run_name="$(printf '%s\n' "$line" | grep -oE 'WANDB_RUN_NAME=[^ ]+' | cut -d= -f2)"
        key="$rf:${run_name:-run$run_no}"
        if printf '%s\n' "$journal" | grep -Fxq "$key"; then
            log "SKIP $key (journaled)"
            continue
        fi

        run_timeout="$RUN_TIMEOUT_SECONDS_DEFAULT"
        case "$line" in *RUN_TIMEOUT_SECONDS=*)
            t="$(printf '%s\n' "$line" | sed -n 's/.*RUN_TIMEOUT_SECONDS=\([0-9]\{1,\}\).*/\1/p')"
            run_timeout="${t:-$run_timeout}" ;;
        esac

        wait_quiescent "$gen"
        gen=$(( gen + 1 ))
        tag="vmrun${gen}-$(date +%s)"
        # Translate runs-file keys to the env config.py actually reads —
        # exactly deploy_tarball's mapping. Publishing TOTAL_TRAIN_STEPS
        # verbatim once launched a default-config run (per-device 32) that
        # OOMed with 86G of temporaries; config.py only reads NANOGPT_*.
        spec="$(for kv in $line; do
            k="${kv%%=*}"
            case "$k" in
                TOTAL_TRAIN_STEPS|PER_DEVICE_BATCH_SIZE|SAVE_CKPT_DIR)
                    printf 'export NANOGPT_%s\n' "$kv" ;;
                RUN_TIMEOUT_SECONDS|DATA_SHARDS) ;;  # coordinator/staging-only
                *) printf 'export %s\n' "$kv" ;;
            esac
        done
        printf 'export RUN_TAG=%s\n' "$tag")"
        printf '%s\n' "$spec" | gcloud storage cp - "$PREFIX/spec-$gen.env"
        log "published spec-$gen ($key, timeout ${run_timeout}s)"

        deadline=$(( $(date +%s) + run_timeout ))
        while true; do
            sleep 30
            heartbeat
            status="$(run_status "$tag")"
            if echo "$status" | grep -q 'DIVERGED at step'; then
                log "$key DIVERGED — verdict recorded, continuing"
                notify "vm-coordinator: $key DIVERGED — $(echo "$status" | grep 'DIVERGED at step' | tail -1)"
                journal_add "$key"
                break
            fi
            if echo "$status" | grep -q 'exited with status'; then
                best="$(run_best_loss "$tag")"
                # The EXIT STATUS is authoritative, not the max-steps marker.
                #
                # A run that ends by exhausting its data exits 0 and never prints
                # "Reached maximum training steps". Requiring that marker recorded
                # the SUCCESSFUL 844-step SFT epoch (val 1.4365) as an ABORT, and
                # in a multi-stage program that stops every later stage after one
                # that actually worked (2026-07-26). This is not an edge case: for
                # SFT, "one epoch" is data-bound by definition.
                #
                # Which way we got there is logged so a run that exits 0 having
                # done nothing is still visible rather than silently "OK".
                if ! echo "$status" | grep -qE 'exited with status [^0]'; then
                    if echo "$status" | grep -q 'Reached maximum training steps'; then
                        why="reached max steps"
                    else
                        why="data-bound, exit 0 without max-steps marker"
                    fi
                    log "$key OK [$why] — ${best:-no val loss}"
                    notify "vm-coordinator: $key OK — ${best:-no val loss recorded}"
                    journal_add "$key"
                    break
                fi
                log "ABORT: $key failed:"; printf '%s\n' "$status" | tee -a "$COORD_LOG"
                notify "vm-coordinator ABORT: $key failed — program stopped. $(echo "$status" | tail -1)"
                heartbeat
                exit 1
            fi
            if [ "$(date +%s)" -ge "$deadline" ]; then
                log "ABORT: $key exceeded ${run_timeout}s"
                notify "vm-coordinator ABORT: $key timed out (${run_timeout}s) — program stopped"
                exit 1
            fi
        done
    done 3< "$REPO_DIR/$rf"
    log "stage $rf complete"
    notify "vm-coordinator: stage $(basename "$rf") complete"
done

log "PROGRAM COMPLETE — all stages finished"
echo "done:$PROGRAM" | gcloud storage cp - "$CONTROL/ACTIVE_PROGRAM"
heartbeat
notify "vm-coordinator: PROGRAM COMPLETE ($PROGRAM). TPU idle; results on W&B."
