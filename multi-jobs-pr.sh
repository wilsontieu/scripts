#!/bin/bash

# Default values
TICKET="PPS-0000"
PACKAGES_ARG=""
REPOS_ARG=""
BRANCHES=("master" "main")

# --- Argument Parsing ---
for ARG in "$@"; do
  case $ARG in
    ticket=*) TICKET="${ARG#*=}"; shift ;; 
    packages=*) PACKAGES_ARG="${ARG#*=}"; shift ;; 
    repos=*) REPOS_ARG="${ARG#*=}"; shift ;; 
  esac
done

if [ -z "$PACKAGES_ARG" ] && [ -z "$REPOS_ARG" ]; then
  echo "Usage: $0 [repos=<repo1>,<repo2> | packages=<pkg1>,<pkg2>] [ticket=<ticket_number>]"
  echo "Example: $0 repos=job-a,job-b ticket=PPS-1234"
  exit 1
fi

# --- Capture Before State (Portable Method) ---
OLD_SUBMODULE_STATE=()
echo "Capturing current submodule state..."
while read -r commit path _; do
  repo_name=$(basename "$path")
  OLD_SUBMODULE_STATE+=("$repo_name:${commit#?}")
done < <(git submodule status)

# Helper function to get old commit from our stored list
get_old_commit() {
  local repo_name_to_find=$1
  for item in "${OLD_SUBMODULE_STATE[@]}"; do
    if [[ "$item" == "$repo_name_to_find:"* ]]; then
      echo "${item#*:}"
      return
    fi
  done
}

# --- Git Setup in Parent Repo ---
DEFAULT_BRANCH=""
for branch in "${BRANCHES[@]}"; do
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        DEFAULT_BRANCH="$branch"
        break
    fi
done

if [ -z "$DEFAULT_BRANCH" ]; then
  echo "Error: Could not find 'master' or 'main' branch in the local repository."
  exit 1
fi

echo "Checking out and updating base branch '$DEFAULT_BRANCH'..."
git checkout "$DEFAULT_BRANCH"
git pull
echo "Updating all submodules to commits specified in parent..."
git submodule update --init --recursive

# --- Determine Repos to Bump ---
REPOS_TO_BUMP_NAMES=()
INITIAL_DIR=$(pwd)

# Convert arg strings to arrays for easier checking
if [ -n "$REPOS_ARG" ]; then
  echo "Using 'repos' argument to select jobs."
  IFS=',' read -r -a REPOS_LIST <<< "$REPOS_ARG"
fi
if [ -n "$PACKAGES_ARG" ]; then
  echo "Using 'packages' argument to find jobs."
  IFS=',' read -r -a PACKAGES_LIST <<< "$PACKAGES_ARG"
fi

echo "Checking submodules for matching criteria..."
for job_path in jobs/*; do
  [ -d "$job_path" ] || continue
  repo_name=$(basename "$job_path")
  
  cd "$job_path" || continue
  
  SUBMODULE_DEFAULT_BRANCH=""
  for branch in "${BRANCHES[@]}"; do
      if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          SUBMODULE_DEFAULT_BRANCH="$branch"
          break
      fi
  done

  if [ -n "$SUBMODULE_DEFAULT_BRANCH" ]; then
      git checkout -q "$SUBMODULE_DEFAULT_BRANCH"
      git pull -q
  fi
  
  SHOULD_BUMP=false
  if [ -n "$REPOS_ARG" ]; then
    for r in "${REPOS_LIST[@]}"; do
      if [ "$r" == "$repo_name" ]; then SHOULD_BUMP=true; break; fi
    done
  elif [ -n "$PACKAGES_ARG" ]; then
    if [ -f "go.mod" ]; then
      for p in "${PACKAGES_LIST[@]}"; do
        pkg_base_name=$(echo "$p" | cut -d'@' -f1)
        if grep -q "$pkg_base_name" "go.mod"; then
          SHOULD_BUMP=true; break;
        fi
      done
    fi
  fi

  if $SHOULD_BUMP; then
    REPOS_TO_BUMP_NAMES+=("$repo_name")
  fi

  cd "$INITIAL_DIR"
done

if [ ${#REPOS_TO_BUMP_NAMES[@]} -eq 0 ]; then
  echo "No jobs found matching the criteria."
  exit 0
fi

echo "Found matching jobs: ${REPOS_TO_BUMP_NAMES[*]}"

# --- Create Branch ---
BRANCH_NAME="$TICKET-bump-jobs"
if [ ${#REPOS_TO_BUMP_NAMES[@]} -eq 1 ]; then
  BRANCH_NAME="$TICKET-bump-${REPOS_TO_BUMP_NAMES[0]}"
fi
git checkout -B "$BRANCH_NAME"

# --- Main Loop: Iterate and Update ---
UPDATED_REPOS_INFO=()
for repo_name in "${REPOS_TO_BUMP_NAMES[@]}"; do
  job_path="jobs/$repo_name"
  echo "--- Processing $repo_name ---"
  cd "$job_path" || continue

  # Add a short sleep to prevent rate-limiting
  sleep 1

  echo "Fetching updates from origin..."
  RETRY_COUNT=0
  MAX_RETRIES=15
  FETCH_SUCCESS=false
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    git fetch origin
    if [ $? -eq 0 ]; then
      FETCH_SUCCESS=true
      break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Warning: fetch failed for $repo_name. Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
    sleep 5
  done

  if ! $FETCH_SUCCESS; then
    echo "Error: Could not fetch from origin for $repo_name after $MAX_RETRIES attempts. Skipping."
    cd "$INITIAL_DIR"
    continue
  fi
  
  LATEST_TAG=$(git tag --sort=-creatordate | head -n 1)
  
  if [ -z "$LATEST_TAG" ]; then
      echo "Warning: No tags found for $repo_name. Skipping."
      cd "$INITIAL_DIR"
      continue
  fi

  echo "Checking out latest tag: $LATEST_TAG"
  git checkout -q "$LATEST_TAG"
  
  UPDATED_REPOS_INFO+=("$repo_name;$LATEST_TAG")
  cd "$INITIAL_DIR"
done

# --- Staging and Confirmation ---
if [ ${#UPDATED_REPOS_INFO[@]} -eq 0 ]; then
  echo "No repositories were successfully updated. Cleaning up..."
  git checkout "$DEFAULT_BRANCH"
  git branch -D "$BRANCH_NAME"
  exit 0
fi

# Construct the explicit git add command
GIT_ADD_COMMAND="git add"
for info in "${UPDATED_REPOS_INFO[@]}"; do
  repo_name=$(echo "$info" | cut -d';' -f1)
  GIT_ADD_COMMAND+=" jobs/$repo_name"
done

echo "Staging changes with: $GIT_ADD_COMMAND"
eval "$GIT_ADD_COMMAND"
if git diff --cached --quiet; then
  echo "No submodule changes detected after checkout. Cleaning up..."
  git checkout "$DEFAULT_BRANCH"
  git branch -D "$BRANCH_NAME"
  exit 0
fi

echo
echo "--- Review Changes ---"
echo "Found changes in ${#UPDATED_REPOS_INFO[@]} repositories."
echo "The following submodule changes are staged:"
PR_BODY_UPDATES=""
for info in "${UPDATED_REPOS_INFO[@]}"; do
  repo_name=$(echo "$info" | cut -d';' -f1)
  new_tag=$(echo "$info" | cut -d';' -f2)
  old_commit=$(get_old_commit "$repo_name")

  change_line=$(printf " * %-30s: %.12s -> %s" "$repo_name" "$old_commit" "$new_tag")
  PR_BODY_UPDATES+="$change_line"
done

echo

read -p "Do you want to commit, push, and create a PR? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborting. Cleaning up created branch..."
  git checkout -q "$DEFAULT_BRANCH"
  git branch -D "$BRANCH_NAME"
  echo "Cleanup complete. Submodule working directories have not been reset."
  exit 1
fi

# --- Final Commit and PR ---
PR_TITLE=""
if [ ${#UPDATED_REPOS_INFO[@]} -gt 1 ]; then
  PR_TITLE="[$TICKET] Bump multiple jobs"
else
  repo_name=$(echo "${UPDATED_REPOS_INFO[0]}" | cut -d';' -f1)
  new_tag=$(echo "${UPDATED_REPOS_INFO[0]}" | cut -d';' -f2)
  PR_TITLE="[$TICKET] Bump $repo_name to $new_tag"
fi

PR_BODY=$(cat <<EOF
https://priceline.atlassian.net/browse/$TICKET

Bumping job submodule(s) to their latest tags.

Updates:
\`\`\`
$PR_BODY_UPDATES
\`\`\`
EOF
)

echo "Committing, pushing, and creating PR..."
git commit -m "$PR_TITLE"
git push -u origin "$BRANCH_NAME"

gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH_NAME" \
  --web

echo "All done."
