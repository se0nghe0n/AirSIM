#!/usr/bin/env bash
# Calendar version and shared build number for every iOS target.
#
# Version: {ISO week-year, two digits}.{ISO week}.{N}. N counts uploads in that week, from 1.
# Build:   one CURRENT_PROJECT_VERSION that only increases, across versions, branches and Macs.
#
# Pushed annotated tags named ios/v<version>-<build> are the shared registry. `bump` commits
# iOS/Config/Version.xcconfig and pushes that commit and its tag atomically. When another Mac
# reserved the same version first, the push is rejected and the next number is computed again.
#
# Written for the macOS system bash 3.2: no associative arrays, no mapfile, and empty arrays
# are only expanded through ${array[@]+"${array[@]}"}.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: iOS/scripts/version.sh <show|next|bump> [--remote <name>] [--offline]

  show        print "<version> <build>" from iOS/Config/Version.xcconfig
  next        print the version and build `bump` would reserve now
  bump        reserve, commit and push the next version and build

  --remote    Git remote holding the shared version tags (default: origin)
  --offline   next: skip fetching the remote registry
EOF
}

readonly CONFIG=iOS/Config/Version.xcconfig
readonly PROJECT=iOS/AirSIM.xcodeproj/project.pbxproj
# Every Mac must agree on the week at midnight between Sunday and Monday.
readonly TIMEZONE=${AIRSIM_VERSION_TIMEZONE:-Asia/Seoul}
readonly ATTEMPTS=5

# Results are returned in globals: a function run in $(...) cannot abort the script reliably.
git_errors=/dev/null
work=""
parsed_version="" parsed_build=""
upstream=""
entries=()
week_year="" week_number=""
next_version="" next_build=""

die() {
  printf 'version.sh: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'version.sh: %s\n' "$*" >&2
  usage >&2
  exit 2
}

# Runs git and passes its stdout through. A failure is fatal and reports git's stderr.
git_checked() {
  if ! git "$@" 2>"$git_errors"; then
    die "git $* failed: $(<"$git_errors")"
  fi
}

# Reads xcconfig text from stdin and sets parsed_version and parsed_build from the last
# MARKETING_VERSION and CURRENT_PROJECT_VERSION assignments.
parse_config() {
  local line version="" build=""
  local pattern='^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$'
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $pattern ]]; then
      if [[ ${BASH_REMATCH[1]} == MARKETING_VERSION ]]; then
        version=${BASH_REMATCH[2]}
      else
        build=${BASH_REMATCH[2]}
      fi
    fi
  done
  if [[ -z $version || ! $build =~ ^[0-9]+$ ]]; then
    die "$CONFIG must set MARKETING_VERSION and an integer CURRENT_PROJECT_VERSION"
  fi
  parsed_version=$version
  parsed_build=$((10#$build))
}

parse_working_config() {
  [[ -f $CONFIG ]] || die "$CONFIG not found"
  parse_config <"$CONFIG"
}

# Appends one registry entry: "major minor patch build", or "- - - build" when the version is
# not calendar-shaped and only its build counts.
add_entry() {
  local version=$1 build=$2 pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
  if [[ $version =~ $pattern ]]; then
    entries+=("$((10#${BASH_REMATCH[1]})) $((10#${BASH_REMATCH[2]})) $((10#${BASH_REMATCH[3]})) $build")
  else
    entries+=("- - - $build")
  fi
}

# Adds the version and build committed at REF, if REF exists and carries them.
add_config_at() {
  local ref=$1 text version build
  if text=$(git show "$ref:$CONFIG" 2>/dev/null); then
    parse_config <<<"$text"
    add_entry "$parsed_version" "$parsed_build"
    return 0
  fi
  # Before Version.xcconfig existed, every target carried the numbers in the project file.
  text=$(git show "$ref:$PROJECT" 2>/dev/null) || text=""
  version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^[:space:]]+);.*/\1/p' <<<"$text" |
    LC_ALL=C sort | tail -n 1)
  build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' <<<"$text" |
    sort -n | tail -n 1)
  if [[ -n $version && -n $build ]]; then
    add_entry "$version" "$((10#$build))"
  fi
}

# Sets entries to every reserved release: tags fetched from the remote, plus the committed and
# local files for history before tags.
registry() {
  local remote=$1 tags tag pattern='^ios/v([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)$'
  entries=()
  tags=$(git_checked tag --list 'ios/v*')
  while IFS= read -r tag; do
    if [[ $tag =~ $pattern ]]; then
      entries+=("$((10#${BASH_REMATCH[1]})) $((10#${BASH_REMATCH[2]})) $((10#${BASH_REMATCH[3]})) $((10#${BASH_REMATCH[4]}))")
    fi
  done <<<"$tags"
  parse_working_config
  add_entry "$parsed_version" "$parsed_build"
  add_config_at HEAD
  add_config_at "$remote/main"
}

# Sets week_year (two digits) and week_number to the current ISO week in TIMEZONE.
this_week() {
  local zoneinfo=${TZDIR:-/usr/share/zoneinfo} now year week
  case "/$TIMEZONE/" in
    *//* | */./* | */../*) die "invalid time zone '$TIMEZONE'" ;;
  esac
  # An unknown TZ silently falls back to UTC, which would shift the week boundary.
  [[ -f $zoneinfo/$TIMEZONE ]] || die "unknown time zone '$TIMEZONE'"
  now=$(TZ=$TIMEZONE date '+%G %V')
  read -r year week <<<"$now"
  week_year=$((10#$year % 100))
  week_number=$((10#$week))
}

# True when "major minor patch" A sorts after B.
version_after() {
  local a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 <<<"$1"
  read -r b1 b2 b3 <<<"$2"
  ((a1 != b1 ? a1 > b1 : (a2 != b2 ? a2 > b2 : a3 > b3)))
}

# Sets next_version and next_build from entries and the current week.
next_release() {
  local entry major minor patch build
  local max_build=0 count=0 newest="" candidate
  this_week
  for entry in ${entries[@]+"${entries[@]}"}; do
    read -r major minor patch build <<<"$entry"
    if ((build > max_build)); then
      max_build=$build
    fi
    if [[ $major == - ]]; then
      continue
    fi
    if ((major == week_year && minor == week_number && patch > count)); then
      count=$patch
    fi
    if [[ -z $newest ]] || version_after "$major $minor $patch" "$newest"; then
      newest="$major $minor $patch"
    fi
  done
  candidate="$week_year $week_number $((count + 1))"
  if [[ -n $newest ]] && version_after "$newest" "$candidate"; then
    die "${newest// /.} is newer than this week's ${candidate// /.}; check this Mac's clock"
  fi
  next_version=${candidate// /.}
  next_build=$((max_build + 1))
}

write_config() {
  local version=$1 build=$2 updated=$work/Version.xcconfig
  sed -E \
    -e "s/^([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*)[^[:space:]]+/\\1$version/" \
    -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*)[^[:space:]]+/\\1$build/" \
    "$CONFIG" >"$updated"
  parse_config <"$updated"
  if [[ $parsed_version != "$version" || $parsed_build != "$build" ]]; then
    die "could not update $CONFIG"
  fi
  # Rewrite in place so the file keeps its mode.
  cat "$updated" >"$CONFIG"
}

require_single_source() {
  local overrides
  [[ -f $PROJECT ]] || die "$PROJECT not found"
  # Xcode's General tab writes target-level values that would silently override the xcconfig.
  overrides=$(sed -nE 's/^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)[[:space:]]*=.*/\1/p' "$PROJECT" |
    LC_ALL=C sort -u | paste -sd ',' -)
  if [[ -n $overrides ]]; then
    die "$PROJECT overrides ${overrides//,/, }; remove them so $CONFIG is the only source"
  fi
}

fetch_registry() {
  local remote=$1
  git_checked fetch --quiet --tags "$remote" >/dev/null
  git fetch --quiet "$remote" main >/dev/null 2>&1 || true
}

# Fetches the registry and BRANCH. Sets upstream to REMOTE/BRANCH, or empties it when the
# remote has no such branch yet.
fetch_branch() {
  local remote=$1 branch=$2
  upstream=""
  fetch_registry "$remote"
  if ! git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    return 0
  fi
  git_checked fetch --quiet "$remote" "$branch" >/dev/null
  upstream="$remote/$branch"
}

is_ancestor() {
  git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

sync_branch() {
  if [[ -z $upstream ]] || is_ancestor "$upstream" HEAD; then
    return 0
  fi
  if is_ancestor HEAD "$upstream"; then
    git_checked merge --quiet --ff-only "$upstream" >/dev/null
    return 0
  fi
  printf 'Rebasing local commits onto %s\n' "$upstream" >&2
  if ! git rebase --quiet "$upstream" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1 || true
    die "rebase onto $upstream failed; resolve it manually and run bump again"
  fi
}

# True when the remote now has TAG, or BRANCH no longer points at BASED_ON (empty when the
# branch did not exist). False when the remote cannot be listed.
push_raced() {
  local remote=$1 branch=$2 tag=$3 based_on=$4 listed sha name branch_sha=""
  if ! listed=$(git ls-remote "$remote" "refs/heads/$branch" "refs/tags/$tag" 2>/dev/null); then
    return 1
  fi
  while IFS=$'\t' read -r sha name; do
    if [[ $name == "refs/tags/$tag" ]]; then
      return 0
    fi
    if [[ $name == "refs/heads/$branch" ]]; then
      branch_sha=$sha
    fi
  done <<<"$listed"
  [[ $branch_sha != "$based_on" ]]
}

bump() {
  local remote=$1 changes branch attempt based_on tag reservation push_errors
  require_single_source
  changes=$(git_checked status --porcelain --untracked-files=no)
  if [[ -n $changes ]]; then
    die "commit or stash tracked changes first; the uploaded build must match its tag"
  fi
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
  if [[ -z $branch ]]; then
    die "check out a branch first; bump pushes the version commit to it"
  fi
  for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    fetch_branch "$remote" "$branch"
    sync_branch
    based_on=""
    if [[ -n $upstream ]]; then
      based_on=$(git_checked rev-parse "$upstream")
    fi
    registry "$remote"
    next_release
    tag="ios/v$next_version-$next_build"
    write_config "$next_version" "$next_build"
    git_checked add "$CONFIG" >/dev/null
    git_checked commit --quiet -m "chore: bump iOS version to $next_version ($next_build)" >/dev/null
    # A random line keeps each reservation a distinct tag object, so a racing Mac cannot
    # "succeed" by pushing an identical tag.
    reservation=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    git_checked tag -a "$tag" \
      -m "AirSIM iOS $next_version ($next_build)"$'\n\n'"reservation $reservation" >/dev/null
    if git push --atomic --quiet "$remote" "HEAD:refs/heads/$branch" "refs/tags/$tag" \
      >/dev/null 2>"$git_errors"; then
      printf '%s %s\n' "$next_version" "$next_build"
      return 0
    fi
    push_errors=$(<"$git_errors")
    git_checked tag -d "$tag" >/dev/null
    git_checked reset --quiet --keep HEAD~1 >/dev/null
    # Recompute only when another Mac moved the branch or took the tag meanwhile.
    # Authentication, network and policy failures are final.
    if ! push_raced "$remote" "$branch" "$tag" "$based_on"; then
      die "push to $remote failed: $push_errors"
    fi
    printf '%s was not accepted by %s; retrying\n' "$tag" "$remote" >&2
  done
  die "could not reserve a version after $ATTEMPTS attempts"
}

main() {
  local command="" remote=origin offline=0 root
  while [[ $# -gt 0 ]]; do
    case $1 in
      show | next | bump)
        [[ -z $command ]] || usage_error "unexpected argument '$1'"
        command=$1
        ;;
      --remote)
        [[ $# -ge 2 ]] || usage_error "--remote needs a value"
        remote=$2
        shift
        ;;
      --remote=*) remote=${1#--remote=} ;;
      --offline) offline=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unexpected argument '$1'" ;;
    esac
    shift
  done
  [[ -n $command ]] || usage_error "a command is required"

  root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel) ||
    die "cannot find the repository root"
  cd "$root"
  work=$(mktemp -d "${TMPDIR:-/tmp}/airsim-version.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  git_errors=$work/git-stderr

  case $command in
    show)
      parse_working_config
      printf '%s %s\n' "$parsed_version" "$parsed_build"
      ;;
    next)
      if ((offline == 0)); then
        fetch_registry "$remote"
      fi
      registry "$remote"
      next_release
      printf '%s %s\n' "$next_version" "$next_build"
      ;;
    bump) bump "$remote" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
