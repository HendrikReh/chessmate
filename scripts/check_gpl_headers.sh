#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || {
  echo "error: must run inside git repository" >&2
  exit 1
})

cd "$ROOT_DIR"

HEADER="$(cat <<'EOF'
(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
    Copyright (C) 2025 Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*)
EOF
)"

header_lines=$(printf '%s\n' "$HEADER" | wc -l | tr -d ' ')

missing=()

while IFS= read -r file; do
  [[ -s "$file" ]] || continue
  if ! diff -u --label "$file" --label header \
    <(printf '%s\n' "$HEADER") <(head -n "$header_lines" "$file") >/dev/null
  then
    missing+=("$file")
  fi
done < <(git ls-files '*.ml' '*.mli' '*.mll' '*.mly')

if ((${#missing[@]})); then
  printf 'error: %d file(s) missing GPL header:\n' "${#missing[@]}" >&2
  for file in "${missing[@]}"; do
    printf '  %s\n' "$file" >&2
  done
  exit 1
fi

echo "GPL headers verified (${#missing[@]} issues)."
