❗ The project is now deprecated. Use GitHub's [official migration guide](https://docs.github.com/en/issues/planning-and-tracking-with-projects/creating-projects/migrating-from-projects-classic) instead.

# How to migrate from GitHub Projects to GitHub Projects (Beta)?

This is a short tutorial on how to automate the migration process between the legacy project boards and the new projects.

It describes how to migrate the legacy project board cards to a new project, preserve the column information in the status field and turn the legacy project board notes into issues so that they can be migrated to the new project.

Due to API immaturity, it does not cover how to automate new project creation, status field option creation or creation of project items not associated with issues.

If you don't care about columns or wonder how to automate adding items to a new project, you might also want to check out [Add Project Items By Content Query](https://github.com/protocol/github-api-action-library/tree/master/add-project-items-by-content-query) action which is capable of populating a new project based on a [content search query](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).

## Prerequisites

*NOTE*: This guide assumes that all the projects/repositories belong to the same owner.

### GitHub Token

You need to create a GitHub token with:
- `admin:org` permission for reading the legacy project board and writing to the new project
- `repo` permission for reading issues in private repositories if such are present in the legacy project board

### Legacy Project Board

Since you're here, I assume you already have a legacy project board that you want to migrate.

### New Project

Unfortunately, due to API immaturity, it is currently not possible to auomate new project creation.

You're going to have to [create an organization project](https://docs.github.com/en/issues/trying-out-the-new-projects-experience/creating-a-project#creating-an-organization-project) or [create a user project](https://docs.github.com/en/issues/trying-out-the-new-projects-experience/creating-a-project#creating-a-user-project) manually.

All you have to do is give it a name of your choosing.

### New Project Status Field Options

*NOTE*: If you skip this step, the script will succeed but it will not migrate information about the columns.

Unfortunately, it is not yet possible to automate populating the option values for the `Status` field of the new project either.

1. Navigate to your project.
1. Click ⚙️ to access the project settings.
1. Click `⬇️ Status` to access the field settings.
1. For every column of your legacy project board, click `➕ Add option` and type the column name.
1. Click `Save options`.

## How to migrate?

You can either run the script from your console or set up and run a GitHub Actions workflow.

Both methods expect the following inputs:
- `OWNER`: the name of the user or the organisation where the projects and the repo reside
- `LEGACY_PROJECT_BOARD_NAME`: the name of the source legacy project board
- `NEW_PROJECT_NAME`: the name of the destination new project
- `REPO`: *[OPTIONAL]* the name of the repository where issues for notes should be created; if skipped, the cards not associated with issues will not be migrated

### Console

1. Install [GitHub CLI](https://cli.github.com/).
1. [Authenticate with GitHub](https://cli.github.com/manual/gh_auth_login) by running `gh auth login` (e.g. with the `GITHUB_TOKEN` you created).
1. Clone this repository  by running `gh repo clone galargh/projects-migration`.
1. Perform the migration by running `./projects-migration/.github/scripts/migrate.sh 'OWNER' 'LEGACY_PROJECT_BOARD_NAME' 'NEW_PROJECT_NAME' 'REPO'`.

### GitHub Actions

This is an example of a migration workflow that you can create in a repository of your choosing:
```
name: Migrate Projects
on: [workflow_dispatch]
jobs:
  migrate:
    uses: galargh/projects-migration/.github/workflows/migrate_reusable.yml@main
    with:
      owner: OWNER
      legacy_project_board_name: LEGACY_PROJECT_BOARD_NAME
      new_project_name: NEW_PROJECT_NAME
      repo: REPO
    secrets:
      token: GITHUB_TOKEN
```

## How does it work?

To analyse the procedure in detail, I advise you to look at the [code](.github/scripts/migrate.sh) directly. Here, I describe some of the steps of the scripts - the ones that involve calling GitHub API.

### 1. Check if the owner if the owner is an user or an organisation.

We need to know this ahead of time because the REST API endpoints for legacy project boards differ for organisation and user projects.

```bash
gh api "users/${owner}" --jq '.type'
```

### 2. Retrieve information about the legacy project board.

To retrieve a legacy project board by name, we list all the legacy project boards owned by the user/organisation and pick the one with a matching name.

Later, we're going to need the information about the legacy project board ID and body (description).

*User*:
```bash
gh api --paginate "users/${owner}/projects" --jq "map(select(.name == \"${legacy_project_board_name}\"))" |
      jq -n '[inputs] | add | .[0]'
```

*Organisation*:
```bash
gh api --paginate "orgs/${owner}/projects" --jq "map(select(.name == \"${legacy_project_board_name}\"))" |
      jq -n '[inputs] | add | .[0]'
```

### 3. Retrieve information about the new project.

There is no REST API for new projects. That's why we're using GraphQL API.

We fetch the new project by name to inspect its' ID and `Status` field.

*User*:
```bash
gh api graphql -f query='query($user: String!, $new_project_name: String!) {
  user(login: $user) {
    projectsNext(first: 1, query: $new_project_name) {
      nodes {
        id
        fields(first: 100) {
          nodes {
            id
            name
            settings
          }
        }
      }
    }
  }
}' -f user="${owner}" -f new_project_name="${new_project_name}" --jq '.data.user.projectsNext.nodes[0]'
```

*Organisation*:
```bash
gh api graphql -f query='query($org: String!, $new_project_name: String!) {
  organization(login: $org) {
    projectsNext(first: 1, query: $new_project_name) {
      nodes {
        id
        fields(first: 100) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
}' -f org="${owner}" -f new_project_name="${new_project_name}" --jq '.data.user.projectsNext.nodes[0]'
```

### 4. Retrieve information about the legacy project board columns.

We need to fetch the columns first so that later we can fetch the cards per column.

```bash
gh api --paginate "projects/${legacy_project_board_id}/columns" | jq -n '[inputs] | add'
```

### 5. Migrate project description.

We use the [updateProjectNext](https://docs.github.com/en/graphql/reference/input-objects#updateprojectnextinput) mutation to migrate the project description from the legacy project board to the new project.

```bash
gh api graphql -f query='mutation($new_project_id: ID!, $legacy_project_board_body: String!) {
  updateProjectNext(input: {
    projectId: $new_project_id,
    shortDescription: $legacy_project_board_body,
    description: $legacy_project_board_body
  }) {
    projectNext {
      id
    }
  }
}' -f new_project_id="${new_project_id}" -f legacy_project_board_body="${legacy_project_board_body}"
```

### 6. Per column: retrieve information about the legacy project board cards.

By fetching cards per column we retain the information on which card belongs to which column and we can use it to populate the `Status` field in the new project.

```bash
gh api --paginate "projects/columns/${legacy_project_board_column_id}/cards" | jq -n '[inputs] | add'
```

### 7. Per card: either create an issue or retrieve information about the associated issue.

If the card has an issue associated with it (the `content_url` on the card object is not `null`), then we can simply fetch the issue's node ID (node IDs are different from the IDs - GraphQL operates on node IDs).

```bash
gh api "$legacy_project_board_card_content_url" --jq '.node_id'
```

Otherwise, we're dealing with a note. If the `repo` input was set, we can create a new issue and fetch the node ID of that new issue.

```bash
gh api "repos/${owner}/${repo}/issues" -f title="${legacy_project_board_card_note:0:60}" -f body="${legacy_project_board_card_note}" --jq '.node_id'
```

### 8. Per card: add issue to the new project.

To add a new issue to the new project, we use `addProjectNextItem` mutation. As for now, it doesn't support adding `Draft` items.

```bash
gh api graphql -f query='mutation($new_project_id: ID!, $legacy_project_board_card_node_id: ID!) {
  addProjectNextItem(input: {
    projectId: $new_project_id,
    contentId: $legacy_project_board_card_node_id
  }) {
    projectNextItem {
      id
    }
  }
}' -f new_project_id="${new_project_id}" -f legacy_project_board_card_node_id="${legacy_project_board_card_node_id}" --jq '.data.addProjectNextItem.projectNextItem.id'
```

### 9. Per card: update the `Status` field on the newly added item.

Finally, we can update the `Status` field on the newly added item to the value corresponding to the column name from the legacy project board. That is if the `Status` field in the new project has such an option value configured of course.

```bash
gh api graphql -f query='mutation($new_project_id: ID!, $new_project_item_id: ID!, $new_project_status_field_id: ID!, $new_project_status_field_option_id: ID!) {
  updateProjectNextItemField(input: {
    projectId: $new_project_id,
    itemId: $new_project_item_id,
    fieldId: $new_project_status_field_id,
    value: $new_project_status_field_option_id,
  }) {
    projectNextItem {
      id
    }
  }
}' -f new_project_id="${new_project_id}" -f new_project_item_id="${new_project_item_id}" -f new_project_status_field_id="${new_project_status_field_id}" -f new_project_status_field_option_id="${new_project_status_field_option_id}"
```

## Resources

- [About project boards - the legacy projects experience](https://docs.github.com/en/issues/organizing-your-work-with-project-boards/managing-project-boards/about-project-boards)
- [About projects (beta) - the new projects experience](https://docs.github.com/en/issues/trying-out-the-new-projects-experience/about-projects)
- [Open discussions on Projects (Beta)](https://github.com/github/feedback/discussions?discussions_q=Projects+Beta)
