#!/usr/bin/env bats

MQTT_EXEC="$BATS_TEST_DIRNAME/mqtt-exec"
MQTT_TEST_HOST="${MQTT_TEST_HOST:-127.0.0.1}"
MQTT_TEST_PORT="${MQTT_TEST_PORT:-18884}"

setup_file() {
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/mqtt-exec-test.XXXXXX")"
	pidfile="$workdir/mosquitto.pid"
	conffile="$workdir/mosquitto.conf"
	logfile="$workdir/mosquitto.log"

	cat >"$conffile" <<EOF
listener $MQTT_TEST_PORT $MQTT_TEST_HOST
allow_anonymous true
persistence false
pid_file $pidfile
log_dest file $logfile
EOF

	mosquitto -c "$conffile" -d

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

teardown_file() {
	if [ -f "$pidfile" ]; then
		kill "$(cat "$pidfile")" 2>/dev/null || true
		wait "$(cat "$pidfile")" 2>/dev/null || true
	fi

	rm -rf "$workdir"
}

setup() {
	topic="mqtt-exec/test/${BATS_TEST_NUMBER}.$$"
	output_file="$BATS_TEST_TMPDIR/payload"
	pid_file="$BATS_TEST_TMPDIR/mqtt-exec.pid"
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
