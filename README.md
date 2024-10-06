# Update Linear Issues Status

This linear issue status updater is a composite action that will update the status of Linear issues when PRs are merged into a give branch.


### Example
```yml
name: "Update Linear Issues on Release PR Merge"
on:
  push:
    branches:
      - main

jobs:
  update-linear:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Use Hosted Linear Issue Update Action
        uses: gihan9a/action-update-linear-issue-status@main  # Points to the public repo and version
        with:
          linear_api_token: ${{ secrets.LINEAR_API_TOKEN }}
          linear_team_key: "<your-linear-team-key>"
          to_state_id: "<your-done-state-id>" 
          dry_run: "true"  # Set to false when ready to update
          base_branch: "develop"
          main_branch: "main"
```