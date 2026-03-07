#!/usr/bin/env bash
# Pre-commit safety checks for common issues caught by AI code reviewers.
#
# Can be run standalone: bash scripts/pre-commit-safety.sh
# Or installed as a git pre-commit hook via dev-setup.sh.
#
# Checks staged .rs files for:
#   1. Unsafe UTF-8 byte slicing (panics on multi-byte chars)
#   2. Case-sensitive file extension / media type comparisons
#   3. Hardcoded /tmp paths in tests (flaky in parallel runs)
#   4. Tool parameters logged without redaction (secret leaks)
#
# Suppress individual lines with an inline "// safety: <reason>" comment.

set -euo pipefail

# Support both pre-commit hook (staged files) and standalone (all changed vs main)
if git diff --cached --quiet 2>/dev/null; then
    # No staged changes -- compare working tree against main
    DIFF_CMD="git diff origin/main -- "
else
    DIFF_CMD="git diff --cached -U0 -- "
fi

WARNINGS=0

warn() {
    if [ "$WARNINGS" -eq 0 ]; then
        echo ""
        echo "=== Pre-commit Safety Checks ==="
        echo ""
    fi
    WARNINGS=$((WARNINGS + 1))
    echo "  [$1] $2"
}

# 1. Unsafe UTF-8 byte slicing: &s[..N] or &s[..some_var] on strings
#    Safe patterns: is_char_boundary, char_indices, // safety:
if $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+' | grep -E '\[\.\..*\]' | grep -vE 'is_char_boundary|char_indices|// safety:|as_bytes|Vec<|&\[u8\]|\[u8\]|bytes\(\)|&bytes' | head -3 | grep -q .; then
    warn "UTF8" "Possible unsafe byte-index string slicing. Use is_char_boundary() or char_indices()."
    $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+' | grep -E '\[\.\..*\]' | grep -vE 'is_char_boundary|char_indices|// safety:|as_bytes|Vec<|&\[u8\]|\[u8\]|bytes\(\)|&bytes' | head -3 | sed 's/^/    /'
fi

# 2. Case-sensitive file extension or media type checks
#    Match: .ends_with(".png") or == "image/jpeg" without prior to_lowercase
if $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*ends_with\("\.([pP][nN][gG]|[jJ][pP][eE]?[gG]|[gG][iI][fF]|[wW][eE][bB][pP]|[mM][dD])"\)' | grep -vE 'to_lowercase|to_ascii_lowercase|// safety:' | head -3 | grep -q .; then
    warn "CASE" "Case-sensitive file extension comparison. Normalize to lowercase first."
    $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*ends_with\("\.([pP][nN][gG]|[jJ][pP][eE]?[gG]|[gG][iI][fF]|[wW][eE][bB][pP]|[mM][dD])"\)' | grep -vE 'to_lowercase|to_ascii_lowercase|// safety:' | head -3 | sed 's/^/    /'
fi

# 3. Hardcoded /tmp paths in test files
if $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*"/tmp/' | grep -vE 'tempfile|tempdir|// safety:' | head -3 | grep -q .; then
    warn "TMPDIR" "Hardcoded /tmp path. Use tempfile::tempdir() for parallel-safe tests."
    $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*"/tmp/' | grep -vE 'tempfile|tempdir|// safety:' | head -3 | sed 's/^/    /'
fi

# 4. Logging tool parameters without redaction
if $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*tracing::(info|debug|warn|error).*param' | grep -vE 'redact|// safety:' | head -3 | grep -q .; then
    warn "REDACT" "Logging tool parameters without redaction. Use redact_params() first."
    $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*tracing::(info|debug|warn|error).*param' | grep -vE 'redact|// safety:' | head -3 | sed 's/^/    /'
fi

# 5. Multi-step DB operations without transaction
if $DIFF_CMD '*.rs' 2>/dev/null | grep -nE '^\+.*(\.execute\(|\.query\()' | head -1 | grep -q .; then
    # Check if there are multiple execute/query calls in the same hunk without transaction/tx
    HUNK_COUNT=$($DIFF_CMD '*.rs' 2>/dev/null | awk '
        /^@@/ { count=0; has_tx=0 }
        /^\+.*\.(execute|query)\(/ { count++ }
        /^\+.*(transaction|\.tx\.|begin)/ { has_tx=1 }
        /^@@/ { if (prev_count >= 2 && !prev_tx) found++ }
        { prev_count=count; prev_tx=has_tx }
        END { if (count >= 2 && !has_tx) found++; print found+0 }
    ')
    if [ "$HUNK_COUNT" -gt 0 ]; then
        warn "TX" "Multiple DB operations in same hunk without transaction. Wrap in a transaction for atomicity."
    fi
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo ""
    echo "Found $WARNINGS potential issue(s). Fix them or add '// safety: <reason>' to suppress."
    echo ""
    exit 1
fi
