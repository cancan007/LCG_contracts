#!/usr/bin/env bash
set -e

E2E_IMAGE="trailofbits/echidna"
TARGET_DIR="contracts/echidna"

echo "=== Running Echidna on all Harness contracts ==="

for f in ${TARGET_DIR}/*Harness.sol; do
  CONTRACT_NAME=$(basename "$f" .sol)

  echo ""
  echo ">>> Echidna: $CONTRACT_NAME"
  echo "--------------------------------------------"

  docker run --rm -it \
    -v "$PWD":/work -w /work \
    ${E2E_IMAGE} \
    echidna "$f" \
      --contract "$CONTRACT_NAME" \
      --config echidna.yaml
done

echo ""
echo "=== Echidna finished successfully ==="
