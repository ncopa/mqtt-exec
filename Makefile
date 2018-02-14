
VERSION=0.3
LIBS=-lmosquitto
CFLAGS ?= -g -Wall -Werror
WITH_TLS := 1

ifeq ($(WITH_TLS),1)
CFLAGS += -DWITH_TLS
endif

mqtt-exec: mqtt-exec.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

clean:
	rm -f mqtt-exec
