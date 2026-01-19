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
#   if ALL specified log patterns exist in their logs (AND logic). Optionally
#   displays highlighted matching log lines.
#
# USAGE:
#   runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [OPTIONS]
#
# ARGUMENTS:
#   jobname_regex    - Regular expression to match job names (first column of 'runai list jobs')
#   log_pattern1..N  - One or more literal strings that MUST ALL appear in the job logs
#
# OPTIONS:
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
#   # Find jobs with "model-v2" in name containing both "accuracy" AND "loss" in logs
#   runai_find_jobs "model-v2" "accuracy" "loss"
#
#   # Same as above, but also display highlighted log lines to terminal
#   runai_find_jobs "model-v2" "accuracy" "loss" --show
#
#   # Use 16 parallel workers for faster searching
#   runai_find_jobs "experiment-.*" "convergence" "validation" --parallel 16
#
#   # Pipe results to another command
#   runai_find_jobs "benchmark-" "completed" | delete_runai_jobs
#
# NOTES:
#   - All patterns must match (AND logic) for a job to be returned
#   - Patterns are literal strings (not regex) matched with grep -F
#   - ANSI color codes are stripped from 'runai list jobs' output
#   - Uses parallel execution for performance with multiple jobs
runai_find_jobs () {
  local job_filter="$1"; shift || true
  local parallelism=8
  local show=0
  local debug=0

  if [[ -z "$job_filter" ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--show] [--debug]" >&2
    return 1
  fi

  local patterns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel|-P) shift; parallelism="${1:-8}"; shift || true ;;
      --parallel=*|-P=*) parallelism="${1#*=}"; shift ;;
      --show) show=1; shift ;;
      --debug) debug=1; shift ;;
      *) patterns+=("$1"); shift ;;
    esac
  done

  if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--show] [--debug]" >&2
    return 1
  fi

  # Highlight regex for ALL patterns in show mode
  local highlight_regex
  highlight_regex="$(printf '%s|' "${patterns[@]}")"
  highlight_regex="${highlight_regex%|}"

  # Candidates: first column matches job_filter
  local candidates
  candidates="$(
    runai list jobs 2>&1 \
      | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' \
      | awk -v pat="$job_filter" '$1 ~ pat {print $1}'
  )"

  [[ -z "$candidates" ]] && return 0

  printf '%s\n' "$candidates" \
    | xargs -r -P"$parallelism" -I{} bash -c '
        JOB="{}"; shift
        show="$1"; shift
        regex="$1"; shift

        # Check ALL patterns exist (AND)
        for p in "$@"; do
          runai logs "$JOB" 2>&1 | grep -Fq -- "$p" || exit 0
        done

        # Always print job name to STDOUT (safe for piping)
        echo "$JOB"

        # If requested, also print highlighted matching lines to STDERR
        if [[ "$show" -eq 1 ]]; then
          {
            echo "===== $JOB ====="
            runai logs "$JOB" 2>&1 | grep --color=always -E -- "$regex"
            echo
          } >&2
        fi
      ' _ "$show" "$highlight_regex" "${patterns[@]}"
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


