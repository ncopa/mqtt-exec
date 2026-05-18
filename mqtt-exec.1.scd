mqtt-exec(1)

# NAME

mqtt-exec - execute a command for MQTT messages

# SYNOPSIS

*mqtt-exec* [_options..._] *-t* _topic_... *--* _command_ [_args..._]

# DESCRIPTION

*mqtt-exec* connects to an MQTT broker, subscribes to one or more topics,
and executes a command when messages are received.

By default, the message payload is passed as the last argument to the
configured command. When *-v* is used, the topic is passed as the
second-to-last argument and the payload is passed as the last argument.

Empty payloads are ignored unless *-v* is enabled.

After each successful connection, *mqtt-exec* can optionally publish an
"up" status message before waiting for subscribed messages.

When *--status-down-payload* is configured, *mqtt-exec* publishes that
message on clean shutdown. Unexpected termination is still handled
separately through the MQTT will configured with *--will-* options.

The clean-shutdown status publish is best effort. *mqtt-exec* attempts to
flush it before disconnecting, but does not wait for a full QoS 1 or QoS 2
delivery handshake before exiting.

# OPTIONS

*-c*, *--disable-clean-session*
	Disable the MQTT clean session flag.

*-d*, *--debug*
	Enable debug output from the MQTT client library.

*-h*, *--host* _host_
	Connect to _host_. The default is *localhost*.

*-i*, *--id* _id_
	Set the client identifier.

*-k*, *--keepalive* _seconds_
	Set the MQTT keepalive interval. The default is *60*.

*-p*, *--port* _port_
	Connect to TCP _port_. The default is *1883*.

*-P*, *--password* _password_
	Set the password used for authentication.

*-q*, *--qos* _qos_
	Set the subscription QoS. Valid values are *0*, *1*, and *2*.

*-t*, *--topic* _topic_
	Subscribe to _topic_. This option may be given more than once.

*-u*, *--username* _username_
	Set the username used for authentication.

*-v*, *--verbose*
	Pass the MQTT topic as an additional command argument before the payload.

*--version*
	Print the program version and exit.

*--will-topic* _topic_
	Set the MQTT will topic.

*--will-payload* _payload_
	Set the MQTT will payload.

*--will-qos* _qos_
	Set the MQTT will QoS. Valid values are *0*, *1*, and *2*.

*--will-retain*
	Publish the MQTT will as a retained message.

*--status-topic* _topic_
	Publish status transitions to _topic_.

*--status-up-payload* _payload_
	Set the payload used after each successful connection. If omitted, an
	empty payload is sent.

*--status-down-payload* _payload_
	Set the payload used on clean shutdown. This publish is best effort.

*--status-qos* _qos_
	Set the QoS for status publishes. Valid values are *0*, *1*, and *2*.

*--status-retain*
	Publish status messages as retained messages.

*--ready-fd* _fd_
	Write a newline to file descriptor _fd_ after the initial connection and
	subscription setup succeeds, then close it. This can be used by test
	harnesses or service supervisors that need an explicit readiness signal.

# TLS OPTIONS

When built with TLS support, the following options are available:

*--cafile* _file_
	Path to a CA certificate file.

*--capath* _directory_
	Path to a directory containing CA certificates.

*--cert* _file_
	Path to the client certificate.

*--key* _file_
	Path to the client private key.

*--ciphers* _list_
	OpenSSL-compatible cipher list.

*--tls-version* _version_
	Set the TLS protocol version.

*--psk* _key_
	Set the TLS pre-shared key in hexadecimal form.

*--psk-identity* _identity_
	Set the TLS PSK identity string.

# ENVIRONMENT

*MQTT_EXEC_PASSWORD*
	Used as the password when *--username* is set and no password is provided
	on the command line.

# EXAMPLES

Show MQTT messages as desktop notifications:

```
$ mqtt-exec -h "$mqtt_host" -t "$topic" -v -- \
	/usr/bin/notify-send -t 3000 -i network-server
```

Run a script for retained messages on startup and for later live messages:

```
$ mqtt-exec -h broker.example.com -t sensors/door -- /usr/local/bin/on-door-event
```

Publish presence status and process messages:

```
$ mqtt-exec -h broker.example.com \
	-t sensors/door \
	--status-topic service/mqtt-exec/status \
	--status-up-payload online \
	--status-down-payload offline \
	--will-topic service/mqtt-exec/status \
	--will-payload failed \
	--status-retain \
	-- /usr/local/bin/on-door-event
```

# SEE ALSO

*mosquitto_sub*(1), *mosquitto_pub*(1)
