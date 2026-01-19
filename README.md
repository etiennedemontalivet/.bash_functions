# .bash_functions

## Installation

Add the following to your `~/.bashrc`:

```bash
for f in ~/.bash_functions/*.sh; do [ -f "$f" ] && source "$f"; done
```
Or use this one-liner to add it automatically:

```bash
echo 'for f in ~/.bash_functions/*.sh; do [ -f "$f" ] && source "$f"; done' >> ~/.bashrc
```

## Configuration (optional, recommended)

Create a user-specific config file (this will NOT be tracked by git):

```bash
echo 'export RUNAI_JOB_PREFIX="$USER"' > ~/.bash_functions/runai_config.sh
```


## runai commands

### `rcp`
Submits a Run:AI job with an auto-generated name of the form "${RUNAI_JOB_PREFIX}-YYMMDD-HHMMSS" and forwards all additional arguments to runai submit.
Usage:
```bash
rcp [runai submit options and arguments]
```

### `runai_find_jobs`
Searches for Run:AI jobs whose names match a given regular expression and returns only those whose logs contain ALL specified literal patterns (AND logic). Optionally prints highlighted matching log lines to stderr and supports parallel log scanning.
Usage:
```bash
runai_find_jobs <jobname_regex> <log_pattern1> [log_pattern2 ...] [--parallel N | -P N | --parallel=N | -P=N] [--show] [--debug]
```

### `delete_runai_jobs`
Deletes Run:AI jobs listed on standard input, one job name per line. Requires the runai CLI. Prints a status line for each deletion and a summary count on completion.
Usage:
```bash
runai list | grep "training-" | awk '{print $1}' | delete_runai_jobs
```
