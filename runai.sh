# ~/.bash_functions/runai.sh
# RunAI helper functions
# Author: Etienne de Montalivet
# Loaded by ~/.bashrc


# Optional: source user-specific overrides if present (untracked file)
RUNAI_CONFIG_FILE="${RUNAI_CONFIG_FILE:-$HOME/.bash_functions/runai_config.sh}"
if [[ -f "$RUNAI_CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$RUNAI_CONFIG_FILE"
fi
# Default job prefix (can be overridden by exporting RUNAI_JOB_PREFIX)
: "${RUNAI_JOB_PREFIX:=$USER}"


rcp() {
    local job_name="${RUNAI_JOB_PREFIX}-$(date +"%y%m%d-%H%M%S")"
    echo "Launching job: $job_name"
    runai submit "$job_name" "$@"
}

alias rcp_interactive="rcp -i registry.rcp.epfl.ch/rcp-runai-upcourtine-klee/wyss_nvidia_pytorch_deps:latest           -e GIT_BRANCH_SYN_DECODER='dev'                     -e SSH_PRIVATE_KEY=SECRET:ssh-key-secret,id_rsa           -e USER='klee'           -e CACHE_DIR=/home/klee/nas/wyss/data/cache           -e SCRIPT_PATH='notebooks/charles/train_cyclegan.py'       --cpu 16 --memory 64G           --pvc upcourtine-scratch:/home/klee/nas:rw        --interactive --attach -g 1"

# runai_find_jobs - Search for RunAI jobs by name and filter by log content patterns
#
# DESCRIPTION:
#   Searches for RunAI jobs matching a name pattern and filters them by checking
#   if ALL specified log patterns exist in their logs (AND logic).
#   Optionally filters jobs by status *before* scanning logs (faster).
#   Optionally displays highlighted matching log lines.
#
# USAGE:
#   runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [OPTIONS]
#
# ARGUMENTS:
#   jobname_regex    - Regular expression to match job names (first column of 'runai list jobs')
#   log_pattern1..N  - One or more literal strings that MUST ALL appear in the job logs
#
# OPTIONS:
#   --status S, --status=S
#                    - Filter candidate jobs by status as reported by `runai list jobs`.
#                      Default: all
#                      Common values: running, pending, succeeded, terminating, containercreating
#                      Other values supported:
#                        deleted, timedout, preempted, containercannotrun, error, fail,
#                        crashloopbackoff, errimagepull, imagepullbackoff, unknown,
#                        podinitializing, init:error, init:crashloopbackoff, init:<a>/<b>
#                      Convenience:
#                        init:*   matches any Init:* status
#                        failed   is accepted as an alias of fail
#
#   --parallel N, -P N, --parallel=N, -P=N
#                    - Number of parallel jobs to check logs (default: 8)
#   --show           - Display highlighted matching log lines to stderr (for human viewing)
#   --debug          - Enable debug mode (currently unused)
#
# OUTPUT:
#   - Job names matching all criteria are printed to stdout (one per line)
#   - If --show is used, highlighted log excerpts are printed to stderr
#
# EXAMPLES:
#   # Find jobs starting with "training-" that contain "epoch" in logs
#   runai_find_jobs "^training-" "epoch"
#
#   # Only RUNNING jobs (filters before log scanning)
#   runai_find_jobs "^training-" "epoch" --status running
#
#   # Only SUCCEEDED jobs
#   runai_find_jobs "model-v2" "accuracy" "loss" --status succeeded
#
#   # Match any Init:* state (distributed jobs)
#   runai_find_jobs "^mpi-" "launcher" --status init:*
#
#   # Use 16 parallel workers for faster searching
#   runai_find_jobs "experiment-.*" "convergence" "validation" --parallel 16
#
#   # Pipe results to another command
#   runai_find_jobs "benchmark-" "completed" --status succeeded | delete_runai_jobs
#
# NOTES:
#   - All patterns must match (AND logic) for a job to be returned
#   - Patterns are literal strings (not regex) matched with grep -F
#   - ANSI color codes are stripped from 'runai list jobs' output
#   - Uses parallel execution for performance with multiple jobs
#   - Status matching is best-effort based on `runai list jobs` text output.
runai_find_jobs () {
  local job_filter="$1"; shift || true
  local parallelism=8
  local show=0
  local debug=0
  local status="all"

  if [[ -z "$job_filter" ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--status S] [--parallel N] [--show] [--debug]" >&2
    return 1
  fi

  local patterns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel|-P) shift; parallelism="${1:-8}"; shift || true ;;
      --parallel=*|-P=*) parallelism="${1#*=}"; shift ;;
      --status) shift; status="${1:-all}"; shift || true ;;
      --status=*) status="${1#*=}"; shift ;;
      --show) show=1; shift ;;
      --debug) debug=1; shift ;;
      *) patterns+=("$1"); shift ;;
    esac
  done

  if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--status S] [--parallel N] [--show] [--debug]" >&2
    return 1
  fi

  # Normalize status to lowercase for matching/validation
  status="${status,,}"
  # Convenience alias
  [[ "$status" == "failed" ]] && status="fail"

  case "$status" in
    all|any)
      ;;

    # Main lifecycle / common statuses
    running|pending|containercreating|terminating|succeeded|deleted|timedout|preempted|containercannotrun|error|fail|crashloopbackoff|unknown|errimagepull|imagepullbackoff)
      ;;

    # Distributed / init-related statuses (may appear as Init:<a>/<b>)
    podinitializing|init:error|init:crashloopbackoff|init:*)
      ;;

    # Accept specific init progress like init:1/3, init:2/5, etc.
    init:[0-9]*/[0-9]*)
      ;;

    *)
      echo "Error: invalid --status '$status'" >&2
      echo "Allowed (examples): all, running, pending, containercreating, terminating, succeeded, deleted, timedout, preempted," >&2
      echo "  containercannotrun, error, fail (or failed), crashloopbackoff, errimagepull, imagepullbackoff, unknown," >&2
      echo "  podinitializing, init:error, init:crashloopbackoff, init:<a>/<b>, init:*" >&2
      return 1
      ;;
  esac

  # Highlight regex for ALL patterns in show mode
  local highlight_regex
  highlight_regex="$(printf '%s|' "${patterns[@]}")"
  highlight_regex="${highlight_regex%|}"

  # Candidates: first column matches job_filter (+ optional status filter)
  local candidates
  candidates="$(
    runai list jobs 2>&1 \
      | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' \
      | awk -v name_pat="$job_filter" -v status="$status" '
          NR > 1 && $1 ~ name_pat {
            if (status == "all" || status == "any") { print $1; next }

            line_l = tolower($0)

            # init:* matches any Init:... token anywhere on the line
            if (status == "init:*") {
              if (index(line_l, "init:") > 0) { print $1; next }
            }

            # Exact field match first (works for RUNNING, SUCCEEDED, etc.)
            for (i = 1; i <= NF; i++) {
              if (tolower($i) == status) { print $1; next }
            }

            # Fallback substring match on the full line (covers init:1/3, init:error, etc.)
            if (index(line_l, status) > 0) { print $1; next }
          }
      '
  )"

  [[ -z "$candidates" ]] && return 0

  # Export config into env for the subshell (robust, avoids shift bugs)
  printf '%s\n' "$candidates" \
  | env RUNAI_FIND_JOBS_SHOW="$show" RUNAI_FIND_JOBS_REGEX="$highlight_regex" \
    xargs -r -P"$parallelism" -I{} bash -c '
      JOB="{}"

      show="${RUNAI_FIND_JOBS_SHOW:-0}"
      regex="${RUNAI_FIND_JOBS_REGEX:-}"

      LOGS="$(runai logs "$JOB" 2>&1)"

      for p in "$@"; do
        printf "%s\n" "$LOGS" | grep -Fq -- "$p" || exit 0
      done

      echo "$JOB"

      if [[ "$show" == "1" ]]; then
        {
          echo "===== $JOB ====="
          printf "%s\n" "$LOGS" | grep --color=always -E -- "$regex" || true
          echo
        } >&2
      fi
    ' _ "${patterns[@]}"
}


#######################################
# Delete all Run:AI jobs passed via stdin.
# Reads job names line by line from standard input and deletes each one using runai CLI.
# Requires the runai command to be available in PATH.
#
# Globals:
#   None
# Arguments:
#   None (reads from stdin)
# Outputs:
#   Writes status messages to stdout for each deletion
#   Writes error message to stdout if runai command not found
# Returns:
#   1 if runai command not found
#   0 otherwise
# Usage:
#   delete_runai_jobs < job_list.txt
#   echo "job-name" | delete_runai_jobs
#   runai list jobs | awk '{print $1}' | tail -n +2 | delete_runai_jobs
# Example:
#   # Delete jobs matching a pattern
#   runai list | grep "training-" | awk '{print $1}' | delete_runai_jobs
#######################################
delete_runai_jobs() {
  if ! command -v runai >/dev/null 2>&1; then
    echo "❌ runai command not found"
    return 1
  fi

  local count=0

  while IFS= read -r job; do
    # skip empty lines
    [[ -z "$job" ]] && continue

    echo "🗑️   Deleting job: $job"
    runai delete job "$job" && ((count++))
  done

  echo "✅ Deleted $count job(s)"
}


