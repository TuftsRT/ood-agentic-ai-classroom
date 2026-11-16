#!/usr/bin/env bash
# Fetch the embedding model used by the optional "Reference documents"
# feature (see reference_docs_dir in form.yml.erb). Run on a LOGIN node --
# needs internet, which compute nodes on this cluster don't have.
#
# The shared, RT-maintained embedding-model catalog has no usable entry for
# this (same situation rag-sandbox already documented when it bootstrapped
# its own copy of the same model), so this app vendors its own copy under
# models/embedding/ rather than depending on another app's directory.
#
# NOT YET VERIFIED: this shell has no live network access to confirm the
# exact HuggingFace repo/filename/revision below is still current. The
# trust-on-first-use hash pin below (same pattern as rag-sandbox's own
# download-embedding-model.sh) makes a *changed* file detectable on any
# later re-run, but does not make a *wrong URL on the very first run*
# detectable -- review this once against a real login-node run before
# relying on it.
set -euo pipefail
cd "$(dirname "$0")"

EMBED_MODEL_DIR="models/embedding/nomic-embed-text-v1.5"
EMBED_MODEL_FILE="$EMBED_MODEL_DIR/nomic-embed-text-v1.5.Q8_0.gguf"

REPO="nomic-ai/nomic-embed-text-v1.5-GGUF"
FILE="nomic-embed-text-v1.5.Q8_0.gguf"
URL="https://huggingface.co/${REPO}/resolve/main/${FILE}"

mkdir -p "$EMBED_MODEL_DIR"
PINS="$EMBED_MODEL_DIR/pins.sha256"
touch "$PINS"

pin() {
  local file="$1" got want
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  want="$(awk -v f="$file" '$2==f{print $1}' "$PINS")"
  if [ -z "$want" ]; then
    echo "$got  $file" >> "$PINS"; echo "    pinned $(basename "$file")"
  elif [ "$got" != "$want" ]; then
    echo "    HASH MISMATCH $file" >&2
    echo "      expected $want" >&2
    echo "      got      $got" >&2
    return 1
  else
    echo "    ok $(basename "$file")"
  fi
}

if ! curl -fsI --max-time 10 "https://huggingface.co" > /dev/null; then
  echo "No outbound internet to huggingface.co - run this on a LOGIN node, not a compute node." >&2
  exit 1
fi

if [ ! -f "$EMBED_MODEL_FILE" ]; then
  echo "== downloading $FILE from $REPO =="
  curl -fL --retry 3 -C - -o "$EMBED_MODEL_FILE" "$URL"
fi
pin "$EMBED_MODEL_FILE"

echo "done: $EMBED_MODEL_FILE"
