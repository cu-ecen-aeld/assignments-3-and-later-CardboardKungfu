CROSS_COMPILE ?=
CC := $(CROSS_COMPILE)gcc

default: writer

writer: writer.c
	$(CC) -o writer writer.c

clean:
	rm -f writer.o writer