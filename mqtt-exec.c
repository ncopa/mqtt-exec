
#include <err.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>

#include <mosquitto.h>

struct userdata {
	char **topics;
	size_t topic_count;
	int command_argc;
	int verbose;
	char **command_argv;
	int qos;
};

struct configuration {
	int debug;
	bool clean_session;
	const char *host;
	char id[MOSQ_MQTT_ID_MAX_LENGTH+1];
	int keepalive;
	int port;
	struct userdata ud;
	char *username;
	char *password;

	char *will_payload;
	int will_qos;
	bool will_retain;
	char *will_topic;
	#ifdef WITH_TLS
	char *cafile;
	char *capath;
	char *certfile;
	char *keyfile;
	char *ciphers;
	char *tls_version;
	char *psk;
	char *psk_identity;
	#endif
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
" -C,--config                 Specify the configuration file\n"
" -d,--debug                  Enable debugging\n"
" -h,--host HOST              Connect to HOST. Default is localhost\n"
" -i,--id ID                  The id to use for this client\n"
" -k,--keepalive SEC          Set keepalive to SEC. Default is 60\n"
" -p,--port PORT              Set TCP port to PORT. Default is 1883\n"
" -P,--password PASSWORD      Set password for authentication\n"
" -q,--qos QOS                Set Quality of Serive to level. Default is 0\n"
" -t,--topic TOPIC            Set MQTT topic to TOPIC. May be repeated\n"
" -u,--username USERNAME      Set username for authentication\n"
" -v,--verbose                Pass over the topic to application as firs arg\n"
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
" --psk KEY                   pre-shared-key in hexadecimal (no leading 0x)\n"
" --psk-identity STRING       client identity string for TLS-PSK mode\n"
#endif
"\n"
"Each long-form option (except config itself) can also be set in a \n"
"config file (specified with -C/--config). The format is `key = value`, \n"
"where key is the parameter without the '--'. Comments are supported by \n"
"starting the line with a '#'.\n"
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

#define LINE_SIZE 256
#define LINE_BUFF_SIZE 16

int read_file(const char *path, char** file_contents[])
{
	FILE *fd;
	char line[LINE_SIZE];
	int idx = 0;
	size_t len = LINE_BUFF_SIZE;
	size_t line_len = LINE_SIZE;
	char** lines;

	lines = malloc(len * sizeof(char *));

	if (!lines) {
		return perror_ret("malloc");
	}

	fd = fopen(path, "r");

	if (!fd) {
		free(lines);
		return perror_ret("fopen");
	}

	while(fgets(line, LINE_SIZE, fd)) {
		lines[idx] = strndup(line, LINE_SIZE);

		while (strstr(lines[idx], "\n") == NULL) {
			if (!fgets(line, LINE_SIZE, fd))
				break;

			lines[idx] = realloc(lines[idx], (line_len + LINE_SIZE) * sizeof(char *));
			if (!lines[idx]) {
				free(lines);
				return perror_ret("realloc");
			}
			strncpy(&lines[idx][line_len - 1], line, LINE_SIZE);
			line_len += LINE_SIZE;
		}

		idx++;

		if (idx >= len - 1) {
			len += LINE_BUFF_SIZE;
			if(!(lines = realloc(lines, len * sizeof(char*)))) {
				free(lines);
				return perror_ret("realloc");
			}
		}
	}
	line[idx] = '\0';

	*file_contents = lines;

	return 0;
}

/**
 * Source: https://stackoverflow.com/a/122721
 * By: Adam Rosenfield (https://stackoverflow.com/users/9530)
 */
char *trim(char *str)
{
	char *end;

	// Trim leading space
	while(isspace((unsigned char)*str)) str++;

	if(*str == 0)	 // All spaces?
		return str;

	// Trim trailing space
	end = str + strlen(str) - 1;
	while(end > str && isspace((unsigned char)*end)) end--;

	// Write new null terminator
	*(end+1) = 0;

	return str;
}

int add_topic(struct configuration *conf, char *topic)
{
	conf->ud.topic_count++;
	conf->ud.topics = realloc(conf->ud.topics,
				sizeof(char *) * conf->ud.topic_count);
	if (!conf->ud.topics) {
		return perror_ret("realloc");
	}
	conf->ud.topics[conf->ud.topic_count-1] = topic;

	return 0;
}

int parse_config(char *config[], struct configuration *conf)
{
	char *line = NULL;
	int idx = 0;
	int rc = 0;
	char *key, *value;

	while((line = config[idx])) {
		key = trim(strdup(strtok(line, "=")));
		value = strtok(NULL, "\n");
		if (value)
			value = trim(strdup(value));
		if (key[0] == '#') { /* comment, ignoring line */ }
		else if(!strcmp(key, "debug"))
			conf->debug = 1;
		else if(!strcmp(key, "verbose"))
			conf->ud.verbose = 1;
		else if(!conf->host && !strcmp(key, "host"))
			conf->host = value;
		else if(conf->id && !strcmp(key, "id"))
			strncpy(conf->id, value, sizeof(conf->id)-1);
		else if(!strcmp(key, "topic")) {
			rc = add_topic(conf, value);
			if (rc)
				return rc;
		}
		else if(!conf->keepalive && !strcmp(key, "keepalive"))
			conf->keepalive = atoi(value);
		else if(!conf->port && !strcmp(key, "port"))
			conf->port = atoi(value);
		else if(!conf->ud.qos && !strcmp(key, "qos"))
			conf->ud.qos = atoi(value);
		else if(!conf->username && !strcmp(key, "username"))
			conf->username = value;
		else if (!conf->password && !strcmp(key, "password"))
			conf->password = value;
		else if (!conf->will_payload && !strcmp(key, "will_payload"))
			conf->will_payload = value;
		else if (!conf->will_qos && !strcmp(key, "will_qos"))
			conf->will_qos = atoi(value);
		else if (!conf->will_retain && !strcmp(key, "will_retain"))
			conf->will_retain = true;
		else if (!conf->will_topic && !strcmp(key, "will_topic"))
			conf->will_topic = value;
		#ifdef WITH_TLS
		else if (!conf->cafile && !strcmp(key, "cafile"))
			conf->cafile = value;
		else if (!conf->capath && !strcmp(key, "capath"))
			conf->capath = value;
		else if (!conf->certfile && !strcmp(key, "certfile"))
			conf->certfile = value;
		else if (!conf->keyfile && !strcmp(key, "keyfile"))
			conf->keyfile = value;
		else if (!conf->ciphers && !strcmp(key, "ciphers"))
			conf->ciphers = value;
		else if (!conf->tls_version && !strcmp(key, "tls_version"))
			conf->tls_version = value;
		else if (!conf->psk && !strcmp(key, "psk"))
			conf->psk = value;
		else if (!conf->psk_identity && !strcmp(key, "psk_identity"))
			conf->psk_identity = value;
		#endif
		else {
			fprintf(stderr, "Unknown config key '%s' on line %d\n", key, idx + 1);
			exit(1);
		}
		idx++;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	static struct option opts[] = {
		{"disable-clean-session", no_argument,	0, 'c' },
		{"config",	required_argument,	0, 'C' },
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

	struct configuration conf;
	const char *config_file = "";
	int i, c, rc = 1;
	char hostname[256];
	struct mosquitto *mosq = NULL;

	memset(&conf, 0, sizeof(conf));
	memset(hostname, 0, sizeof(hostname));

	while ((c = getopt_long(argc, argv, "cC:dh:i:k:p:P:q:t:u:v", opts, &i)) != -1) {
		switch(c) {
		case 'c':
			conf.clean_session = false;
			break;
		case 'C':
			config_file = optarg;
			break;
		case 'd':
			conf.debug = 1;
			break;
		case 'h':
			conf.host = optarg;
			break;
		case 'i':
			if (strlen(optarg) > MOSQ_MQTT_ID_MAX_LENGTH) {
				fprintf(stderr, "specified id is longer than %d chars\n",
					MOSQ_MQTT_ID_MAX_LENGTH);
				return 1;
			}
			strncpy(conf.id, optarg, sizeof(conf.id)-1);
			break;
		case 'k':
			conf.keepalive = atoi(optarg);
			break;
		case 'p':
			conf.port = atoi(optarg);
			break;
		case 'P':
			conf.password = optarg;
		case 'q':
			conf.ud.qos = atoi(optarg);
			if (!valid_qos_range(conf.ud.qos, "QoS"))
				return 1;
			break;
		case 't':
			rc = add_topic(&conf, optarg);
			if (rc)
				goto cleanup;
			break;
		case 'u':
			conf.username = optarg;
		case 'v':
			conf.ud.verbose = 1;
			break;
		case 0x1001:
			conf.will_topic = optarg;
			break;
		case 0x1002:
			conf.will_payload = optarg;
			break;
		case 0x1003:
			conf.will_qos = atoi(optarg);
			if (!valid_qos_range(conf.will_qos, "will QoS"))
				return 1;
			break;
		case 0x1004:
			conf.will_retain = 1;
			break;
#ifdef WITH_TLS
		case 0x2001:
			conf.cafile = optarg;
			break;
		case 0x2002:
			conf.capath = optarg;
			break;
		case 0x2003:
			conf.certfile = optarg;
			break;
		case 0x2004:
			conf.keyfile = optarg;
			break;
		case 0x2005:
			conf.ciphers = optarg;
			break;
		case 0x2006:
			conf.tls_version = optarg;
			break;
		case 0x2007:
			conf.psk = optarg;
			break;
		case 0x2008:
			conf.psk_identity = optarg;
			break;
#endif
		case '?':
			return usage(1);
		}
	}

	if (config_file) {
		char **file_contents;

		if (*config_file) {
			if (access(config_file, R_OK) <0) {
				fprintf(stderr, "File not found or no access: %s\n", config_file);
				goto cleanup;
			}

			rc = read_file(config_file, &file_contents);
			if(rc)
				goto cleanup;

			rc = parse_config(file_contents, &conf);
			if (rc)
				goto cleanup;
		}
	}

	if (!conf.port) {
		conf.port = 1883;
	}
	if (!conf.keepalive) {
		conf.keepalive = 60;
	}
	if (!conf.host) {
		conf.host = "localhost";
	}

	if ((conf.ud.topics == NULL) || (optind == argc))
		return usage(1);

	conf.ud.command_argc = (argc - optind) + 1 + conf.ud.verbose;
	conf.ud.command_argv = malloc((conf.ud.command_argc + 1) * sizeof(char *));
	if (conf.ud.command_argv == NULL)
		return perror_ret("malloc");

	for (i=0; i <= conf.ud.command_argc; i++)
		conf.ud.command_argv[i] = optind+i < argc ? argv[optind+i] : NULL;

	if (conf.id[0] == '\0') {
		/* generate an id */
		gethostname(hostname, sizeof(hostname)-1);
		snprintf(conf.id, sizeof(conf.id), "mqttexe/%x-%s", getpid(), hostname);
	}

	mosquitto_lib_init();
	mosq = mosquitto_new(conf.id, conf.clean_session, &conf.ud);
	if (mosq == NULL)
		return perror_ret("mosquitto_new");

	if (conf.debug) {
		printf("host=%s:%d\nid=%s\ntopic_count=%zu\ncommand=%s\n",
			conf.host, conf.port, conf.id, conf.ud.topic_count, conf.ud.command_argv[0]);
		mosquitto_log_callback_set(mosq, log_cb);
	}

	if (conf.will_topic && mosquitto_will_set(mosq, conf.will_topic,
					     conf.will_payload ? strlen(conf.will_payload) : 0,
					     conf.will_payload, conf.will_qos,
					     conf.will_retain)) {
		fprintf(stderr, "Failed to set will\n");
		goto cleanup;
	}

	if (!conf.username != !conf.password) {
		fprintf(stderr, "Need to set both username and password\n");
		goto cleanup;
	}

	if (conf.username && conf.password)
		mosquitto_username_pw_set(mosq, conf.username, conf.password);

#ifdef WITH_TLS
	if ((conf.cafile || conf.capath) && mosquitto_tls_set(mosq, conf.cafile, conf.capath, conf.certfile,
						    conf.keyfile, NULL)) {
		fprintf(stderr, "Failed to set TLS options\n");
		goto cleanup;
	}
	if (conf.psk && mosquitto_tls_psk_set(mosq, conf.psk, conf.psk_identity, NULL)) {
		fprintf(stderr, "Failed to set TLS-PSK\n");
		goto cleanup;
	}
	if ((conf.tls_version || conf.ciphers) && mosquitto_tls_opts_set(mosq, 1, conf.tls_version,
							       conf.ciphers)) {
		fprintf(stderr, "Failed to set TLS options\n");
		goto cleanup;
	}
#endif

	mosquitto_connect_callback_set(mosq, connect_cb);
	mosquitto_message_callback_set(mosq, message_cb);

	/* let kernel reap the children */
	signal(SIGCHLD, SIG_IGN);

	rc = mosquitto_connect(mosq, conf.host, conf.port, conf.keepalive);
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
