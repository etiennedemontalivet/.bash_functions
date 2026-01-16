# ~/.bash_functions/runai.sh
# RunAI helper functions
# Author: Etienne de Montalivet
# Loaded by ~/.bashrc
rcp() {
    local job_name="etienne-$(date +"%y%m%d-%H%M%S")"
    echo "Launching job: $job_name"
    runai submit "$job_name" "$@"
}

alias rcp_interactive="rcp -i registry.rcp.epfl.ch/rcp-runai-upcourtine-klee/wyss_nvidia_pytorch_deps:latest           -e GIT_BRANCH_SYN_DECODER='dev'                     -e SSH_PRIVATE_KEY=SECRET:ssh-key-secret,id_rsa           -e USER='klee'           -e CACHE_DIR=/home/klee/nas/wyss/data/cache           -e SCRIPT_PATH='notebooks/charles/train_cyclegan.py'       --cpu 16 --memory 64G           --pvc upcourtine-scratch:/home/klee/nas:rw        --interactive --attach -g 1"

runai_find_jobs () {
  local job_filter="$1"; shift || true
  local parallelism=8
  local show_pat=""
  local debug=0

  if [[ -z "$job_filter" ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--show PATTERN] [--debug]" >&2
    return 1
  fi

  local patterns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel|-P) shift; parallelism="${1:-8}"; shift || true ;;
      --parallel=*|-P=*) parallelism="${1#*=}"; shift ;;
      --show) shift; show_pat="${1:-}"; shift || true ;;
      --show=*) show_pat="${1#*=}"; shift ;;
      --debug) debug=1; shift ;;
      *) patterns+=("$1"); shift ;;
    esac
  done

  if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--show PATTERN] [--debug]" >&2
    return 1
  fi

  # Candidate jobs
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
        dbg="$1"; shift
        show_pat="$1"; shift

        # Check ALL patterns exist (AND semantics)
        for p in "$@"; do
          runai logs "$JOB" 2>&1 | grep -Fq -- "$p" || exit 0
        done

        if [[ -n "$show_pat" ]]; then
          echo "===== $JOB ====="
          runai logs "$JOB" 2>&1 | grep -F --color=always -- "$show_pat"
        else
          echo "$JOB"
        fi
      ' _ "$debug" "$show_pat" "${patterns[@]}"
}


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


