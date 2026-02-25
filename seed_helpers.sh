#!/bin/sh
# =============================================================================
# seed_helpers.sh — Shared version-aware seeding functions
#
# Source this from any init container to get version-aware directory seeding.
# Works in any image (emqx, node, python, alpine) — pure POSIX sh.
#
# Usage in an init container:
#   . /humming_dir/bootstrap/seed_helpers.sh
#   version_aware_seed /source/dir /target/dir "my-app-1.2.3"
# =============================================================================

_seed_log() {
  echo "[seed-helper] $*"
}

_seed_now_ts() {
  date +%s 2>/dev/null || echo 0
}

_seed_ensure_dir() {
  mkdir -p "$1"
}

_seed_is_dir_empty() {
  dir="$1"
  [ -d "$dir" ] || return 0
  if ls -A "$dir" >/dev/null 2>&1; then
    [ -z "$(ls -A "$dir" 2>/dev/null || true)" ]
  else
    return 1
  fi
}

# Generate a checksum manifest for all files in a directory.
# Output: "<md5>  <relative_path>" per line, sorted.
_seed_generate_manifest() {
  src_dir="$1"
  (cd "$src_dir" && find . -type f \
    ! -name '.seed_version' \
    ! -name '.seed_checksums' \
    ! -name '*.pyc' \
    -exec md5sum {} + 2>/dev/null | sort) || true
}

# Fingerprint a directory by hashing file listing + sizes.
# Useful when you don't know the app version but want to detect changes.
fingerprint_dir() {
  dir="$1"
  if [ -d "$dir" ]; then
    find "$dir" -type f -exec stat -c '%n %s' {} + 2>/dev/null \
      | sort | md5sum 2>/dev/null | cut -d' ' -f1 || echo "unknown"
  else
    echo "missing"
  fi
}

# =============================================================================
# version_aware_seed <source_dir> <target_dir> <version_string>
#
# Copies source_dir contents into target_dir with smart refresh logic:
#   - First run: copies everything, records checksums + version
#   - Same version: skips entirely
#   - New version: refreshes defaults, preserves user-modified files
#
# The version_string should change whenever the source image changes.
# You can use an explicit version or fingerprint_dir().
# =============================================================================
version_aware_seed() {
  src="$1"
  dst="$2"
  current_version="$3"

  if [ ! -d "$src" ]; then
    _seed_log "WARNING: Source directory $src does not exist — skipping."
    return 1
  fi

  _seed_ensure_dir "$dst"

  stamp_file="$dst/.seed_version"
  manifest_file="$dst/.seed_checksums"

  stored_version=""
  if [ -f "$stamp_file" ]; then
    stored_version="$(cat "$stamp_file" 2>/dev/null || true)"
  fi

  # --- CASE 1: First run (empty dir or no stamp) ---
  if _seed_is_dir_empty "$dst" || [ -z "$stored_version" ]; then
    _seed_log "First-time seed: $src → $dst (version: $current_version)"
    cp -a "$src/." "$dst/" 2>/dev/null || true
    _seed_generate_manifest "$dst" > "$manifest_file"
    printf %s "$current_version" > "$stamp_file"
    return 0
  fi

  # --- CASE 2: Same version → skip ---
  if [ "$stored_version" = "$current_version" ]; then
    _seed_log "Version unchanged ($current_version) for $dst — skipping."
    return 0
  fi

  # --- CASE 3: Version changed → refresh preserving user edits ---
  _seed_log "Version change: $stored_version → $current_version for $dst"
  _seed_log "Refreshing defaults while preserving user edits..."

  user_mod_list="/tmp/seed_user_mods_$$"
  : > "$user_mod_list"

  if [ -f "$manifest_file" ]; then
    current_manifest="$(_seed_generate_manifest "$dst")"

    # Files whose checksum differs from original seed = user edited
    printf '%s\n' "$current_manifest" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      curr_sum="$(printf '%s' "$line" | awk '{print $1}')"
      curr_path="$(printf '%s' "$line" | sed 's/^[^ ]* *//')"
      orig_line="$(grep -F " $curr_path" "$manifest_file" 2>/dev/null | head -1 || true)"
      orig_sum="$(printf '%s' "$orig_line" | awk '{print $1}')"
      if [ -n "$orig_sum" ] && [ "$curr_sum" != "$orig_sum" ]; then
        printf '%s\n' "$curr_path" >> "$user_mod_list"
      fi
    done

    # Files not in original manifest = user added
    printf '%s\n' "$current_manifest" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      curr_path="$(printf '%s' "$line" | sed 's/^[^ ]* *//')"
      if ! grep -qF " $curr_path" "$manifest_file" 2>/dev/null; then
        printf '%s\n' "$curr_path" >> "$user_mod_list"
      fi
    done
  fi

  # Back up user-modified files
  backup_dir="/tmp/seed_backup_$$"
  mkdir -p "$backup_dir"
  if [ -s "$user_mod_list" ]; then
    while IFS= read -r relpath; do
      [ -z "$relpath" ] && continue
      full="$dst/$relpath"
      if [ -f "$full" ]; then
        bdir="$backup_dir/$(dirname "$relpath")"
        mkdir -p "$bdir"
        cp -a "$full" "$bdir/" 2>/dev/null || true
        _seed_log "  Preserved user edit: $relpath"
      fi
    done < "$user_mod_list"
  fi

  # Full safety backup
  ts="$(_seed_now_ts)"
  archive_dir="${dst}.pre_upgrade_${ts}"
  _seed_log "  Full backup → $archive_dir"
  cp -a "$dst" "$archive_dir" 2>/dev/null || true

  # Re-seed from image
  cp -a "$src/." "$dst/" 2>/dev/null || true

  # Restore user edits on top
  if [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
    cp -a "$backup_dir/." "$dst/" 2>/dev/null || true
    _seed_log "  Restored user-modified files."
  fi

  _seed_generate_manifest "$dst" > "$manifest_file"
  printf %s "$current_version" > "$stamp_file"

  rm -rf "$backup_dir" "$user_mod_list" 2>/dev/null || true
  _seed_log "Refresh complete for $dst"
  return 0
}