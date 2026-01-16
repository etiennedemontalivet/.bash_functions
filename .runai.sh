# RCP / RUNAI
rcp() {
    local job_name="etienne-$(date +"%y%m%d-%H%M%S")"
    echo "Launching job: $job_name"
    runai submit "$job_name" "$@"
}

alias rcp_interactive="rcp -i registry.rcp.epfl.ch/rcp-runai-upcourtine-klee/wyss_nvidia_pytorch_deps:latest           -e GIT_BRANCH_SYN_DECODER='dev'                     -e SSH_PRIVATE_KEY=SECRET:ssh-key-secret,id_rsa           -e USER='klee'           -e CACHE_DIR=/home/klee/nas/wyss/data/cache           -e SCRIPT_PATH='notebooks/charles/train_cyclegan.py'       --cpu 16 --memory 64G           --pvc upcourtine-scratch:/home/klee/nas:rw        --interactive --attach -g 1"


runai_find_jobs () {
  local job_filter="$1"; shift || true
  local parallelism=8
  local list_all=0

  if [[ -z "$job_filter" ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--all]" >&2
    return 1
  fi

  local patterns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel|-P) shift; parallelism="${1:-8}"; shift || true ;;
      --parallel=*|-P=*) parallelism="${1#*=}"; shift ;;
      --all) list_all=1; shift ;;
      *) patterns+=("$1"); shift ;;
    esac
  done

  if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "Usage: runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N] [--all]" >&2
    return 1
  fi

  # Adjust this if your RunAI uses a different "show all jobs" flag:
  local list_cmd=(runai list jobs)
  if [[ "$list_all" -eq 1 ]]; then
    list_cmd+=(--all)
  fi

  "${list_cmd[@]}" \
    | awk -v pat="$job_filter" 'NR>1 && $1 ~ pat {print $1}' \
    | xargs -r -n1 -P"$parallelism" bash -c '
        job="$1"; shift

        # Capture BOTH stdout+stderr to avoid missing logs if they go to stderr
        logs="$(runai logs "$job" 2>&1)" || exit 0

        for p in "$@"; do
          printf "%s" "$logs" | grep -Fq -- "$p" || exit 0
        done

        echo "$job"
      ' _ {} "${patterns[@]}"
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


