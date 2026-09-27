#!/usr/bin/env bash
# Run check-jsonschema with the given arguments: the installed binary, else a
# throwaway copy through `uvx` or `pipx run` (GitHub's runners ship pipx).
# Exit 127 when none is available, so callers can tell "no validator" from
# "invalid".
if command -v check-jsonschema >/dev/null 2>&1; then exec check-jsonschema "$@"; fi
if command -v uvx >/dev/null 2>&1; then exec uvx --quiet check-jsonschema "$@"; fi
if command -v pipx >/dev/null 2>&1; then exec pipx run --quiet check-jsonschema "$@"; fi
echo "❌ check-jsonschema not found (pip install check-jsonschema, or install uv or pipx)" >&2
exit 127
