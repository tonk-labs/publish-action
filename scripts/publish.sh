#!/usr/bin/env bash
# Join the space with the agent connection link, then `tonk eval` the
# directory and report the outcome as step outputs.
#
# Everything tonk stores (the connection's credentials, the replica) lives
# under a fresh directory in RUNNER_TEMP and is removed on exit, so nothing
# carries over to later steps or jobs.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

invite="${TONK_INVITE:-}"
directory="${PUBLISH_DIRECTORY:-tonk}"
branch="${PUBLISH_BRANCH:-main}"
attempts="${PUBLISH_ATTEMPTS:-5}"
dry_run="${PUBLISH_DRY_RUN:-false}"
agent_name="${PUBLISH_AGENT_NAME:-}"

[ -n "$invite" ] || fail "invite is required: pass the agent connection link from a secret"
echo "::add-mask::$invite"

# Agent connections are granted the `main` branch alone, and the CLI tracks
# only `main`. Refuse anything else up front rather than fail on the access
# service's rejection after joining.
[ "$branch" = main ] ||
  fail "branch '$branch' is not supported yet: agent connections can only publish to main"

[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || fail "attempts must be a positive integer (got '$attempts')"
case "$dry_run" in
  true | false) ;;
  *) fail "dry-run must be true or false (got '$dry_run')" ;;
esac

root="${GITHUB_WORKSPACE:-$PWD}"
case "$directory" in
  /*) source_dir="$directory" ;;
  *) source_dir="$root/$directory" ;;
esac
[ -d "$source_dir" ] || fail "directory '$directory' does not exist"

repository="${GITHUB_REPOSITORY:-local}"
[ -n "$agent_name" ] || agent_name="GitHub Actions ($repository)"

# Every run joins from scratch. A stable installation identity makes each
# run's connection receipt the same fact, so a run that publishes nothing
# new commits nothing, instead of recording one installation per run.
installation="$(printf 'github-actions:%s' "$repository" | sha256sum | cut -c1-32)"

state="$(mktemp -d "${RUNNER_TEMP:-/tmp}/tonk-publish.XXXXXX")"
trap 'rm -rf "$state"' EXIT
export XDG_DATA_HOME="$state/data"
export TONK_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME" "$state/work"

space=tonk-publish
echo "::group::Join the space"
(cd "$state/work" && tonk join "$invite" \
  --name "$space" \
  --agent-name "$agent_name" \
  --installation "$installation")
echo "::endgroup::"

# Which files count and in what order is this action's convention, not
# tonk's: every *.yaml / *.yml under the directory, hidden entries skipped,
# sorted by path so `00-schema.yaml` runs before the documents using it.
mapfile -d '' documents < <(
  cd "$source_dir" &&
    find . -name '.?*' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 |
    LC_ALL=C sort -z
)
[ "${#documents[@]}" -gt 0 ] || fail "no *.yaml or *.yml documents under '$directory'"
for i in "${!documents[@]}"; do
  documents[i]="$source_dir/${documents[i]#./}"
done

flags=(--json --quiet --no-sync)
[ "$dry_run" = true ] && flags+=(--dry-run)

# One commit for all of them, in that order, against the replica the join just
# pulled. Syncing is done below, where its failures fail the step.
echo "::group::Evaluate $directory"
printf '%s\n' "${documents[@]#"$source_dir"/}"
tonk --space "$space" eval "${documents[@]}" "${flags[@]}" >"$state/outcome.json"
echo "::endgroup::"
changed="$(jq -r 'if .revision_before == .revision_after then "false" else "true" end' "$state/outcome.json")"

# Deliver. Pull first, merging whatever others wrote since the join, then
# push. A push refused because the branch moved again exits with tonk's
# commit-error code (3); pull and push again for that, and fail at once on
# anything else (network, authority), which exits with another code.
pushed=false
if [ "$dry_run" = false ] && [ "$changed" = true ]; then
  echo "::group::Push"
  attempt=1
  while :; do
    tonk --space "$space" pull
    status=0
    tonk --space "$space" push || status=$?
    [ "$status" -eq 0 ] && break
    if [ "$status" -ne 3 ] || [ "$attempt" -ge "$attempts" ]; then
      fail "the documents were committed but could not be pushed (exit $status, attempt $attempt of $attempts)"
    fi
    attempt=$((attempt + 1))
    echo "the branch moved; pulling and pushing again"
  done
  echo "::endgroup::"
  pushed=true
fi
{
  echo "changed=$changed"
  echo "pushed=$pushed"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"

if [ "$dry_run" = true ]; then
  summary="Dry run: every document evaluated, nothing committed."
elif [ "$pushed" = true ]; then
  summary="Published \`$directory\` to the space."
else
  summary="Nothing to publish: the space already holds \`$directory\`."
fi
echo "$summary"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$summary" >>"$GITHUB_STEP_SUMMARY"
