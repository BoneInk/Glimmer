#!/bin/bash
# Shared local-build signing policy. This file only reads code-signing identity
# metadata; it never creates certificates, changes ACLs, or reads app secrets.

gw_codesigning_records() {
  security find-identity -v -p codesigning 2>/dev/null || true
}

gw_identity_is_available() {
  local requested="$1"
  gw_codesigning_records | grep -qF -- "$requested"
}

gw_resolve_signing_identity() {
  local requested="${GW_SIGNING_IDENTITY:-}"
  if [ -n "$requested" ]; then
    if [ "$requested" = "-" ]; then
      printf '%s' '-'
      return 0
    fi
    if ! gw_identity_is_available "$requested"; then
      echo "GW_SIGNING_IDENTITY does not match a valid local code-signing identity." >&2
      return 1
    fi
    printf '%s' "$requested"
    return 0
  fi

  local hashes count
  hashes="$(gw_codesigning_records | sed -n 's/^[[:space:]]*[0-9][0-9]*) \([[:xdigit:]]\{40\}\) "Apple Development:.*$/\1/p')"
  count="$(printf '%s\n' "$hashes" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$count" in
    0) printf '%s' '-' ;;
    1) printf '%s' "$hashes" ;;
    *)
      echo "Multiple Apple Development identities are available; set GW_SIGNING_IDENTITY explicitly." >&2
      return 1
      ;;
  esac
}

gw_signing_description() {
  if [ "$1" = "-" ]; then
    printf '%s' 'ad-hoc fallback'
  else
    printf '%s' 'stable local Apple identity'
  fi
}
