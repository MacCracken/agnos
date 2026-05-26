#!/bin/sh
# Install AGNOS git hooks. Git doesn't version-control .git/hooks/, so this
# script is the committed source of truth — run it once per fresh checkout
# (and after it changes). Idempotent.
#
#   pre-push → scripts/fmt-check.sh   (local CI-parity format gate)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/.git/hooks"
[ -d "$HOOKS" ] || { echo "install-hooks: $HOOKS missing (not a git checkout?)" >&2; exit 1; }

cat > "$HOOKS/pre-push" <<'EOF'
#!/bin/sh
# AGNOS pre-push: local CI-parity format gate (mirrors ci.yml's Format job).
# Managed by scripts/install-hooks.sh — edits here are overwritten on reinstall.
exec "$(git rev-parse --show-toplevel)/scripts/fmt-check.sh"
EOF
chmod +x "$HOOKS/pre-push"
echo "installed: .git/hooks/pre-push → scripts/fmt-check.sh"
