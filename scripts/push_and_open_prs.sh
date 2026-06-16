#!/usr/bin/env bash
set -euo pipefail

: "${REPO_OWNER:=joywearglobal}"
: "${REPO_NAME:=Small-town}"
: "${BASE_BRANCH:=main}"

BRANCH_TO_ISSUE=(
  "feat/jia-5-range-scope-lock|JIA-5|8cd48f4b-f9f3-4bf1-b388-ba061d419ede"
  "feat/jia-6-architecture|JIA-6|dad610bc-5d89-49b7-98c5-7be0314ac8e7"
  "feat/jia-7-order-loop|JIA-7|e5ec9b30-ea05-4c69-b488-c9eb776a73c0"
  "feat/jia-8-resource-township|JIA-8|78cb010e-bf4b-46a9-957d-f6095db5596a"
)

contains_csv() {
  local target="$1"
  local csv="$2"
  [[ ",$csv," == *",${target},"* ]]
}

target="${TARGET_ISSUES:-all}"
if [[ "$target" != "all" ]]; then
  echo "Target issues: $target"
fi

dry_run="${DRY_RUN:-0}"
if [[ "$dry_run" == "1" ]]; then
  echo "DRY_RUN=1 -> remote operations will be skipped"
else
  : "${GH_TOKEN:?Please set GH_TOKEN env var first}"
  : "${LINEAR_API_TOKEN:?Please set LINEAR_API_TOKEN env var first (lin_api_...)}"
fi

echo "==> Start sync: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

for item in "${BRANCH_TO_ISSUE[@]}"; do
  IFS='|' read -r branch issue issue_id <<< "$item"

  if [[ "$target" != "all" ]] && ! contains_csv "$issue" "$target"; then
    echo "Skip: $issue (not in TARGET_ISSUES)"
    continue
  fi

  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Skip: missing branch $branch"
    continue
  fi

  echo "==> Processing $issue ($branch)"
  git checkout -q "$branch"

  # 1) Push branch
  if [[ "$dry_run" != "1" ]]; then
    git push -u origin "$branch"
  else
    echo "  [DRY RUN] skip git push"
  fi

  # 2) Find existing PR or create new PR
  if [[ "$dry_run" == "1" ]]; then
    echo "  [DRY RUN] skip PR query/creation for $branch"
    pr_url="(dry-run-pr-url)"
  else
    existing_pr="$(curl -sS -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: codex" \
      "${API_BASE}/pulls?state=open&head=${REPO_OWNER}:${branch}" \
      | jq -r '.[0].html_url // empty')"

    if [[ -z "$existing_pr" || "$existing_pr" == "null" ]]; then
      pr_title="${issue} - Project 小镇烟火"
      pr_body="Auto-generated PR by Codex for ${issue}."
      pr_payload=$(jq -nc --arg title "$pr_title" --arg head "$branch" --arg body "$pr_body" \
        '{title:$title, head:$head, base:"'"${BASE_BRANCH}"'", body:$body, draft:false}')
      pr_url="$(curl -sS -X POST -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: codex" \
        -d "$pr_payload" "${API_BASE}/pulls" | jq -r '.html_url // empty')"
    else
      pr_url="$existing_pr"
    fi
  fi

  if [[ -z "$pr_url" || "$pr_url" == "null" ]]; then
    echo "  -> PR create/get failed"
    continue
  fi
  echo "  PR: $pr_url"

  # 3) Read Linear description
  if [[ "$dry_run" == "1" ]]; then
    echo "  [DRY RUN] skip Linear query/update for $issue"
    continue
  fi

  linear_query=$(jq -nc --arg id "$issue_id" '{query: "query { issue(id: \\\"" + $id + "\\\") { description } }"}')
  linear_desc="$(curl -sS -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -X POST https://api.linear.app/graphql \
    -d "$linear_query" | jq -r '.data.issue.description // ""')"

  if [[ -z "$linear_desc" || "$linear_desc" == "null" ]]; then
    echo "  -> Linear issue fetch failed for ${issue}"
    continue
  fi

  # 4) Upsert PR link in issue description block
  linear_desc_new="$(printf '%s' "$linear_desc" | python3 - "$pr_url" <<'PY'
import sys

desc = sys.stdin.read()
pr = sys.argv[1]
marker = "### PR 回填（今晚）"
line = f"* 今晚 PR 链接（占位）：{pr}\n"

if marker in desc:
    lines = desc.splitlines(True)
    updated = False
    out = []
    for l in lines:
        if l.startswith("* 今晚 PR 链接（占位）"):
            out.append(line)
            updated = True
        else:
            out.append(l)
    if not updated:
        out.append(line)
    desc = "".join(out)
else:
    desc = desc.rstrip("\n") + "\n\n" + marker + "\n\n" + line

print(desc.rstrip("\n"))
PY)"

  linear_update_payload=$(jq -nc --arg id "$issue_id" --arg desc "$linear_desc_new" '{
    query: "mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { identifier } } }",
    variables: { id: $id, input: { description: $desc } }
  }')

  linear_update_result="$(curl -sS -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -X POST https://api.linear.app/graphql \
    -d "$linear_update_payload")"

  if [[ "$(printf '%s' "$linear_update_result" | jq -r '.data.issueUpdate.success // false')" == "true" ]]; then
    echo "  -> Linear sync done"
  else
    echo "  -> Linear sync failed:"
    echo "$linear_update_result" | jq -r '.errors[0].message // .errors[0].extensions[0] // "unknown error"'
  fi
done

echo "==> Done"