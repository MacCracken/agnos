#!/bin/sh
# Install AGNOS git hooks. Git doesn't version-control .git/hooks/, so this
# script is the committed source of truth — run it once per fresh checkout
# (and after it changes). Idempotent.
#
#   pre-push → scripts/check/fmt-check.sh   (local CI-parity format gate)

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/.git/hooks"
[ -d "$HOOKS" ] || { echo "install-hooks: $HOOKS missing (not a git checkout?)" >&2; exit 1; }

if ! cat > "$HOOKS/pre-push" <<'EOF'
#!/bin/sh
# AGNOS pre-push: local CI-parity format gate (mirrors ci.yml's Format job).
# Managed by scripts/burn/install-hooks.sh — edits here are overwritten on reinstall.
exec "$(git rev-parse --show-toplevel)/scripts/check/fmt-check.sh"
EOF
then
    echo "install-hooks: could not write $HOOKS/pre-push" >&2; exit 1
fi
chmod +x "$HOOKS/pre-push" || { echo "install-hooks: could not chmod +x $HOOKS/pre-push" >&2; exit 1; }
# ⛔ VERIFY, DO NOT ANNOUNCE. This was `cat > hook; chmod +x hook; echo "installed:"` with no `set -e`
# and no check on either command — so a hook that could not be written (read-only .git from a
# worktree/submodule checkout, a full disk, an existing pre-push owned by another user) still printed
# "installed: .git/hooks/pre-push → scripts/check/fmt-check.sh". The whole point of this script is that
# the local format gate RUNS before a push; a claim that it was installed when it was not is worse than
# no claim, because it is the reason nobody checks. git will not run a hook that is not executable, so
# both facts are asserted.
if [ ! -s "$HOOKS/pre-push" ] || [ ! -x "$HOOKS/pre-push" ]; then
    echo "install-hooks: $HOOKS/pre-push is empty or not executable after install — git would skip it." >&2
    exit 1
fi
echo "installed: .git/hooks/pre-push → scripts/check/fmt-check.sh ($(wc -c < "$HOOKS/pre-push" | tr -d ' ') bytes, executable)"
