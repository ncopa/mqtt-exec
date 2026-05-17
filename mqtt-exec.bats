#!/usr/bin/env bats

MQTT_EXEC="$BATS_TEST_DIRNAME/mqtt-exec"

@test "--version prints the program version" {
	run "$MQTT_EXEC" --version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^mqtt-exec[[:space:]][0-9] ]]
}

