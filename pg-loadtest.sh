#!/usr/bin/env bash
# pg-loadtest.sh — PostgreSQL load test using pgbench.
# Enhancements:
#  - Optional --viewer <URL> to scrape PGHOST/PGPORT/USER/DB defaults from the Viewer UI.
#  - Auto-set PGPASSWORD from $PGPASSWORD or ~/.pgpass (no prompting).
#  - Interactively ask for PGUSER and PGDATABASE (with defaults when found).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pg-loadtest.sh [pgbench options] [--viewer URL] [--dsn DSN]

Connection discovery order:
  1) --dsn "postgres://..."
  2) PG* envs (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)
  3) --viewer URL  → scrape Host/Port + (default User/Database)
     - Prompts for PGUSER and PGDATABASE (defaults shown if scraped)
     - PGPASSWORD is auto-set from $PGPASSWORD or ~/.pgpass

Common pgbench flags (you can pass any):
  -c/--clients N   -j/--threads N
  -T/--duration S  -t/--transactions N
  -S (select-only) -f FILE (custom SQL)  -M prepared|simple

Examples:
  # Discover from viewer, prompt for user/db, 60s run
  ./scripts/pg-loadtest.sh --viewer "http://<route>/" -T 60 -c 40 -j 4

  # Using DSN (skips prompts)
  ./scripts/pg-loadtest.sh --dsn "postgres://u:pw@host:8888/db" -T 30 -c 50
EOF
}

VIEWER_URL=""
DSN=""
PGOPTS=()

# Extract our two meta flags while letting all other args pass to pgbench
while [[ $# -gt 0 ]]; do
  case "$1" in
    --viewer) VIEWER_URL="$2"; shift 2;;
    --dsn) DSN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) PGOPTS+=("$1"); shift;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd pgbench; then
  echo "ERROR: pgbench not installed." >&2
  echo "  - macOS:   brew install libpq && brew link --force libpq" >&2
  echo "  - Debian:  apt-get update && apt-get install -y postgresql-client" >&2
  echo "  - Docker:  docker run --rm -it postgres:16 pgbench --version" >&2
  exit 127
fi

# If DSN provided, just run
if [[ -n "$DSN" ]]; then
  exec pgbench -d "$DSN" "${PGOPTS[@]}"
fi

# Attempt discovery from viewer if PGHOST/PGPORT unset
if [[ -n "$VIEWER_URL" ]]; then
  if ! need_cmd curl; then
    echo "ERROR: curl is required for --viewer scraping" >&2
    exit 2
  fi
  html="$(curl -fsSL "$VIEWER_URL")" || { echo "ERROR: unable to fetch viewer URL"; exit 2; }

  # Crude extraction from the HTML UI we control
  # Host
  if [[ -z "${PGHOST:-}" ]]; then
    PGHOST="$(printf '%s' "$html" | sed -nE 's@.*<dt>Host</dt><dd><code>([^<]+)</code></dd>.*@\1@p' | head -n1)"
  fi
  # Port
  if [[ -z "${PGPORT:-}" ]]; then
    PGPORT="$(printf '%s' "$html" | sed -nE 's@.*<dt>Port</dt><dd><code>([0-9]+)</code></dd>.*@\1@p' | head -n1)"
  fi
  # Defaults for prompts (do not export yet)
  _DEF_USER="$(printf '%s' "$html" | sed -nE 's@.*<dt>User</dt><dd><code>([^<]+)</code></dd>.*@\1@p' | head -n1)"
  _DEF_DB="$(printf '%s' "$html" | sed -nE 's@.*<dt>Database</dt><dd><code>([^<]+)</code></dd>.*@\1@p' | head -n1)"
fi

# Fallback defaults
PGPORT="${PGPORT:-8888}"
# Ask for user/database with defaults if discovered
read -r -p "PGUSER [${_DEF_USER:-}]: " PGUSER_IN || true
PGUSER="${PGUSER_IN:-${PGUSER:-${_DEF_USER:-}}}"
if [[ -z "$PGUSER" ]]; then echo "PGUSER is required."; exit 2; fi

read -r -p "PGDATABASE [${_DEF_DB:-}]: " PGDATABASE_IN || true
PGDATABASE="${PGDATABASE_IN:-${PGDATABASE:-${_DEF_DB:-}}}"
if [[ -z "$PGDATABASE" ]]; then echo "PGDATABASE is required."; exit 2; fi

# Auto-set PGPASSWORD:
# 1) use existing env if set
# 2) else try ~/.pgpass with exact and wildcard matches
if [[ -z "${PGPASSWORD:-}" ]]; then
  PGPASSFILE="${PGPASSFILE:-$HOME/.pgpass}"
  if [[ -f "$PGPASSFILE" ]]; then
    esc() { printf '%s' "$1" | sed 's/[][\.^$*+?|(){}]/\\&/g; s/:/\\:/g'; }
    H="$(esc "${PGHOST:-*}")"
    P="$(esc "${PGPORT:-*}")"
    D="$(esc "${PGDATABASE}")"
    U="$(esc "${PGUSER}")"
    # Try exact, then wildcard combos
    pw="$(awk -F: -v h="$H" -v p="$P" -v d="$D" -v u="$U" '
      $1==h && $2==p && $3==d && $4==u {print $5; found=1; exit}
      END{if(!found) print ""}
    ' "$PGPASSFILE")"
    if [[ -z "$pw" ]]; then
      # try wildcard lines (host *, port *, db *, user *), choose the first match
      pw="$(awk -F: -v h="${PGHOST:-*}" -v p="${PGPORT:-*}" -v d="${PGDATABASE}" -v u="${PGUSER}" '
        function matchField(val, pat) { return (pat=="*" || val==pat) }
        matchField($1,h) && matchField($2,p) && matchField($3,d) && matchField($4,u) { print $5; exit }
      ' "$PGPASSFILE")"
    fi
    if [[ -n "$pw" ]]; then
      export PGPASSWORD="$pw"
      echo "(Using password from $PGPASSFILE)"
    fi
  fi
fi

# Final sanity
: "${PGHOST:?PGHOST not set}"
: "${PGPORT:?PGPORT not set}"
: "${PGUSER:?PGUSER not set}"
: "${PGDATABASE:?PGDATABASE not set}"

echo "==> Target: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
if [[ -n "${PGPASSWORD:-}" ]]; then echo "=> Password: from env/pgpass"; else echo "=> Password: (none)"; fi

# Build pgbench args (pass-through from CLI)
ARGS=(-h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
exec pgbench "${ARGS[@]}" "${PGOPTS[@]}"
