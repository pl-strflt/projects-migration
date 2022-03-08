#!/bin/bash

set -e
set -u
set -o pipefail

echo "::group::Parsing inputs"
owner="$1"
echo "owner=${owner}"
legacy_project_board_name="$2"
echo "legacy_project_board_name=${legacy_project_board_name}"
new_project_name="$3"
echo "new_project_name=${new_project_name}"
repo="$4"
echo "repo=${repo}"
echo "::endgroup::"

echo "::group::Checking the type of the owner"
type="$(gh api "users/${owner}" --jq '.type')"
echo "type=${type}"
echo "::endgroup::"

if [[ "$type" == "User" ]]; then
  echo "::group::Retrieving legacy project board"
  legacy_project_board="$(
    gh api --paginate "users/${owner}/projects" --jq "map(select(.name == \"${legacy_project_board_name}\"))" |
      jq -n '[inputs] | add | .[0]'
  )"
  echo "legacy_project_board=$(jq '.id' <<< "${legacy_project_board}")"
  echo "::endgroup::"

  echo "::group::Retrieving new project"
  new_project="$(
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
  )"
  echo "new_project=$(jq '.id' <<< "${new_project}")"
  echo "::endgroup::"
elif [[ "$type" == "Organization" ]]; then
  echo "::group::Retrieving legacy project board"
  legacy_project_board="$(
    gh api --paginate "orgs/${owner}/projects" --jq "map(select(.name == \"${legacy_project_board_name}\"))" |
      jq -n '[inputs] | add | .[0]'
  )"
  echo "legacy_project_board=$(jq '.id' <<< "${legacy_project_board}")"
  echo "::endgroup::"

  echo "::group::Retrieving new project"
  new_project="$(
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
  )"
  echo "new_project=$(jq '.id' <<< "${new_project}")"
  echo "::endgroup::"
fi

echo "::group::Retrieving information about legacy project board and new project"
legacy_project_board_body="$(jq -r '.body' <<< "${legacy_project_board}")"
echo "legacy_project_board_body=${legacy_project_board_body}"
new_project_id="$(jq -r '.id' <<< "${new_project}")"
echo "new_project_id=${new_project_id}"
legacy_project_board_id="$(jq '.id' <<< "${legacy_project_board}")"
echo "legacy_project_board_id=${legacy_project_board_id}"
legacy_project_board_columns="$(gh api --paginate "projects/${legacy_project_board_id}/columns" | jq -n '[inputs] | add')"
echo "legacy_project_board_columns=$(jq 'map(.id)' <<< "${legacy_project_board_columns}")"
new_project_status_field="$(jq -r '.fields.nodes | map(select(.name == "Status")) | .[0]' <<< "${new_project}")"
echo "new_project_status_field=$(jq '.id' <<< "{new_project_status_field}")"
new_project_status_field_id="$(jq -r '.id' <<< "${new_project_status_field}")"
echo "new_project_status_field_id=${new_project_status_field_id}"
new_project_status_field_settings="$(jq -r '.settings' <<< "${new_project_status_field}")"
echo "new_project_status_field_settings=${new_project_status_field_settings}"
echo "::endgroup::"

echo "::group::Synchronising metadata"
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
echo "::endgroup::"

echo "::group::Synchronising cards"
while read legacy_project_board_column_id; do
  echo "legacy_project_board_column_id=${legacy_project_board_column_id}"
  legacy_project_board_column_name="$(jq -r 'map(select(.id == $legacy_project_board_column_id)) | .[0].name' --argjson legacy_project_board_column_id "${legacy_project_board_column_id}" <<< "$legacy_project_board_columns")"
  echo "legacy_project_board_column_name=${legacy_project_board_column_name}"
  legacy_project_board_cards="$(gh api --paginate "projects/columns/${legacy_project_board_column_id}/cards" | jq -n '[inputs] | add')"
  echo "legacy_project_board_cards=$(jq 'map(.id)' <<< "${legacy_project_board_cards}")"
  new_project_status_field_option_id="$(jq -r '.options | map(select(.name == $legacy_project_board_column_name)) | .[0].id // ""' --arg legacy_project_board_column_name "${legacy_project_board_column_name}" <<< "${new_project_status_field_settings}")"
  echo "new_project_status_field_option_id=${new_project_status_field_option_id}"

  while read legacy_project_board_card_id; do
    echo "legacy_project_board_card_id=${legacy_project_board_card_id}"
    legacy_project_board_card="$(jq -r 'map(select(.id == $legacy_project_board_card_id)) | .[0]' --argjson legacy_project_board_card_id "${legacy_project_board_card_id}" <<< "$legacy_project_board_cards")"
    echo "legacy_project_board_card=$(jq '.id' <<< "${legacy_project_board_card}")"
    legacy_project_board_card_content_url="$(jq -r '.content_url // ""' <<< "${legacy_project_board_card}")"
    echo "legacy_project_board_card_content_url=${legacy_project_board_card_content_url}"

    if [[ -z "${legacy_project_board_card_content_url}" ]]; then
      if [[ ! -z "$repo" ]]; then
        legacy_project_board_card_note="$(jq -r '.note // ""' <<< "${legacy_project_board_card}")"
        echo "legacy_project_board_card_note=${legacy_project_board_card_note}"
        legacy_project_board_card_node_id="$(gh api "repos/${owner}/${repo}/issues" -f title="${legacy_project_board_card_note:0:60}" -f body="${legacy_project_board_card_note}" --jq '.node_id')"
      else
        continue
      fi
    else
      legacy_project_board_card_node_id="$(gh api "$legacy_project_board_card_content_url" --jq '.node_id')"
    fi
    echo "legacy_project_board_card_node_id=${legacy_project_board_card_node_id}"

    new_project_item_id="$(
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
    )"
    echo "new_project_item_id=${new_project_item_id}"

    if [[ ! -z "$new_project_status_field_option_id" ]]; then
      gh api graphql -f query='mutation($new_project_id: ID!, $new_project_item_id: ID!, $new_project_status_field_id: ID!, $new_project_status_field_option_id: String!) {
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
    fi
  done <<< "$(jq '.[].id' <<< "$legacy_project_board_cards")"
done <<< "$(jq '.[].id' <<< "$legacy_project_board_columns")"
echo "::endgroup::"
