#!/usr/bin/env bash
set -euo pipefail

cd /mnt/c/Users/DELL/Desktop/Work/SRAM

export GIT_AUTHOR_NAME="SRAM Setup"
export GIT_AUTHOR_EMAIL="sram@local"
export GIT_COMMITTER_NAME="SRAM Setup"
export GIT_COMMITTER_EMAIL="sram@local"

# ---------------------------------------------------------------------------
# 1. Commit current state to main (preserve original repository layout)
# ---------------------------------------------------------------------------
git add golden sources tests prompt.txt pyproject.toml .gitignore
git commit -m "Initial repository state with sources, golden reference, and tests."

# Save golden source and test file for branch construction
cp golden/sram.sv /tmp/sram_golden.sv
cp tests/test_sram_hidden.py /tmp/test_sram_hidden.py

# ---------------------------------------------------------------------------
# 2. sram_baseline: incomplete sources, no golden/, empty tests/
# ---------------------------------------------------------------------------
git checkout -b sram_baseline
rm -rf golden/
rm -f tests/test_sram_hidden.py
rm -rf tests/sim_build
touch tests/.gitkeep
git add -A
git commit -m "SRAM baseline: incomplete implementation, empty tests, no golden reference."

# ---------------------------------------------------------------------------
# 3. sram_test: baseline + populated tests (fail against baseline code)
# ---------------------------------------------------------------------------
git checkout -b sram_test
cp /tmp/test_sram_hidden.py tests/test_sram_hidden.py
rm -f tests/.gitkeep
git add tests/test_sram_hidden.py tests/.gitkeep
git commit -m "SRAM test branch: add cocotb tests targeting sources/sram.sv."

# ---------------------------------------------------------------------------
# 4. sram_golden: baseline structure + complete sources, empty tests/
# ---------------------------------------------------------------------------
git checkout sram_baseline
git checkout -b sram_golden
cp /tmp/sram_golden.sv sources/sram.sv
git add sources/sram.sv
git commit -m "SRAM golden branch: complete implementation in sources/sram.sv."

# ---------------------------------------------------------------------------
# 5. Return to main and show branch summary
# ---------------------------------------------------------------------------
git checkout main
echo ""
echo "Branches created:"
git branch -v
echo ""
echo "Tree summary:"
for branch in main sram_baseline sram_test sram_golden; do
  echo "=== ${branch} ==="
  git ls-tree -r --name-only "${branch}" | sort
  echo ""
done
