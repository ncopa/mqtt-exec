/* Copyright (c) 2013-2019 Natanael Copa <ncopa@alpinelinux.org>
 *
 * This work is licensed under the terms of the MIT license.
 * For a copy, see <https://opensource.org/licenses/MIT>.
 *
 */
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
	int qos;
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
			mosquitto_subscribe(mosq, NULL, ud->topics[i], ud->qos);
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
"\n"
"options:\n"
" -c,--disable-clean-session  Disable the 'clean session' flag\n"
" -d,--debug                  Enable debugging\n"
" -h,--host HOST              Connect to HOST. Default is localhost\n"
" -i,--id ID                  The id to use for this client\n"
" -k,--keepalive SEC          Set keepalive to SEC. Default is 60\n"
" -p,--port PORT              Set TCP port to PORT. Default is 1883\n"
" -P,--password PASSWORD      Set password for authentication\n"
" -q,--qos QOS                Set Quality of Serive to level. Default is 0\n"
" -t,--topic TOPIC            Set MQTT topic to TOPIC. May be repeated\n"
" -u,--username USERNAME      Set username for authentication\n"
" -v,--verbose                Pass over the topic to application as first arg\n"
" --will-topic TOPIC          Set the client Will topic to TOPIC\n"
" --will-payload MSG          Set the client Will message to MSG\n"
" --will-qos QOS              Set the QoS level for client Will message\n"
" --will-retain               Make the client Will retained\n"
#ifdef WITH_TLS
" --cafile FILE               Path to file containing CA certificates\n"
" --capath DIR                Path to directory containing CA certificates\n"
" --cert FILE                 Client certificate for authentication\n"
" --key FILE                  Client private key for authentication\n"
" --ciphers LIST              OpenSSL compatible list of TLS ciphers\n"
" --tls-version VERSION       TLS protocol version: tlsv1.2 tlsv1.1 tlsv1\n"
" --psk KEY                   Pre-shared-key in hexadecimal (no leading 0x)\n"
" --psk-identity STRING       Client identity string for TLS-PSK mode\n"
#endif
		"\n", major, minor, rev);
	return retcode;
}

static int perror_ret(const char *msg)
{
	perror(msg);
	return 1;
}

static int valid_qos_range(int qos, const char *type)
{
	if (qos >= 0 && qos <= 2)
		return 1;

	fprintf(stderr, "%d: %s out of range\n", qos, type);
	return 0;
}

int main(int argc, char *argv[])
{
	static struct option opts[] = {
		{"disable-clean-session", no_argument,	0, 'c' },
		{"debug",	no_argument,		0, 'd' },
		{"host",	required_argument,	0, 'h' },
		{"id",		required_argument,	0, 'i' },
		{"keepalive",	required_argument,	0, 'k' },
		{"port",	required_argument,	0, 'p' },
		{"qos",		required_argument,	0, 'q' },
		{"topic",	required_argument,	0, 't' },
		{"verbose",	no_argument,		0, 'v' },
		{"username",	required_argument,	0, 'u' },
		{"password",	required_argument,	0, 'P' },
		{"will-topic",	required_argument,	0, 0x1001 },
		{"will-payload", required_argument,	0, 0x1002 },
		{"will-qos",	required_argument,	0, 0x1003 },
		{"will-retain",	no_argument,		0, 0x1004 },
#ifdef WITH_TLS
		{"cafile",	required_argument,	0, 0x2001 },
		{"capath",	required_argument,	0, 0x2002 },
		{"cert",	required_argument,	0, 0x2003 },
		{"key",		required_argument,	0, 0x2004 },
		{"ciphers",	required_argument,	0, 0x2005 },
		{"tls-version",	required_argument,	0, 0x2006 },
		{"psk",		required_argument,	0, 0x2007 },
		{"psk-identity",required_argument,	0, 0x2008 },
#endif
		{ 0, 0, 0, 0}
	};
	int debug = 0;
	bool clean_session = true;
	const char *host = "localhost";
	int port = 1883;
	int keepalive = 60;
	int i, c, rc = 1;
	struct userdata ud;
	char *id = NULL;
	struct mosquitto *mosq = NULL;
	char *username = NULL;
	char *password = NULL;

	char *will_payload = NULL;
	int will_qos = 0;
	bool will_retain = false;
	char *will_topic = NULL;
#ifdef WITH_TLS
	char *cafile = NULL;
	char *capath = NULL;
	char *certfile = NULL;
	char *keyfile = NULL;
	char *ciphers = NULL;
	char *tls_version = NULL;
	char *psk = NULL;
	char *psk_identity = NULL;
#endif

	memset(&ud, 0, sizeof(ud));

	while ((c = getopt_long(argc, argv, "cdh:i:k:p:P:q:t:u:v", opts, &i)) != -1) {
		switch(c) {
		case 'c':
			clean_session = false;
			break;
		case 'd':
			debug = 1;
			break;
		case 'h':
			host = optarg;
			break;
		case 'i':
			if (strlen(optarg) > MOSQ_MQTT_ID_MAX_LENGTH) {
				fprintf(stderr, "specified id is longer than %d chars\n",
					MOSQ_MQTT_ID_MAX_LENGTH);
				return 1;
			}
			id = optarg;
			break;
		case 'k':
			keepalive = atoi(optarg);
			break;
		case 'p':
			port = atoi(optarg);
			break;
		case 'P':
			password = optarg;
		case 'q':
			ud.qos = atoi(optarg);
			if (!valid_qos_range(ud.qos, "QoS"))
				return 1;
			break;
		case 't':
			ud.topic_count++;
			ud.topics = realloc(ud.topics,
					    sizeof(char *) * ud.topic_count);
			ud.topics[ud.topic_count-1] = optarg;
			break;
		case 'u':
			username = optarg;
		case 'v':
			ud.verbose = 1;
			break;
		case 0x1001:
			will_topic = optarg;
			break;
		case 0x1002:
			will_payload = optarg;
			break;
		case 0x1003:
			will_qos = atoi(optarg);
			if (!valid_qos_range(will_qos, "will QoS"))
				return 1;
			break;
		case 0x1004:
			will_retain = 1;
			break;
#ifdef WITH_TLS
		case 0x2001:
			cafile = optarg;
			break;
		case 0x2002:
			capath = optarg;
			break;
		case 0x2003:
			certfile = optarg;
			break;
		case 0x2004:
			keyfile = optarg;
			break;
		case 0x2005:
			ciphers = optarg;
			break;
		case 0x2006:
			tls_version = optarg;
			break;
		case 0x2007:
			psk = optarg;
			break;
		case 0x2008:
			psk_identity = optarg;
			break;
#endif
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

	mosquitto_lib_init();
	mosq = mosquitto_new(id, clean_session, &ud);
	if (mosq == NULL)
		return perror_ret("mosquitto_new");

	if (debug) {
		printf("host=%s:%d\nid=%s\ntopic_count=%zu\ncommand=%s\n",
			host, port, id ? id : "(null)", ud.topic_count,
			ud.command_argv[0]);
		mosquitto_log_callback_set(mosq, log_cb);
	}

	if (will_topic && mosquitto_will_set(mosq, will_topic,
					     will_payload ? strlen(will_payload) : 0,
					     will_payload, will_qos,
					     will_retain)) {
		fprintf(stderr, "Failed to set will\n");
		goto cleanup;
	}

	if (username && !password)
		password = getenv("MQTT_EXEC_PASSWORD");

	if (!username != !password) {
		fprintf(stderr, "Need to set both username and password\n");
		goto cleanup;
	}

	if (username && password)
		mosquitto_username_pw_set(mosq, username, password);

#ifdef WITH_TLS
	if ((cafile || capath) && mosquitto_tls_set(mosq, cafile, capath, certfile,
						    keyfile, NULL)) {
		fprintf(stderr, "Failed to set TLS options\n");
		goto cleanup;
	}
	if (psk && mosquitto_tls_psk_set(mosq, psk, psk_identity, NULL)) {
		fprintf(stderr, "Failed to set TLS-PSK\n");
		goto cleanup;
	}
	if ((tls_version || ciphers) && mosquitto_tls_opts_set(mosq, 1, tls_version,
							       ciphers)) {
		fprintf(stderr, "Failed to set TLS options\n");
		goto cleanup;
	}
#endif

	mosquitto_connect_callback_set(mosq, connect_cb);
	mosquitto_message_callback_set(mosq, message_cb);

	/* let kernel reap the children */
	signal(SIGCHLD, SIG_IGN);

	rc = mosquitto_connect(mosq, host, port, keepalive);
	if (rc != MOSQ_ERR_SUCCESS) {
		if (rc == MOSQ_ERR_ERRNO)
			return perror_ret("mosquitto_connect_bind");
		fprintf(stderr, "Unable to connect (%d)\n", rc);
		goto cleanup;
	}

	rc = mosquitto_loop_forever(mosq, -1, 1);

cleanup:
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
	return rc;

}
