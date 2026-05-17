
VERSION=0.4
LIBS=-lmosquitto
CFLAGS ?= -g -Wall -Werror
CFLAGS += -DVERSION=\"$(VERSION)\"
WITH_TLS := 1

ifeq ($(WITH_TLS),1)
CFLAGS += -DWITH_TLS
endif

mqtt-exec: mqtt-exec.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

clean:
	rm -f mqtt-exec

check: mqtt-exec
	bats --print-output-on-failure ./mqtt-exec.bats
