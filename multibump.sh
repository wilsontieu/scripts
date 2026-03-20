#!/bin/bash

# Default values
TICKET="PPS-0000"
PACKAGES_ARG=""
BRANCHES=("master" "main")

# --- Argument Parsing ---
for ARG in "$@"; do
  case $ARG in
    ticket=*) 
      TICKET="${ARG#*=}"
      shift
      ;;
    packages=*) 
      PACKAGES_ARG="${ARG#*=}"
      shift
      ;;
  esac
done

if [ -z "$PACKAGES_ARG" ]; then
  echo "Usage: $0 packages=<pkg1>,<pkg2>[@<version>] [ticket=<ticket_number>]"
  echo "Example: $0 packages=google.golang.org/grpc,google.golang.org/protobuf ticket=PPS-4984"
  exit 1
fi

# --- Initial Setup ---
IFS=',' read -r -a PACKAGES <<< "$PACKAGES_ARG"
MODIFIED_REPOS=()
INITIAL_DIR=$(pwd)

# --- Phase 1: Staging Changes ---
echo "--- Phase 1: Staging local changes ---"
for job_path in jobs/*; do
  [ -d "$job_path" ] || continue
  [ -f "$job_path/go.mod" ] || continue

  repo_name=$(basename "$job_path")
  echo "=== Processing $repo_name ==="

  PACKAGES_IN_REPO=()
  for PACKAGE in "${PACKAGES[@]}"; do
    PACKAGE_NAME=$(echo "$PACKAGE" | cut -d'@' -f1)
    if grep -q "$PACKAGE_NAME" "$job_path/go.mod"; then
      PACKAGES_IN_REPO+=("$PACKAGE")
    fi
  done

  if [ ${#PACKAGES_IN_REPO[@]} -eq 0 ]; then
    echo "Skipping $repo_name: No relevant packages found."
    continue
  fi

  cd "$job_path" || continue

  git stash -u -m "temp-bump"
  
  DEFAULT_BRANCH=""
  for branch in "${BRANCHES[@]}"; do
      if git checkout "$branch" && git pull; then
          DEFAULT_BRANCH="$branch"
          break
      fi
  done

  if [ -z "$DEFAULT_BRANCH" ]; then
      echo "Could not checkout and pull any of the branches in $repo_name: ${BRANCHES[*]}"
      cd "$INITIAL_DIR"
      continue
  fi

  BRANCH_NAME="$TICKET-bump-multiple-packages"
  if [ ${#PACKAGES_IN_REPO[@]} -eq 1 ]; then
    PACKAGE_NAME_SLUG=$(echo "${PACKAGES_IN_REPO[0]}" | cut -d'@' -f1 | sed 's/\//-/g')
    BRANCH_NAME="$TICKET-bump-$PACKAGE_NAME_SLUG"
  fi
  
  git checkout -B "$BRANCH_NAME"

  for PACKAGE in "${PACKAGES_IN_REPO[@]}"; do
    if ! [[ "$PACKAGE" == *"@"* ]]; then
      PACKAGE_WITH_VERSION="$PACKAGE@latest"
    else
      PACKAGE_WITH_VERSION="$PACKAGE"
    fi
    echo "Staging 'go get $PACKAGE_WITH_VERSION' in $repo_name"
    go get "$PACKAGE_WITH_VERSION"
  done

  go mod tidy
  git add go.mod go.sum

  if git diff --cached --quiet; then
    echo "No changes for $repo_name"
  else
    echo "Staged changes for $repo_name"
    MODIFIED_REPOS+=("$job_path")
  fi

  cd "$INITIAL_DIR"
done

# --- Phase 2: Confirmation ---
echo
if [ ${#MODIFIED_REPOS[@]} -eq 0 ]; then
  echo "No repositories were modified. Exiting."
  exit 0
fi

echo "--- Phase 2: Confirmation ---"
echo "The following repositories have staged changes:"
for repo in "${MODIFIED_REPOS[@]}"; do
  echo " - $repo"
done
echo

read -p "Do you want to commit, push, and create PRs for them? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted. Local branches with staged changes have been created in each repo."
  exit 1
fi

# --- Phase 3: Execution ---
echo
echo "--- Phase 3: Creating Commits and PRs ---"
for job_path in "${MODIFIED_REPOS[@]}"; do
  repo_name=$(basename "$job_path")
  echo "=== Finalizing $repo_name ==="

  cd "$job_path" || continue

  # Re-evaluate which packages were relevant for this repo to build messages
  PACKAGES_IN_REPO=()
  for PACKAGE in "${PACKAGES[@]}"; do
    PACKAGE_NAME=$(echo "$PACKAGE" | cut -d'@' -f1)
    if grep -q "$PACKAGE_NAME" "go.mod"; then
      PACKAGES_IN_REPO+=("$PACKAGE")
    fi
  done

  # Determine branch name and PR content again
  BRANCH_NAME="$TICKET-bump-multiple-packages"
  if [ ${#PACKAGES_IN_REPO[@]} -eq 1 ]; then
    PACKAGE_NAME_SLUG=$(echo "${PACKAGES_IN_REPO[0]}" | cut -d'@' -f1 | sed 's/\//-/g')
    BRANCH_NAME="$TICKET-bump-$PACKAGE_NAME_SLUG"
  fi

  PR_TITLE=""
  PR_BODY=""
  if [ ${#PACKAGES_IN_REPO[@]} -gt 1 ]; then
    PR_TITLE="[$TICKET] Bump multiple packages"
    PACKAGES_LIST_FOR_BODY=$(printf -- ' * `%s`\n' "${PACKAGES_IN_REPO[@]}")
    PR_BODY=$(cat <<EOF
https://priceline.atlassian.net/browse/$TICKET

Bump multiple packages to resolve NexusIQ vulnerabilities.

Packages updated in this repo:
$PACKAGES_LIST_FOR_BODY
EOF
)
  else
    PACKAGE_NAME=$(echo "${PACKAGES_IN_REPO[0]}" | cut -d'@' -f1)
    PR_TITLE="[$TICKET] Bump $PACKAGE_NAME"
    PR_BODY=$(cat <<EOF
https://priceline.atlassian.net/browse/$TICKET

Bump 
$PACKAGE_NAME
 to latest to resolve NexusIQ vulnerabilities.
EOF
)
  fi

  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')

  echo "Committing, pushing, and creating PR for $repo_name..."
  git commit -m "$PR_TITLE"
  git push -u origin "$BRANCH_NAME"

  gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH_NAME" \
    --web

  cd "$INITIAL_DIR"
done

echo
echo "All done."
