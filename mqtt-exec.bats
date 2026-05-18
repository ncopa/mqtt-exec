#!/usr/bin/env bats

MQTT_EXEC="$BATS_TEST_DIRNAME/mqtt-exec"
MQTT_TEST="$BATS_TEST_DIRNAME/mqtt-test"
MQTT_TEST_HOST="${MQTT_TEST_HOST:-127.0.0.1}"
MQTT_TEST_PORT="${MQTT_TEST_PORT:-18884}"

mqtt_pub() {
	"$MQTT_TEST" pub -h "$MQTT_TEST_HOST" -p "$MQTT_TEST_PORT" "$@"
}

mqtt_sub() {
	"$MQTT_TEST" sub -h "$MQTT_TEST_HOST" -p "$MQTT_TEST_PORT" "$@"
}

init_broker_paths() {
	workdir="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}/mqtt-exec-test"
	pidfile="$workdir/mosquitto.pid"
	conffile="$workdir/mosquitto.conf"
	logfile="$workdir/mosquitto.log"
}

wait_for_broker() {
	init_broker_paths

	for _ in $(seq 0 100); do
		if mqtt_pub -t _mqtt_exec_probe -m ready >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.1
	done

	[ -f "$logfile" ] && cat "$logfile" >&2
	return 1
}

start_broker() {
	init_broker_paths
	mosquitto -c "$conffile" -d
	wait_for_broker
}

stop_broker() {
	init_broker_paths
	if [ -f "$pidfile" ]; then
		kill "$(cat "$pidfile")" 2>/dev/null || true
		wait "$(cat "$pidfile")" 2>/dev/null || true
		rm -f "$pidfile"
	fi
}

setup_file() {
	init_broker_paths
	rm -rf "$workdir"
	mkdir -p "$workdir"

	cat >"$conffile" <<EOF
listener $MQTT_TEST_PORT $MQTT_TEST_HOST
allow_anonymous true
persistence false
pid_file $pidfile
log_dest file $logfile
EOF

	start_broker
}

teardown_file() {
	init_broker_paths
	stop_broker

	rm -rf "$workdir"
}

setup() {
	topic="mqtt-exec/test/${BATS_TEST_NUMBER}.$$"
	output_file="$BATS_TEST_TMPDIR/payload.fifo"
	ready_fifo="$BATS_TEST_TMPDIR/ready.fifo"
	pid_file="$BATS_TEST_TMPDIR/mqtt-exec.pid"
	status_topic=
	rm -f "$output_file"
	rm -f "$ready_fifo"
}

teardown() {
	if [ -f "$pid_file" ]; then
		kill "$(cat "$pid_file")" 2>/dev/null || true
		wait "$(cat "$pid_file")" 2>/dev/null || true
	fi

	mqtt_pub -t "$topic" -n -r >/dev/null 2>&1 || true
	if [ -n "$status_topic" ]; then
		mqtt_pub -t "$status_topic" -n -r >/dev/null 2>&1 || true
	fi
}

make_fifo() {
	local path="$1"
	rm -f "$path"
	mkfifo "$path"
}

read_fifo() {
	local path="$1"
	local timeout_secs="${2:-5}"

	timeout "$timeout_secs" cat "$path"
}

read_fifo_lines() {
	local path="$1"
	local count="$2"
	local timeout_secs="${3:-5}"

	timeout "$timeout_secs" sh -c '
		path="$1"
		count="$2"
		exec 3<"$path"
		while [ "$count" -gt 0 ]; do
			IFS= read -r line <&3 || exit 1
			printf "%s\n" "$line"
			count=$((count - 1))
		done
	' sh "$path" "$count"
}

open_ready_channel() {
	local path="$1"

	make_fifo "$path"
	exec {READY_FD}<>"$path"
}

read_ready_fd() {
	local fd="$1"
	local timeout_secs="${2:-5}"

	timeout "$timeout_secs" bash -c 'IFS= read -r -u "$1" _' bash "$fd"
}

close_ready_fd() {
	local fd="$1"

	eval "exec ${fd}>&-"
	eval "exec ${fd}<&-"
}

wait_for_process_exit() {
	local pid="$1"
	local tries="${2:-15}"

	while [ "$tries" -gt 0 ]; do
		if ! kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		sleep 0.2
		tries=$((tries - 1))
	done

	return 1
}

start_single_message_subscriber() {
	local topic="$1"
	local output_path="$2"
	local ready_fifo="${output_path}.ready"
	local ready_fd

	rm -f "$output_path"
	open_ready_channel "$ready_fifo"
	ready_fd="$READY_FD"
	mqtt_sub -C 1 -t "$topic" --ready-fd "$ready_fd" >"$output_path" &
	SUB_PID=$!
	read_ready_fd "$ready_fd" >/dev/null || {
		close_ready_fd "$ready_fd"
		rm -f "$ready_fifo"
		kill "$SUB_PID" 2>/dev/null || true
		wait "$SUB_PID" 2>/dev/null || true
		return 1
	}
	close_ready_fd "$ready_fd"
	rm -f "$ready_fifo"
}

assert_single_message() {
	local sub_pid="$1"
	local output_path="$2"
	local expected="$3"
	local output

	wait "$sub_pid" 2>/dev/null || true
	output="$(cat "$output_path")" || {
		kill "$sub_pid" 2>/dev/null || true
		wait "$sub_pid" 2>/dev/null || true
		return 1
	}
	[ "$output" = "$expected" ]
}

wait_for_mqtt_exec_ready() {
	open_ready_channel "$ready_fifo"
}

consume_mqtt_exec_ready() {
	local ready_fd="$1"

	read_ready_fd "$ready_fd" >/dev/null || {
		close_ready_fd "$ready_fd"
		rm -f "$ready_fifo"
		return 1
	}
	close_ready_fd "$ready_fd"
	rm -f "$ready_fifo"
}

@test "--version prints the program version" {
	run "$MQTT_EXEC" --version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^mqtt-exec[[:space:]][0-9] ]]
}

@test "rejects invalid QoS values" {
	run "$MQTT_EXEC" -q 3 -t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[ "$output" = "3: QoS out of range" ]
}

@test "rejects invalid will QoS values" {
	run "$MQTT_EXEC" --will-qos 3 -t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[ "$output" = "3: will QoS out of range" ]
}

@test "rejects invalid status QoS values" {
	run "$MQTT_EXEC" --status-topic "$topic/state" --status-qos 3 \
		-t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[ "$output" = "3: status QoS out of range" ]
}

@test "requires both username and password" {
	run "$MQTT_EXEC" -u user -t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[ "$output" = "Need to set both username and password" ]
}

@test "accepts password from MQTT_EXEC_PASSWORD" {
	MQTT_EXEC_PASSWORD=secret run "$MQTT_EXEC" -u user --version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^mqtt-exec[[:space:]][0-9] ]]
}

@test "requires a status topic when using status options" {
	run "$MQTT_EXEC" --status-up-payload online --status-down-payload offline \
		--status-qos 1 --status-retain -t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[ "$output" = "Need to set status topic when using status options" ]
}

@test "rejects an overly long client id" {
	long_id="abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
	run "$MQTT_EXEC" -i "$long_id" -t "$topic" -- /bin/true
	[ "$status" -eq 1 ]
	[[ "$output" =~ ^specified\ id\ is\ longer\ than\ [0-9]+\ chars$ ]]
}

@test "requires at least one topic" {
	run "$MQTT_EXEC" -- /bin/true
	[ "$status" -eq 2 ]
	[[ "$output" =~ ^mqtt-exec\ -\ execute\ command\ on\ mqtt\ messages ]]
}

@test "requires a command after the topic" {
	run "$MQTT_EXEC" -t "$topic"
	[ "$status" -eq 2 ]
	[[ "$output" =~ ^mqtt-exec\ -\ execute\ command\ on\ mqtt\ messages ]]
}

@test "verbose mode passes topic and payload" {
	wait_for_mqtt_exec_ready
	ready_fd="$READY_FD"
	make_fifo "$output_file"
	script='printf "%s\n%s" "${1-unset}" "${2-unset}" > "'"$output_file"'"'
	"$MQTT_EXEC" -v \
		-h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--ready-fd "$ready_fd" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	consume_mqtt_exec_ready "$ready_fd"

	run mqtt_pub -t "$topic" -m "hello verbose"
	[ "$status" -eq 0 ]

	run read_fifo "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n%s' "$topic" "hello verbose")" ]
}

@test "verbose mode executes for an empty payload and passes the topic" {
	wait_for_mqtt_exec_ready
	ready_fd="$READY_FD"
	make_fifo "$output_file"
	script='printf "%s\n%s" "${1-unset}" "${2-unset}" > "'"$output_file"'"'
	"$MQTT_EXEC" -v \
		-h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--ready-fd "$ready_fd" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	consume_mqtt_exec_ready "$ready_fd"

	run mqtt_pub -t "$topic" -n
	[ "$status" -eq 0 ]

	run read_fifo "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\nunset' "$topic")" ]
}

@test "executes a command for a live message from the broker" {
	wait_for_mqtt_exec_ready
	ready_fd="$READY_FD"
	make_fifo "$output_file"
	script='printf "%s" "$1" > "'"$output_file"'"'
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--ready-fd "$ready_fd" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	consume_mqtt_exec_ready "$ready_fd"

	run mqtt_pub -t "$topic" -m "live message"
	[ "$status" -eq 0 ]

	run read_fifo "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "live message" ]
}

@test "subscribes to multiple topics" {
	topic2="${topic}/second"
	wait_for_mqtt_exec_ready
	ready_fd="$READY_FD"
	collector_fifo="$BATS_TEST_TMPDIR/collector.fifo"
	output_path="$BATS_TEST_TMPDIR/multi-topic.out"
	make_fifo "$collector_fifo"
	rm -f "$output_path"
	exec 8<>"$collector_fifo"
	read_fifo_lines "$collector_fifo" 2 >"$output_path" &
	relay_pid=$!
	script='printf "%s\n" "$1" > "'"$collector_fifo"'"'
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-t "$topic2" \
		--ready-fd "$ready_fd" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	consume_mqtt_exec_ready "$ready_fd"

	run mqtt_pub -t "$topic" -m "first topic"
	[ "$status" -eq 0 ]

	run mqtt_pub -t "$topic2" -m "second topic"
	[ "$status" -eq 0 ]

	wait "$relay_pid"
	exec 8>&-
	exec 8<&-

	run sort "$output_path"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n%s' "first topic" "second topic")" ]
}

@test "executes a command for a retained message from the broker" {
	run mqtt_pub -t "$topic" -m "hello world" -r
	[ "$status" -eq 0 ]

	make_fifo "$output_file"
	script="printf '%s' \"\$1\" > '$output_file'"
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	run read_fifo "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "hello world" ]
}

@test "publishes the configured status message after reconnect" {
	status_topic="${topic}/state"
	first_status="$BATS_TEST_TMPDIR/status-first.$$"
	start_single_message_subscriber "$status_topic" "$first_status"
	first_sub_pid="$SUB_PID"

	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--status-topic "$status_topic" \
		--status-up-payload online \
		--status-retain \
		-- /bin/true &
	echo $! > "$pid_file"

	assert_single_message "$first_sub_pid" "$first_status" "online"

	stop_broker
	start_broker

	run mqtt_sub -W 10 -C 1 -t "$status_topic"
	[ "$status" -eq 0 ]
	[ "$output" = "online" ]
}

@test "publishes an empty up status when only status topic is set" {
	status_topic="${topic}/state"
	status_path="$BATS_TEST_TMPDIR/status-empty.$$"
	start_single_message_subscriber "$status_topic" "$status_path"
	status_sub_pid="$SUB_PID"

	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--status-topic "$status_topic" \
		-- /bin/true &
	echo $! > "$pid_file"

	assert_single_message "$status_sub_pid" "$status_path" ""
}

@test "publishes the configured down status on clean shutdown" {
	status_topic="${topic}/state"
	up_path="$BATS_TEST_TMPDIR/status-up.$$"
	down_path="$BATS_TEST_TMPDIR/status-down.$$"
	start_single_message_subscriber "$status_topic" "$up_path"
	up_sub_pid="$SUB_PID"

	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--status-topic "$status_topic" \
		--status-up-payload online \
		--status-down-payload offline \
		-- /bin/true &
	echo $! > "$pid_file"

	assert_single_message "$up_sub_pid" "$up_path" "online"

	start_single_message_subscriber "$status_topic" "$down_path"
	down_sub_pid="$SUB_PID"

	kill -TERM "$(cat "$pid_file")"
	wait_for_process_exit "$(cat "$pid_file")"
	wait "$(cat "$pid_file")" 2>/dev/null || true
	rm -f "$pid_file"

	assert_single_message "$down_sub_pid" "$down_path" "offline"
}

@test "publishes the will payload on unclean disconnect without status options" {
	will_topic="${topic}/will"
	will_path="$BATS_TEST_TMPDIR/will-only.$$"

	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--will-topic "$will_topic" \
		--will-payload failed \
		-- /bin/true &
	echo $! > "$pid_file"

	open_ready_channel "$will_path.ready"
	ready_fd="$READY_FD"
	mqtt_sub -C 1 -t "$will_topic" --ready-fd "$ready_fd" >"$will_path" &
	sub_pid=$!
	read_ready_fd "$ready_fd" >/dev/null
	close_ready_fd "$ready_fd"
	rm -f "$will_path.ready"

	kill -KILL "$(cat "$pid_file")"
	wait "$(cat "$pid_file")" 2>/dev/null || true
	rm -f "$pid_file"

	wait "$sub_pid"
	run cat "$will_path"
	[ "$status" -eq 0 ]
	[ "$output" = "failed" ]
}

@test "keeps clean shutdown status separate from the will payload" {
	status_topic="${topic}/state"
	will_topic="${topic}/will"
	up_path="$BATS_TEST_TMPDIR/status-up.$$"
	will_path="$BATS_TEST_TMPDIR/will.$$"
	start_single_message_subscriber "$status_topic" "$up_path"
	up_sub_pid="$SUB_PID"

	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		--status-topic "$status_topic" \
		--status-up-payload online \
		--status-down-payload offline \
		--will-topic "$will_topic" \
		--will-payload failed \
		-- /bin/true &
	echo $! > "$pid_file"

	assert_single_message "$up_sub_pid" "$up_path" "online"

	open_ready_channel "$will_path.ready"
	ready_fd="$READY_FD"
	mqtt_sub -C 1 -t "$will_topic" --ready-fd "$ready_fd" >"$will_path" &
	sub_pid=$!
	read_ready_fd "$ready_fd" >/dev/null
	close_ready_fd "$ready_fd"
	rm -f "$will_path.ready"

	kill -KILL "$(cat "$pid_file")"
	wait "$(cat "$pid_file")" 2>/dev/null || true
	rm -f "$pid_file"

	wait "$sub_pid"
	run cat "$will_path"
	[ "$status" -eq 0 ]
	[ "$output" = "failed" ]
}
