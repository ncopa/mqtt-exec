
#include <err.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mosquitto.h>

struct userdata {
	char **topics;
	size_t topic_count;
	int command_argc;
	int verbose;
	char **command_argv;
};

void log_cb(struct mosquitto *mosq, void *obj, int level, const char *str)
{
	printf("%s\n", str);
}

void message_cb(struct mosquitto *mosq, void *obj,
		const struct mosquitto_message *msg)
{
	struct userdata *ud = (struct userdata *)obj;
	if (msg->payloadlen || ud->verbose) {
		if (ud->command_argv && fork() == 0) {
			if (ud->verbose)
				ud->command_argv[ud->command_argc-2] = msg->topic;
			ud->command_argv[ud->command_argc-1] =
				msg->payloadlen ? msg->payload : NULL;
			execv(ud->command_argv[0], ud->command_argv);
			perror(ud->command_argv[0]);
			_exit(1);
		}
	}
}

void connect_cb(struct mosquitto *mosq, void *obj, int result)
{
	struct userdata *ud = (struct userdata *)obj;
	fflush(stderr);
	if (result == 0) {
		size_t i;
		for (i = 0; i < ud->topic_count; i++)
			mosquitto_subscribe(mosq, NULL, ud->topics[i], 0);
	} else {
		fprintf(stderr, "%s\n", mosquitto_connack_string(result));
	}
}

int usage(int retcode)
{
	int major, minor, rev;

	mosquitto_lib_version(&major, &minor, &rev);
	printf(
"mqtt-exec - execute command on mqtt messages\n"
"libmosquitto version: %d.%d.%d\n"
"\n"
"usage: mqtt-exec [ARGS...] -t TOPIC ... -- CMD [CMD ARGS...]\n"
		"\n", major, minor, rev);
	return retcode;
}

static int perror_ret(const char *msg)
{
	perror(msg);
	return 1;
}

int main(int argc, char *argv[])
{
	static struct option opts[] = {
		{"debug",	no_argument,		0, 'd' },
		{"host",	required_argument,	0, 'h' },
		{"keepalive",	required_argument,	0, 'k' },
		{"port",	required_argument,	0, 'p' },
		{"topic",	required_argument,	0, 't' },
		{"verbose",	no_argument,		0, 'v' },
		{ 0, 0, 0, 0}
	};
	int debug = 0;
	const char *host = "localhost";
	int port = 1883;
	int keepalive = 60;
	int i, c, rc;
	struct userdata ud;
	char hostname[256];
	static char id[MOSQ_MQTT_ID_MAX_LENGTH+1];
	struct mosquitto *mosq = NULL;

	memset(&ud, 0, sizeof(ud));

	memset(hostname, 0, sizeof(hostname));
	memset(id, 0, sizeof(id));

	while ((c = getopt_long(argc, argv, "dh:k:p:t:v", opts, &i)) != -1) {
		switch(c) {
		case 'd':
			debug = 1;
			break;
		case 'h':
			host = optarg;
			break;
		case 'k':
			keepalive = atoi(optarg);
			break;
		case 'p':
			port = atoi(optarg);
			break;
		case 't':
			ud.topic_count++;
			ud.topics = realloc(ud.topics,
					    sizeof(char *) * ud.topic_count);
			ud.topics[ud.topic_count-1] = optarg;
			break;
		case 'v':
			ud.verbose = 1;
			break;
		case '?':
			return usage(1);
		}
	}

	if ((ud.topics == NULL) || (optind == argc))
		return usage(1);

	ud.command_argc = (argc - optind) + 1 + ud.verbose;
	ud.command_argv = malloc((ud.command_argc + 1) * sizeof(char *));
	if (ud.command_argv == NULL)
		return perror_ret("malloc");

	for (i=0; i <= ud.command_argc; i++)
		ud.command_argv[i] = optind+i < argc ? argv[optind+i] : NULL;

	/* generate an id */
	gethostname(hostname, sizeof(hostname)-1);
	snprintf(id, sizeof(id), "mqttexe/%x-%s", getpid(), hostname);

	mosquitto_lib_init();
	mosq = mosquitto_new(id, true, &ud);
	if (mosq == NULL)
		return perror_ret("mosquitto_new");

	if (debug) {
		printf("host=%s:%d\nid=%s\ntopic_count=%zu\ncommand=%s\n",
			host, port, id, ud.topic_count, ud.command_argv[0]);
		mosquitto_log_callback_set(mosq, log_cb);
	}
	mosquitto_connect_callback_set(mosq, connect_cb);
	mosquitto_message_callback_set(mosq, message_cb);

	/* let kernel reap the children */
	signal(SIGCHLD, SIG_IGN);

	rc = mosquitto_connect(mosq, host, port, keepalive);
	if (rc != MOSQ_ERR_SUCCESS) {
		if (rc == MOSQ_ERR_ERRNO)
			return perror_ret("mosquitto_connect_bind");
		fprintf(stderr, "Unable to connect (%d)\n", rc);
		return 1;
	}

	rc = mosquitto_loop_forever(mosq, -1, 1);

	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
	return rc;

}
