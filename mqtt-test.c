#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <mosquitto.h>

enum mode {
	MODE_NONE,
	MODE_PUB,
	MODE_SUB,
};

struct app {
	enum mode mode;
	const char *host;
	int port;
	const char *topic;
	const char *payload;
	int ready_fd;
	int count;
	int timeout_secs;
	bool null_payload;
	bool retain;
	bool done;
	bool ready;
	int exit_code;
	struct mosquitto *mosq;
};

static void usage(FILE *out)
{
	fprintf(out,
		"usage: mqtt-test pub|sub [OPTIONS]\n"
		"options:\n"
		" -h, --host HOST       MQTT host (default 127.0.0.1)\n"
		" -p, --port PORT       MQTT port (default 1883)\n"
		" -t, --topic TOPIC     MQTT topic\n"
		" -m, --message MSG     publish payload\n"
		" -n, --null-message    publish an empty payload\n"
		" -r, --retain          publish as retained\n"
		" -C, --count N         number of messages to read (default 1)\n"
		" -W, --timeout SEC     overall timeout in seconds (default 5)\n"
		"     --ready-fd N      write a newline to fd N after SUBACK and close it\n");
}

static int signal_ready_fd(int fd)
{
	ssize_t wr;

	wr = write(fd, "\n", 1);
	if (wr != 1) {
		perror("write");
		return 1;
	}
	return 0;
}

static void close_ready_fd(struct app *app)
{
	if (app->ready_fd >= 0) {
		close(app->ready_fd);
		app->ready_fd = -1;
	}
}

static void connect_cb(struct mosquitto *mosq, void *obj, int rc)
{
	struct app *app = obj;
	int ret;

	if (rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "%s\n", mosquitto_connack_string(rc));
		app->done = true;
		app->exit_code = 1;
		return;
	}

	if (app->mode == MODE_SUB) {
		ret = mosquitto_subscribe(mosq, NULL, app->topic, 0);
		if (ret != MOSQ_ERR_SUCCESS) {
			fprintf(stderr, "subscribe failed (%d)\n", ret);
			app->done = true;
			app->exit_code = 1;
		}
		return;
	}

	ret = mosquitto_publish(mosq, NULL, app->topic,
		app->null_payload ? 0 : (int)strlen(app->payload),
		app->null_payload ? NULL : app->payload, 0, app->retain);
	if (ret != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "publish failed (%d)\n", ret);
		app->done = true;
		app->exit_code = 1;
	}
}

static void subscribe_cb(struct mosquitto *mosq, void *obj, int mid, int qos_count,
		const int *granted_qos)
{
	struct app *app = obj;
	(void)mosq;
	(void)mid;
	(void)qos_count;
	(void)granted_qos;

	if (!app->ready && app->ready_fd >= 0) {
		if (signal_ready_fd(app->ready_fd) != 0) {
			app->done = true;
			app->exit_code = 1;
			return;
		}
		close_ready_fd(app);
	}
	app->ready = true;
}

static void publish_cb(struct mosquitto *mosq, void *obj, int mid)
{
	struct app *app = obj;
	(void)mid;

	app->done = true;
	app->exit_code = 0;
	mosquitto_disconnect(mosq);
}

static void message_cb(struct mosquitto *mosq, void *obj,
		const struct mosquitto_message *msg)
{
	struct app *app = obj;

	(void)mosq;
	if (msg->payloadlen > 0)
		fwrite(msg->payload, 1, (size_t)msg->payloadlen, stdout);
	fputc('\n', stdout);
	fflush(stdout);

	app->count--;
	if (app->count <= 0) {
		app->done = true;
		app->exit_code = 0;
		mosquitto_disconnect(mosq);
	}
}

static int timed_out(time_t start, int timeout_secs)
{
	return timeout_secs >= 0 && time(NULL) - start >= timeout_secs;
}

int main(int argc, char **argv)
{
	static struct option opts[] = {
		{ "host", required_argument, NULL, 'h' },
		{ "port", required_argument, NULL, 'p' },
		{ "topic", required_argument, NULL, 't' },
		{ "message", required_argument, NULL, 'm' },
		{ "null-message", no_argument, NULL, 'n' },
		{ "retain", no_argument, NULL, 'r' },
		{ "count", required_argument, NULL, 'C' },
		{ "timeout", required_argument, NULL, 'W' },
		{ "ready-fd", required_argument, NULL, 1000 },
		{ 0, 0, 0, 0 },
	};
	struct app app = {
		.host = "127.0.0.1",
		.port = 1883,
		.ready_fd = -1,
		.count = 1,
		.timeout_secs = 5,
	};
	time_t started;
	int opt;
	int rc;

	if (argc < 2) {
		usage(stderr);
		return 2;
	}
	if (strcmp(argv[1], "pub") == 0)
		app.mode = MODE_PUB;
	else if (strcmp(argv[1], "sub") == 0)
		app.mode = MODE_SUB;
	else {
		usage(stderr);
		return 2;
	}

	argc--;
	argv++;
	optind = 1;
	while ((opt = getopt_long(argc, argv, "h:p:t:m:nrC:W:", opts, NULL)) != -1) {
		switch (opt) {
		case 'h':
			app.host = optarg;
			break;
		case 'p':
			app.port = atoi(optarg);
			break;
		case 't':
			app.topic = optarg;
			break;
		case 'm':
			app.payload = optarg;
			break;
		case 'n':
			app.null_payload = true;
			break;
		case 'r':
			app.retain = true;
			break;
		case 'C':
			app.count = atoi(optarg);
			break;
		case 'W':
			app.timeout_secs = atoi(optarg);
			break;
		case 1000:
			app.ready_fd = atoi(optarg);
			break;
		default:
			usage(stderr);
			return 2;
		}
	}

	if (app.topic == NULL) {
		fprintf(stderr, "missing topic\n");
		return 2;
	}
	if (app.mode == MODE_PUB && !app.null_payload && app.payload == NULL) {
		fprintf(stderr, "missing message\n");
		return 2;
	}
	if (app.mode == MODE_SUB && app.count < 1) {
		fprintf(stderr, "count must be positive\n");
		return 2;
	}

	mosquitto_lib_init();
	app.mosq = mosquitto_new(NULL, true, &app);
	if (app.mosq == NULL) {
		perror("mosquitto_new");
		mosquitto_lib_cleanup();
		return 1;
	}

	mosquitto_connect_callback_set(app.mosq, connect_cb);
	mosquitto_subscribe_callback_set(app.mosq, subscribe_cb);
	mosquitto_publish_callback_set(app.mosq, publish_cb);
	mosquitto_message_callback_set(app.mosq, message_cb);

	rc = mosquitto_connect(app.mosq, app.host, app.port, 60);
	if (rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Unable to connect (%d)\n", rc);
		mosquitto_destroy(app.mosq);
		mosquitto_lib_cleanup();
		return 1;
	}

	started = time(NULL);
	while (!app.done) {
		rc = mosquitto_loop(app.mosq, 100, 1);
		if (rc != MOSQ_ERR_SUCCESS) {
			fprintf(stderr, "loop failed (%d)\n", rc);
			app.exit_code = 1;
			break;
		}
		if (timed_out(started, app.timeout_secs)) {
			fprintf(stderr, "timed out\n");
			app.exit_code = 1;
			break;
		}
	}

	close_ready_fd(&app);
	mosquitto_destroy(app.mosq);
	mosquitto_lib_cleanup();
	return app.exit_code;
}
