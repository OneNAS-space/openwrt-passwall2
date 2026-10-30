#!/bin/sh

. /usr/share/passwall2/utils.sh
LOCK_FILE=${LOCK_PATH}/${CONFIG}_monitor.lock

ENABLED=$(config_n_get @global[0] enabled 0)
[ "$ENABLED" != 1 ] && return 1
ENABLED=$(config_n_get @global_delay[0] start_daemon 0)
[ "$ENABLED" != 1 ] && return 1

# Fail-open: if a core (xray/sing-box) cannot be brought back after MAX_RETRY
# restarts in a row, stop PassWall2 so traffic goes direct again instead of
# being redirected to a dead process.
MAX_RETRY=3
RETRY_WAIT=10

is_running() {
	local cmd_check escape_cmd
	cmd_check=$(echo $1 | awk -F '>' '{print $1}')
	escape_cmd="$(echo $cmd_check | sed 's/[^a-zA-Z0-9]/\\&/g')"
	[ "$(busybox pgrep -f "${escape_cmd}" | wc -l)" != 0 ]
}

run_cmd() {
	eval $(echo "nohup ${1} 2>&1 &") >/dev/null 2>&1 &
}

sleep 58s
while [ "$ENABLED" -eq 1 ]; do
	[ -f "$LOCK_FILE" ] && {
		sleep 6s
		continue
	}
	touch $LOCK_FILE
	[ -d ${TMP_SCRIPT_FUNC_PATH} ] && {
		for filename in $(ls ${TMP_SCRIPT_FUNC_PATH} | grep -v "^_"); do
			cmd=$(cat ${TMP_SCRIPT_FUNC_PATH}/${filename})
			is_running "$cmd" && continue
			log 0 "${cmd} crashed, restarting."
			run_cmd "$cmd"
			echo "$cmd" | grep -qE '(^|/)(xray|sing-box) ' || continue
			try=1
			sleep $RETRY_WAIT
			while ! is_running "$cmd"; do
				if [ "$try" -ge "$MAX_RETRY" ]; then
					log 0 "${cmd} failed to restart ${MAX_RETRY} times, stopping PassWall2 to restore direct access."
					rm -f $LOCK_FILE
					( /etc/init.d/${CONFIG} stop >/dev/null 2>&1 & )
					exit 0
				fi
				try=$((try + 1))
				log 0 "${cmd} is still not running, retry ${try}/${MAX_RETRY}."
				run_cmd "$cmd"
				sleep $RETRY_WAIT
			done
		done
	}

	rm -f $LOCK_FILE
	sleep 58s
done
