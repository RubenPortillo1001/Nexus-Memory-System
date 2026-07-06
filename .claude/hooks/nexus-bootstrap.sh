#!/usr/bin/env bash
# Nexus Memory System — SessionStart bootstrap for Claude Code (web/ephemeral sessions)
#
# Idempotent, best-effort provisioning: if the `nexus` binary is missing, build and
# install it from this repo, initialize the local DB, and register Claude Code hooks.
# Guarded so a warm container (binary already present) does NOT rebuild — this keeps
# session startup fast. All failures are non-fatal: we never block Claude from starting.
#
# NOTE: In the ephemeral web environment the DB at ~/.nexus / ~/.local/share does NOT
# persist between containers, so captured memory here is session-local. The durable
# deployment is on your own machine — see docs/guide/claude-integration.md.

set -u

log() { printf '[nexus-bootstrap] %s\n' "$*" >&2; }

# Resolve repo root from this script's location (.claude/hooks/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Ensure common install dirs are on PATH for this process.
export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"

find_nexus() {
    command -v nexus 2>/dev/null && return 0
    for c in "${HOME}/.cargo/bin/nexus" "${HOME}/.local/bin/nexus" "${REPO_ROOT}/target/release/nexus"; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

NEXUS_BIN="$(find_nexus || true)"

if [ -z "${NEXUS_BIN}" ]; then
    if ! command -v cargo >/dev/null 2>&1; then
        log "cargo not found and no nexus binary present; skipping provisioning."
        exit 0
    fi
    log "nexus binary not found — building from repo (this can take several minutes on a cold container)."
    if cargo build --release -p nexus-memory --manifest-path "${REPO_ROOT}/Cargo.toml" >&2; then
        if [ -x "${REPO_ROOT}/scripts/install.sh" ]; then
            bash "${REPO_ROOT}/scripts/install.sh" --binary "${REPO_ROOT}/target/release/nexus" --skip-profile >&2 \
                || log "install.sh reported an issue (continuing)."
        fi
        NEXUS_BIN="$(find_nexus || true)"
    else
        log "cargo build failed; skipping provisioning."
        exit 0
    fi
fi

if [ -z "${NEXUS_BIN}" ]; then
    log "nexus still not available after build; skipping."
    exit 0
fi

log "using nexus at: ${NEXUS_BIN}"

# Initialize the DB if it has not been created yet (idempotent).
"${NEXUS_BIN}" init >&2 2>/dev/null || "${NEXUS_BIN}" init >&2 || log "nexus init reported an issue (continuing)."

# Register Claude Code native hooks (idempotent: installer purges duplicates).
"${NEXUS_BIN}" hooks install --agent claude-code >&2 || log "hooks install reported an issue (continuing)."

log "bootstrap complete."
exit 0
