#!/usr/bin/env bash
set -euo pipefail

# Enable tool surfaces intentionally by editing LibreChat YAML config:
# - optionally re-enable MCP servers UI (interface.mcpServers.use/create/share/public)
# - set explicit allowlists for Actions and MCP remote transports
#
# This script is deliberately conservative:
# - it does NOT enable anything unless you ask it to
# - it requires explicit domains to be provided (or it leaves allowlists empty)
# - it makes a timestamped backup before writing

usage() {
  cat <<'EOF'
Usage:
  enable_tools.sh [options]

Options:
  --config PATH            Path to librechat.yaml (default: /var/lib/librechat/app/librechat.yaml)

  --enable-mcp-ui          Enable MCP server UI (use/create). Share/public remain false unless set.
  --mcp-share              Allow sharing MCP servers in UI
  --mcp-public             Allow public MCP servers in UI

  --actions-domain DOMAIN  Add DOMAIN to actions.allowedDomains (repeatable)
  --mcp-domain DOMAIN      Add DOMAIN to mcpSettings.allowedDomains (repeatable)

  --dry-run                Print what would happen; do not write, do not restart
  --no-restart             Do not restart services after writing
  -y, --yes                Do not prompt for confirmation

Examples:
  # Enable MCP UI, allow MCP servers hosted on your LAN domain, keep Actions disabled
  sudo enable_tools.sh --enable-mcp-ui --mcp-domain ai2 --mcp-domain ai2.local

  # Enable Actions for a single internal host
  sudo enable_tools.sh --actions-domain ai2
EOF
}

CONFIG_PATH="/var/lib/librechat/app/librechat.yaml"
DO_RESTART=true
DRY_RUN=false
ASSUME_YES=false

ENABLE_MCP_UI=false
MCP_SHARE=false
MCP_PUBLIC=false

ACTIONS_DOMAINS=()
MCP_DOMAINS=()

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "ERROR: this script is intended for macOS (Darwin)." >&2
  exit 2
fi

# Re-exec early via sudo before we parse/shift args.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --enable-mcp-ui)
      ENABLE_MCP_UI=true
      shift
      ;;
    --mcp-share)
      MCP_SHARE=true
      shift
      ;;
    --mcp-public)
      MCP_PUBLIC=true
      shift
      ;;
    --actions-domain)
      ACTIONS_DOMAINS+=("$2")
      shift 2
      ;;
    --mcp-domain)
      MCP_DOMAINS+=("$2")
      shift 2
      ;;
    --no-restart)
      DO_RESTART=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      DO_RESTART=false
      shift
      ;;
    -y|--yes)
      ASSUME_YES=true
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

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: config not found: $CONFIG_PATH" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to safely edit YAML blocks without extra dependencies." >&2
  exit 2
fi

if [[ "$ASSUME_YES" != "true" ]]; then
  echo "About to modify: $CONFIG_PATH" >&2
  echo "- MCP UI enable:   $ENABLE_MCP_UI (share=$MCP_SHARE public=$MCP_PUBLIC)" >&2
  echo "- Actions domains: ${#ACTIONS_DOMAINS[@]}" >&2
  echo "- MCP domains:     ${#MCP_DOMAINS[@]}" >&2
  echo "A timestamped backup will be created." >&2
  printf "Continue? [y/N] " >&2
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup="${CONFIG_PATH}.bak.${stamp}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: would back up $CONFIG_PATH -> $backup" >&2
else
  cp -p "$CONFIG_PATH" "$backup"
  echo "Backed up: $backup" >&2
fi

# Pass arrays via NUL-separated strings to avoid shell escaping issues.
actions_blob=""
if [[ ${#ACTIONS_DOMAINS[@]} -gt 0 ]]; then
  actions_blob="$(printf '%s\0' "${ACTIONS_DOMAINS[@]}")"
fi

mcp_blob=""
if [[ ${#MCP_DOMAINS[@]} -gt 0 ]]; then
  mcp_blob="$(printf '%s\0' "${MCP_DOMAINS[@]}")"
fi

python3 - "$CONFIG_PATH" "$DRY_RUN" "$ENABLE_MCP_UI" "$MCP_SHARE" "$MCP_PUBLIC" "$actions_blob" "$mcp_blob" <<'PY'
import os
import re
import sys
import tempfile

def parse_nul_blob(blob: str):
    if not blob:
        return []
    parts = blob.split('\0')
    return [p for p in parts if p]

path = sys.argv[1]
dry_run = (sys.argv[2].lower() == 'true')
enable_mcp_ui = (sys.argv[3].lower() == 'true')
mcp_share = (sys.argv[4].lower() == 'true')
mcp_public = (sys.argv[5].lower() == 'true')
actions_domains = parse_nul_blob(sys.argv[6])
mcp_domains = parse_nul_blob(sys.argv[7])

with open(path, 'r', encoding='utf-8') as f:
    original = f.read()

lines = original.splitlines(True)

TOP_KEY_RE = re.compile(r'^[A-Za-z0-9_\-]+:\s*(#.*)?$')

def find_top_level_block(name: str):
    key_re = re.compile(rf'^{re.escape(name)}:\s*(#.*)?$')
    start = None
    for i, line in enumerate(lines):
        if key_re.match(line.rstrip('\n')) and not line.startswith(' '):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        s = lines[j].rstrip('\n')
        if not s.strip():
            continue
        if not s.startswith(' ') and TOP_KEY_RE.match(s):
            end = j
            break
    return (start, end)


def replace_top_level_block(name: str, block_text: str):
    rng = find_top_level_block(name)
    block_lines = [l if l.endswith('\n') else (l + '\n') for l in block_text.splitlines(True)]
    if rng is None:
        ep = find_top_level_block('endpoints')
        insert_at = ep[0] if ep else len(lines)
        if insert_at > 0 and lines[insert_at - 1].strip():
            block_lines = ['\n'] + block_lines
        if insert_at < len(lines) and lines[insert_at].strip():
            block_lines = block_lines + ['\n']
        lines[insert_at:insert_at] = block_lines
        return
    start, end = rng
    lines[start:end] = block_lines


def set_interface_mcp_servers(use: bool, create: bool, share: bool, public: bool):
    rng = find_top_level_block('interface')
    desired = (
        '  mcpServers:\n'
        f'    use: {str(use).lower()}\n'
        f'    create: {str(create).lower()}\n'
        f'    share: {str(share).lower()}\n'
        f'    public: {str(public).lower()}\n'
    )
    if rng is None:
        # Create interface block near top.
        ver = find_top_level_block('version')
        insert_at = ver[1] if ver else 0
        block = 'interface:\n' + desired
        if insert_at > 0 and lines[insert_at - 1].strip():
            block = '\n' + block
        lines[insert_at:insert_at] = [l if l.endswith('\n') else (l + '\n') for l in block.splitlines(True)]
        return

    start, end = rng
    # Remove existing interface.mcpServers sub-block if present
    i = start + 1
    while i < end:
        if re.match(r'^\s{2}mcpServers:\s*(#.*)?$', lines[i].rstrip('\n')):
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

    insert_at = end
    while insert_at > start + 1 and not lines[insert_at - 1].strip():
        insert_at -= 1

    block_lines = [l if l.endswith('\n') else (l + '\n') for l in desired.splitlines(True)]
    if insert_at > start + 1 and lines[insert_at - 1].strip():
        block_lines = ['\n'] + block_lines
    lines[insert_at:insert_at] = block_lines


def yaml_list(items):
    # Quote only if needed; keep it simple.
    out = []
    for item in items:
        item = str(item)
        if re.search(r'[^A-Za-z0-9.\-_:]', item):
            out.append("'" + item.replace("'", "''") + "'")
        else:
            out.append(item)
    return '[' + ', '.join(out) + ']'


changed = False

if enable_mcp_ui:
    set_interface_mcp_servers(True, True, mcp_share, mcp_public)
    changed = True

if actions_domains:
    replace_top_level_block('actions', f"actions:\n  allowedDomains: {yaml_list(actions_domains)}\n")
    changed = True

if mcp_domains:
    replace_top_level_block('mcpSettings', f"mcpSettings:\n  allowedDomains: {yaml_list(mcp_domains)}\n")
    changed = True

if not changed:
    print('No changes requested (nothing to enable).')
    sys.exit(0)

new_text = ''.join(lines)

if new_text == original:
    print('No changes needed (already in desired state).')
    sys.exit(0)

if dry_run:
    print('DRY RUN: changes would be applied. Diff preview not shown (run without --dry-run).')
    sys.exit(0)

fd, tmp = tempfile.mkstemp(prefix='librechat.yaml.', suffix='.tmp', dir=os.path.dirname(path))
os.close(fd)
with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
    f.write(new_text)
os.replace(tmp, path)
print('Applied changes.')
PY

if [[ "$DO_RESTART" == "true" && "$DRY_RUN" != "true" ]]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  "$here/restart.sh" >/dev/null
  echo "Restarted LibreChat + MongoDB via restart.sh" >&2
fi

echo "Done." >&2
