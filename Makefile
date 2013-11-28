
VERSION=0.1
LIBS=-lmosquitto
CFLAGS ?= -g -Wall -Werror

mqtt-exec: mqtt-exec.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)
