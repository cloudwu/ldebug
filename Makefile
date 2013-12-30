all : 
	@echo Please do 'make PLATFORM' where PLATFORM is one of these : linux mingw

CFLAGS := -g -Wall 
LDFLAGS :=  --shared

mingw : TARGET := ldebug.dll
mingw : CFLAGS += -I/usr/local/include
mingw : LDFLAGS += -L/usr/local/bin -llua52 -lws2_32

mingw : ldebug

linux : TARGET := ldebug.so
linux : CFLAGS += -I/usr/local/include
linux : LDFLAGS += -fPIC

linux : ldebug


ldebug : lsocket.c
	gcc -o $(TARGET) $(CFLAGS) $^ $(LDFLAGS) 

clean :
	rm -f ldebug.dll ldebug.so