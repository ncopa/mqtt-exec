#!/usr/bin/env bats

MQTT_EXEC="$BATS_TEST_DIRNAME/mqtt-exec"
MQTT_TEST_HOST="${MQTT_TEST_HOST:-127.0.0.1}"
MQTT_TEST_PORT="${MQTT_TEST_PORT:-18884}"

init_broker_paths() {
	workdir="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}/mqtt-exec-test"
	pidfile="$workdir/mosquitto.pid"
	conffile="$workdir/mosquitto.conf"
	logfile="$workdir/mosquitto.log"
}

wait_for_broker() {
	init_broker_paths

	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if mosquitto_pub -h "$MQTT_TEST_HOST" -p "$MQTT_TEST_PORT" \
			-t _mqtt_exec_probe -m ready >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
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
	output_file="$BATS_TEST_TMPDIR/payload"
	pid_file="$BATS_TEST_TMPDIR/mqtt-exec.pid"
	status_topic=
}

teardown() {
	if [ -f "$pid_file" ]; then
		kill "$(cat "$pid_file")" 2>/dev/null || true
		wait "$(cat "$pid_file")" 2>/dev/null || true
	fi

	mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-n -r >/dev/null 2>&1 || true
	if [ -n "$status_topic" ]; then
		mosquitto_pub -h "$MQTT_TEST_HOST" \
			-p "$MQTT_TEST_PORT" \
			-t "$status_topic" \
			-n -r >/dev/null 2>&1 || true
	fi
}

wait_for_file() {
	local path="$1"
	local tries=15

	while [ "$tries" -gt 0 ]; do
		[ -f "$path" ] && return 0
		sleep 0.2
		tries=$((tries - 1))
	done

	return 1
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

	rm -f "$output_path"
	mosquitto_sub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-C 1 \
		-t "$topic" >"$output_path" &
	SUB_PID=$!
}

assert_single_message() {
	local sub_pid="$1"
	local output_path="$2"
	local expected="$3"
	local tries="${4:-15}"
	if ! wait_for_process_exit "$sub_pid" "$tries"; then
		kill "$sub_pid" 2>/dev/null || true
		wait "$sub_pid" 2>/dev/null || true
		return 1
	fi

	wait "$sub_pid" 2>/dev/null || true
	run cat "$output_path"
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
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
	script="printf '%s\n%s' \"\${1-unset}\" \"\${2-unset}\" > '$output_file'"
	"$MQTT_EXEC" -v \
		-h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	sleep 0.2

	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-m "hello verbose"
	[ "$status" -eq 0 ]

	wait_for_file "$output_file"

	run cat "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n%s' "$topic" "hello verbose")" ]
}

@test "verbose mode executes for an empty payload and passes the topic" {
	script="printf '%s\n%s' \"\${1-unset}\" \"\${2-unset}\" > '$output_file'"
	"$MQTT_EXEC" -v \
		-h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	sleep 0.2

	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-n
	[ "$status" -eq 0 ]

	wait_for_file "$output_file"

	run cat "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\nunset' "$topic")" ]
}

@test "executes a command for a live message from the broker" {
	script="printf '%s' \"\$1\" > '$output_file'"
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	sleep 0.2

	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-m "live message"
	[ "$status" -eq 0 ]

	wait_for_file "$output_file"

	run cat "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "live message" ]
}

@test "subscribes to multiple topics" {
	topic2="${topic}/second"
	script="printf '%s\n' \"\$1\" >> '$output_file'"
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-t "$topic2" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	sleep 0.2

	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-m "first topic"
	[ "$status" -eq 0 ]

	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic2" \
		-m "second topic"
	[ "$status" -eq 0 ]

	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if [ -f "$output_file" ] && [ "$(wc -l < "$output_file")" -eq 2 ]; then
			break
		fi
		sleep 0.2
	done

	run sort "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n%s' "first topic" "second topic")" ]
}

@test "executes a command for a retained message from the broker" {
	run mosquitto_pub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-m "hello world" -r
	[ "$status" -eq 0 ]

	script="printf '%s' \"\$1\" > '$output_file'"
	"$MQTT_EXEC" -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-t "$topic" \
		-- /bin/sh -c "$script" /bin/sh &
	echo $! > "$pid_file"

	wait_for_file "$output_file"

	run cat "$output_file"
	[ "$status" -eq 0 ]
	[ "$output" = "hello world" ]
}

@test "publishes the configured status message after reconnect" {
	status_topic="${topic}/state"
	first_status="$BATS_TEST_TMPDIR/status-first.$$"
	second_status="$BATS_TEST_TMPDIR/status-second.$$"
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

	start_single_message_subscriber "$status_topic" "$second_status"
	second_sub_pid="$SUB_PID"

	stop_broker
	start_broker

	assert_single_message "$second_sub_pid" "$second_status" "online" 50
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
	sleep 0.2

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

	mosquitto_sub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-C 1 \
		-t "$will_topic" >"$will_path" &
	sub_pid=$!

	sleep 0.2

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

	mosquitto_sub -h "$MQTT_TEST_HOST" \
		-p "$MQTT_TEST_PORT" \
		-C 1 \
		-t "$will_topic" >"$will_path" &
	sub_pid=$!

	kill -KILL "$(cat "$pid_file")"
	wait "$(cat "$pid_file")" 2>/dev/null || true
	rm -f "$pid_file"

	wait "$sub_pid"
	run cat "$will_path"
	[ "$status" -eq 0 ]
	[ "$output" = "failed" ]
}
