
VERSION=0.7.1
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
MAN1DIR ?= $(MANDIR)/man1
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

mqtt-test: mqtt-test.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

mqtt-exec.1: mqtt-exec.1.scd
	$(SCDOC) < $< > $@

install: mqtt-exec mqtt-exec.1
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(MAN1DIR)"
	install -m755 mqtt-exec "$(DESTDIR)$(BINDIR)/mqtt-exec"
	install -m644 mqtt-exec.1 "$(DESTDIR)$(MAN1DIR)/mqtt-exec.1"

clean:
	rm -f mqtt-exec mqtt-test mqtt-exec.1

check: mqtt-exec mqtt-test
	bats --print-output-on-failure ./mqtt-exec.bats
