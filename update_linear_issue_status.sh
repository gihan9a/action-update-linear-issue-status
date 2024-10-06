#!/bin/bash

# Configurable Variables (coming from GitHub Action inputs)
DRY_RUN=${DRY_RUN:-true}
LINEAR_API_TOKEN=${LINEAR_API_TOKEN}
LINEAR_TEAM_KEY=${LINEAR_TEAM_KEY}
TO_STATUS_ID=${TO_STATUS_ID}
BASE_BRANCH=${BASE_BRANCH}
MAIN_BRANCH=${MAIN_BRANCH}
PR_LIMIT=${PR_LIMIT:-40}

# Get the latest merged PRs merged into the $BASE_BRANCH branch
echo "Fetching latest PRs merged into $BASE_BRANCH branch..."
pr_list=$(gh pr list --base $BASE_BRANCH --state merged --json number,headRefName --limit $PR_LIMIT)

# Check if the pr_list is empty
if [[ -z "$pr_list" ]]; then
  echo "No PRs found."
  exit 0
fi

# find commit range to check for Linear issue IDs
# This script is supposed to run right after $MAIN_BRANCH is merged with a merge commit
# So in that case take the last 2 commits as the range
last_merge_commit=$(git log $MAIN_BRANCH --merges -n 1 --pretty=format:"%H")
second_last_merge_commit=$(git log $MAIN_BRANCH --merges -n 2 --pretty=format:"%H" | tail -n 1)

# Extract branch names and corresponding Linear issue IDs
echo "Extracting Linear issue identifier numbers from branch names..."
issue_identifier_numbers=()

# Iterate through PRs and ensure they are part of the current release branch
for row in $(echo "${pr_list}" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  # Extract the branch name
  branch_name=$(_jq '.headRefName')

  # Extract the PR number
  pr_number=$(_jq '.number')

  # Find the commit related to the PR number within the valid commit range
  commit_sha=$(git log $MAIN_BRANCH --grep "(#$pr_number)" --format="%H" --reverse $second_last_merge_commit..$last_merge_commit | head -n 1)

  # If the commit is found, proceed to extract the Linear issue ID number
  if [[ ! -z "$commit_sha" ]]; then
    # Extract the Linear issue ID (assuming branch format is prefix/LINEAR_TEAM_KEY-ID-name)
    issue_identifier_number=$(echo "$branch_name" | grep -Eio "$LINEAR_TEAM_KEY-[0-9]+" | cut -d'-' -f2)

    # If issue ID number exists, add it to the list
    if [[ ! -z "$issue_identifier_number" ]]; then
      issue_identifier_numbers+=("$issue_identifier_number")
    fi
  fi
done

# Display extracted issue IDs
if [ ${#issue_identifier_numbers[@]} -eq 0 ]; then
  echo "No Linear issue IDs found in the current release branch."
  exit 0
fi

echo "Extracted Linear Issue IDs: "$(printf "$LINEAR_TEAM_KEY-%s," "${issue_identifier_numbers[@]}")

# Convert issue numbers into JSON array format for batch query
issue_identifier_numbers_string=$(printf '%s,' "${issue_identifier_numbers[@]}")
issue_identifier_numbers_string="[${issue_identifier_numbers_string%,}]" # Wrap in brackets and remove the trailing comma

# Query Linear for the ids in batch
echo "Querying Linear for issue ids..."
ids_response=$(curl -s -X POST \
  -H "Authorization: $LINEAR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "query": "query { issues(filter: { team: { key: { eq: \"'$LINEAR_TEAM_KEY'\" } }, number: { in: '"$issue_identifier_numbers_string"' }, state: { id: { neq: \"'$TO_STATUS_ID'\" } } }) { nodes { id identifier } } }"
    }' \
  https://api.linear.app/graphql)

if [ $? -ne 0 ]; then
  echo "Linear API request failed."
  echo "Raw response:"
  echo "$ids_response"
  exit 1
fi

# Extract issue ids and map them
issue_ids=($(echo "$ids_response" | jq -r '.data.issues.nodes[].id'))
issue_identifiers=($(echo "$ids_response" | jq -r '.data.issues.nodes[].identifier'))

if [ ${#issue_ids[@]} -eq 0 ]; then
  echo "Linear issues are upto date."
  exit 0
fi

echo "Updating Linear issues: ${issue_identifiers[@]}"

issue_ids_string=$(printf '\\"%s\\",' "${issue_ids[@]}")
issue_ids_string="[${issue_ids_string%,}]" # Wrap in brackets and remove the trailing comma

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
            "query": "mutation { issueBatchUpdate(ids: '"$issue_ids_string"', input: { stateId: \"'"$TO_STATUS_ID"'\" }) { success }}"
        }' \
    https://api.linear.app/graphql

  if [ $? -eq 0 ]; then
    echo "Successfully updated issues in Linear."
  else
    echo "Failed to update issues in Linear."
  fi
fi
