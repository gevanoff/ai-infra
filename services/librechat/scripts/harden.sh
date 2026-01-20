#!/usr/bin/env bash
set -euo pipefail

# Apply "safe by default" hardening to LibreChat YAML config:
# - disables Actions (actions.allowedDomains: [])
# - disables MCP remote transports (mcpSettings.allowedDomains: [])
# - hides/disables MCP server UI (interface.mcpServers.*: false)
#
# This script:
# - makes a timestamped backup of the YAML
# - performs minimal in-place edits (preserves endpoints and other config)

usage() {
  cat <<'EOF'
Usage:
  harden.sh [--config /path/to/librechat.yaml] [--no-restart] [--dry-run]

Defaults:
  --config     /var/lib/librechat/app/librechat.yaml

Notes:
  - Run on macOS host (ai2).
  - Will re-exec via sudo if not root (because the config is typically mode 640).
EOF
}

CONFIG_PATH="/var/lib/librechat/app/librechat.yaml"
DO_RESTART=true
DRY_RUN=false

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: this hardening script is intended for macOS (Darwin)." >&2
  exit 2
fi

# Re-exec early via sudo before we parse/shift args.
# If we wait until after parsing, we will have shifted $@ to empty and lose flags like --dry-run.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --no-restart)
      DO_RESTART=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  # Dry run must be non-invasive.
  DO_RESTART=false
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: config not found: $CONFIG_PATH" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to safely edit YAML blocks without extra dependencies." >&2
  exit 2
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup="${CONFIG_PATH}.bak.${stamp}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: would back up $CONFIG_PATH -> $backup" >&2
else
  cp -p "$CONFIG_PATH" "$backup"
  echo "Backed up: $backup" >&2
fi

python3 - "$CONFIG_PATH" "$DRY_RUN" <<'PY'
import io
import os
import re
import sys

path = sys.argv[1]
dry_run = (sys.argv[2].lower() == 'true')

with open(path, 'r', encoding='utf-8') as f:
    original = f.read()

lines = original.splitlines(True)  # keepends

def find_top_level_block(name: str):
    # Returns (start_index, end_index) for block with key `name:` at column 0.
    key_re = re.compile(rf'^{re.escape(name)}:\s*(#.*)?$')
    starts = None
    for i, line in enumerate(lines):
        if key_re.match(line.rstrip('\n')) and not line.startswith(' '):
            starts = i
            break
    if starts is None:
        return None
    # block ends right before next top-level key (non-empty, no leading spaces, ends with ':')
    end = len(lines)
    for j in range(starts + 1, len(lines)):
        s = lines[j].rstrip('\n')
        if not s.strip():
            continue
        if not s.startswith(' ') and re.match(r'^[A-Za-z0-9_\-]+:\s*(#.*)?$', s):
            end = j
            break
    return (starts, end)

def replace_top_level_block(name: str, block_text: str):
    rng = find_top_level_block(name)
    block_lines = [l if l.endswith('\n') else (l + '\n') for l in block_text.splitlines(True)]
    if block_lines and not block_lines[-1].endswith('\n'):
        block_lines[-1] += '\n'
    if rng is None:
        # insert before endpoints if present, else append
        ep = find_top_level_block('endpoints')
        insert_at = ep[0] if ep else len(lines)
        # Ensure there's a blank line before insertion unless at top or already blank
        if insert_at > 0 and lines[insert_at-1].strip():
            block_lines = ['\n'] + block_lines
        # Ensure there's a blank line after insertion if next is not blank
        if insert_at < len(lines) and lines[insert_at].strip():
            block_lines = block_lines + ['\n']
        lines[insert_at:insert_at] = block_lines
        return
    start, end = rng
    lines[start:end] = block_lines


def find_interface_block():
    return find_top_level_block('interface')

def ensure_interface_mcpservers_disabled():
    rng = find_interface_block()
    desired = (
        "  mcpServers:\n"
        "    use: false\n"
        "    create: false\n"
        "    share: false\n"
        "    public: false\n"
    )
    if rng is None:
        # Create minimal interface block at top.
        block = "interface:\n" + desired
        # Insert near top (after version if present)
        ver = find_top_level_block('version')
        insert_at = (ver[1] if ver else 0)
        if insert_at > 0 and lines[insert_at-1].strip():
            block = "\n" + block
        lines[insert_at:insert_at] = [l if l.endswith('\n') else (l + '\n') for l in block.splitlines(True)]
        return

    start, end = rng
    # Remove any existing '  mcpServers:' sub-block inside interface
    i = start + 1
    while i < end:
        line = lines[i]
        if re.match(r'^\s{2}mcpServers:\s*(#.*)?$', line.rstrip('\n')):
            # remove this line and any following lines with indentation >= 4
            j = i + 1
            while j < end:
                nxt = lines[j]
                if nxt.strip() == '':
                    j += 1
                    continue
                if re.match(r'^\s{4,}', nxt):
                    j += 1
                    continue
                break
            del lines[i:j]
            end -= (j - i)
            continue
        i += 1

    # Insert desired sub-block at end of interface block (before trailing blank lines within it)
    insert_at = end
    # Back up over trailing blank lines
    while insert_at > start + 1 and not lines[insert_at-1].strip():
        insert_at -= 1
    block_lines = [l if l.endswith('\n') else (l + '\n') for l in desired.splitlines(True)]
    # Ensure a blank line before insertion if needed and not immediately after 'interface:'
    if insert_at > start + 1 and lines[insert_at-1].strip():
        block_lines = ['\n'] + block_lines
    lines[insert_at:insert_at] = block_lines


# Apply changes
ensure_interface_mcpservers_disabled()
replace_top_level_block('actions', 'actions:\n  allowedDomains: []\n')
replace_top_level_block('mcpSettings', 'mcpSettings:\n  allowedDomains: []\n')

new_text = ''.join(lines)

if new_text == original:
    print('No changes needed (already hardened).')
    sys.exit(0)

if dry_run:
    print('DRY RUN: changes would be applied. Diff preview not shown (run without --dry-run).')
    sys.exit(0)

# Preserve existing file ownership/permissions across atomic-ish replace.
st = os.stat(path)
orig_mode = st.st_mode & 0o777
orig_uid = st.st_uid
orig_gid = st.st_gid

# Atomic-ish write: write temp then replace
import tempfile
fd, tmp = tempfile.mkstemp(prefix='librechat.yaml.', suffix='.tmp', dir=os.path.dirname(path))
os.close(fd)
with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
    f.write(new_text)
os.replace(tmp, path)

# Re-apply original perms in case the temp file was created with different defaults.
try:
  os.chown(path, orig_uid, orig_gid)
except PermissionError:
  pass
os.chmod(path, orig_mode)
print('Applied hardening changes.')
PY

if [[ "$DO_RESTART" == "true" && "$DRY_RUN" != "true" ]]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  "$here/restart.sh" >/dev/null
  echo "Restarted LibreChat + MongoDB via restart.sh" >&2
fi

echo "Done." >&2
