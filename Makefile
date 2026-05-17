
VERSION=0.4
LIBS=-lmosquitto
CFLAGS ?= -g -Wall -Werror
CFLAGS += -DVERSION=\"$(VERSION)\"
WITH_TLS := 1
SCDOC ?= scdoc

ifeq ($(WITH_TLS),1)
CFLAGS += -DWITH_TLS
endif

mqtt-exec: mqtt-exec.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

mqtt-exec.1: mqtt-exec.1.scd
	$(SCDOC) < $< > $@

clean:
	rm -f mqtt-exec mqtt-exec.1

check: mqtt-exec
	bats --print-output-on-failure ./mqtt-exec.bats
