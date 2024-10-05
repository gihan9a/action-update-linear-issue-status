#!/bin/bash

# Configurable Variables (coming from GitHub Action inputs)
DRY_RUN=${DRY_RUN:-true}
LINEAR_API_TOKEN=${LINEAR_API_TOKEN}
LINEAR_TEAM_KEY=${LINEAR_TEAM_KEY}
TO_STATUS_ID=${TO_STATUS_ID}
BASE_BRANCH=${BASE_BRANCH}
MAIN_BRANCH=${MAIN_BRANCH}

RELEASE_BRANCH=$(git branch --show-current)

# Get the merge base between develop and the current release branch
MERGE_BASE=$(git merge-base $MAIN_BRANCH $RELEASE_BRANCH)

# Get the latest merged PRs from the $BASE_BRANCH branch (limit to 40)
echo "Fetching latest PRs merged into $BASE_BRANCH branch..."
PR_LIST=$(gh pr list --base $BASE_BRANCH --state merged --json number,headRefName --limit 40)

# Check if the PR_LIST variable is empty
if [[ -z "$PR_LIST" ]]; then
  echo "No PRs found."
  exit 0
fi

# Extract branch names and corresponding Linear issue IDs
echo "Extracting Linear issue IDs from branch names..."
ISSUE_IDS=()

# Iterate through PRs and ensure they are part of the current release branch
for row in $(echo "${PR_LIST}" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  # Extract the branch name
  branch_name=$(_jq '.headRefName')

  # Extract the PR number
  pr_number=$(_jq '.number')

  # Find the commit related to the PR number in the commit message
  commit_sha=$(git log --grep "(#$pr_number)" --format="%H" --reverse $MERGE_BASE..HEAD | head -n 1)

  # If the commit is found, proceed to extract the Linear issue ID
  if [[ ! -z "$commit_sha" ]]; then
    # Extract the Linear issue ID (assuming branch format is prefix/LINEAR_TEAM_KEY-ID-name)
    linear_issue_identifier=$(echo "$branch_name" | grep -Eio "$LINEAR_TEAM_KEY-[0-9]+" | cut -d'-' -f2)

    # If issue ID exists, add it to the lst
    if [[ ! -z "$linear_issue_identifier" ]]; then
      ISSUE_IDS+=("$linear_issue_identifier")
    fi
  fi
done

# Display extracted issue IDs
if [ ${#ISSUE_IDS[@]} -eq 0 ]; then
  echo "No Linear issue IDs found in the current release branch."
  exit 0
fi

echo "Extracted Linear Issue IDs: "$(printf "$LINEAR_TEAM_KEY-%s," "${ISSUE_IDS[@]}")

# Convert issue numbers into JSON array format for batch query
ISSUE_NUMBERS_STRING=$(printf '%s,' "${ISSUE_IDS[@]}")
ISSUE_NUMBERS_STRING="[${ISSUE_NUMBERS_STRING%,}]" # Wrap in brackets and remove the trailing comma

# Query Linear for the UUIDs in batch
echo "Querying Linear for issue UUIDs..."
UUIDS_RESPONSE=$(curl -s -X POST \
  -H "Authorization: $LINEAR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "query": "query { issues(filter: { team: { key: { eq: \"'$LINEAR_TEAM_KEY'\" } }, number: { in: '"$ISSUE_NUMBERS_STRING"' }, state: { id: { neq: \"'$TO_STATUS_ID'\" } } }) { nodes { id identifier } } }"
    }' \
  https://api.linear.app/graphql)

# Extract issue UUIDs and map them
ISSUE_UUIDS=($(echo "$UUIDS_RESPONSE" | jq -r '.data.issues.nodes[].id'))
ISSUE_IDENTIFIERS=($(echo "$UUIDS_RESPONSE" | jq -r '.data.issues.nodes[].identifier'))

if [ ${#ISSUE_UUIDS[@]} -eq 0 ]; then
  echo "Failed to retrieve UUIDs for the given issues."
  exit 1
fi

echo "Updating Linear issues: ${ISSUE_IDENTIFIERS[@]}"

ISSUE_UUIDS_STRING=$(printf '\\"%s\\",' "${ISSUE_UUIDS[@]}")
ISSUE_UUIDS_STRING="[${ISSUE_UUIDS_STRING%,}]" # Wrap in brackets and remove the trailing comma

# Prepare to update issues in Linear
if [ "$DRY_RUN" = true ]; then
  echo "Dry-run mode: Skipping actual Linear issue updates"
else
  echo "Updating Linear issue statuses..."
  # Batch updating issues in Linear
  curl -X POST \
    -H "Authorization: $LINEAR_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
            "query": "mutation { issueBatchUpdate(ids: '"$ISSUE_UUIDS_STRING"', input: { stateId: \"'"$TO_STATUS_ID"'\" }) { success }}"
        }' \
    https://api.linear.app/graphql

  if [ $? -eq 0 ]; then
    echo "Successfully updated issues in Linear."
  else
    echo "Failed to update issues in Linear."
  fi
fi
