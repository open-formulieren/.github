#!/usr/bin/env bash
#
# Report on GitHub issues in the open-formulieren organization that are labeled
# 'broncodebeheer' and were closed in a given year. All closed issues from the
# open-formulieren/security-issues repository are included as well, since those
# implicitly fall under 'broncodebeheer' (they never carry the label).
#
# Output is Markdown on stdout: a summary (total closed, number labeled
# 'needs-backport') followed by the full list of issues grouped by month.
#
# Requirements: gh (authenticated), jq
#
# Note: months are derived from the `closedAt` timestamp, which is in UTC.

set -euo pipefail

OWNER="open-formulieren"
LABEL="broncodebeheer"
BACKPORT_LABEL="needs-backport"
SECURITY_REPO="${OWNER}/security-issues"
SEARCH_LIMIT=1000  # hard cap of the GitHub search API

usage() {
    cat <<EOF
Usage: $(basename "$0") [YEAR]

Report on issues in the '${OWNER}' organization labeled '${LABEL}' that were
closed in YEAR (defaults to the current year), plus all issues closed in YEAR
in '${SECURITY_REPO}'. Outputs Markdown on stdout.

Example:
    $(basename "$0") 2026 > report-2026.md
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 1
fi

YEAR="${1:-$(date +%Y)}"
if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
    echo "Error: YEAR must be a 4-digit number, got '${YEAR}'." >&2
    exit 1
fi

for cmd in gh jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '${cmd}' is required but not installed." >&2
        exit 1
    fi
done

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 1
fi

CLOSED_RANGE="${YEAR}-01-01..${YEAR}-12-31"
JSON_FIELDS="repository,number,title,closedAt,labels,url"

check_limit() {
    local name="$1" json="$2" count
    count=$(jq 'length' <<<"$json")
    if [[ "$count" -ge "$SEARCH_LIMIT" ]]; then
        echo "Warning: ${name} search returned ${count} results, which is the" \
            "search API limit. The report may be incomplete." >&2
    fi
}

labeled_json=$(
    gh search issues \
        --owner "$OWNER" \
        --label "$LABEL" \
        --closed "$CLOSED_RANGE" \
        --limit "$SEARCH_LIMIT" \
        --json "$JSON_FIELDS"
)
check_limit "'${LABEL}' label" "$labeled_json"

# Issues in the security repository never carry the label, but are implicitly
# part of 'broncodebeheer' - include all closed issues from it.
security_json=$(
    gh search issues \
        --repo "$SECURITY_REPO" \
        --closed "$CLOSED_RANGE" \
        --limit "$SEARCH_LIMIT" \
        --json "$JSON_FIELDS"
)
check_limit "'${SECURITY_REPO}'" "$security_json"

# Merge both result sets, de-duplicating on URL.
issues_json=$(jq -s 'add | unique_by(.url)' <<<"${labeled_json}${security_json}")

jq -r \
    --arg year "$YEAR" \
    --arg label "$LABEL" \
    --arg backport "$BACKPORT_LABEL" \
    --arg security_repo "$SECURITY_REPO" '
    def escape_md: gsub("\\|"; "\\|") | gsub("\n"; " ");
    def yesno: if . then "yes" else "no" end;

    map({
        repo: .repository.name,
        number,
        title,
        url,
        closed: .closedAt[0:10],
        month: .closedAt[0:7],
        backport: ([.labels[].name] | index($backport) != null),
        security: (.repository.nameWithOwner == $security_repo)
    })
    | sort_by(.closed, .repo, .number) as $issues
    | ($issues | map(select(.backport)) | length) as $n_backport
    | ($issues | map(select(.security)) | length) as $n_security
    | (
        "# Broncodebeheer report \($year)",
        "",
        "Issues in the open-formulieren organization labeled `\($label)`, closed in \($year),",
        "plus all issues closed in `\($security_repo)` in \($year).",
        "",
        "## Summary",
        "",
        "- Issues closed: \($issues | length)",
        "- Labeled `\($backport)`: \($n_backport)",
        "- From `\($security_repo)`: \($n_security)",
        "",
        "## Issues by month",
        (
            $issues
            | group_by(.month)[]
            | . as $group
            | (
                "",
                "### \($group[0].month) (\($group | length) closed, \($group | map(select(.backport)) | length) \($backport))",
                "",
                "| Closed | Repository | Issue | Title | Backport |",
                "|--------|------------|-------|-------|----------|",
                ($group[] | "| \(.closed) | \(.repo) | [#\(.number)](\(.url)) | \(.title | escape_md) | \(.backport | yesno) |")
            )
        )
    )
' <<<"$issues_json"
