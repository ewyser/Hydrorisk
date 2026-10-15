#!/bin/bash
# run-daemon.sh COMMAND [ARGS...]
#
# Runs the daemon (COMMAND: `julia ... Daemon.run()`) so that stopping the
# container stops it cleanly.
#
# `docker stop` / `docker compose stop` send SIGTERM, which runuser (PID 1,
# see entrypoint.sh) passes on to its child. Julia has no SIGTERM handler: it
# would die at once - workers orphaned, running jobs left `in-progress`,
# claimed jobs left `fetched`/`pending`. SIGINT instead becomes an
# InterruptException in Daemon.run, whose shutdown marks the running jobs
# failed, gives the claimed ones back to the queue and removes the workers.
# So this script sits between runuser and Julia and turns SIGTERM into SIGINT,
# sent to Julia alone (its workers are stopped by the daemon itself).
#
# (Sending SIGINT to runuser instead does not work: runuser answers it by
# killing its child outright.)

# Job control: without it, a non-interactive bash starts background commands
# with SIGINT ignored - Julia would never receive it
set -m

"$@" &
pid=$!
trap 'kill -INT "$pid" 2>/dev/null' TERM INT

# `wait` returns as soon as a trapped signal arrives: wait again until the
# daemon has actually exited, and exit with its status
wait "$pid"; status=$?
while kill -0 "$pid" 2>/dev/null; do
    wait "$pid"; status=$?
done
exit "$status"
