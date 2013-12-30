#include <lua.h>
#include <lauxlib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef WIN32
#  include <windows.h>
#  include <winsock2.h>

static void
startup() {
	WORD wVersionRequested;
	WSADATA wsaData;
	int err;

	wVersionRequested = MAKEWORD(2, 2);

	err = WSAStartup(wVersionRequested, &wsaData);
	if (err != 0) {
		printf("WSAStartup failed with error: %d\n", err);
		exit(1);
    }
}

static void
yield() {
	Sleep(0);
}

#define EINTR WSAEINTR
#define EWOULDBLOCK WSAEWOULDBLOCK

#else

#include <sys/select.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

#define closesocket close

static void
startup() {
}

static void
yield() {
	sleep(0);
}

#endif

#define BUFFER_SIZE 1024

struct socket {
	int listen_fd;
	int fd;
	int closed;
};

static int
lstart(lua_State *L) {
	const char * addr = luaL_checkstring(L,1);
	int port = luaL_checkinteger(L,2);

	struct socket * s = lua_newuserdata(L, sizeof(*s));
	s->listen_fd = -1;
	s->fd = -1;
	s->closed = 0;

	int lfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	int reuse = 1;
	setsockopt(s->listen_fd, SOL_SOCKET, SO_REUSEADDR, (void *)&reuse, sizeof(int));

	struct sockaddr_in service;
 
	service.sin_family = AF_INET;
	service.sin_addr.s_addr = inet_addr(addr);
	service.sin_port = htons(port);

	if (bind(lfd, (const struct sockaddr *)&service, sizeof(service)) < 0) {
		closesocket(lfd);
		printf("bind() failed");
		exit(1);
	}
	if (listen(lfd, 1) < 0) {
		printf("listen(): Error");
		exit(1);
	}
	s->listen_fd = lfd;

	return 1;
}

static int
fdcanread(int fd) {
	fd_set rfds;
	struct timeval tv = {0,0};

	FD_ZERO(&rfds);
	FD_SET(fd, &rfds);

	return select(fd+1, &rfds, NULL, NULL, &tv) == 1;
}

static int
test(struct socket *s, const char * welcome, size_t sz) {
	if (s->closed) {
		closesocket(s->fd);
		s->fd = -1;
		s->closed = 0;
	}
	if (s->fd < 0) {
		if (fdcanread(s->listen_fd)) {
			s->fd = accept(s->listen_fd, NULL, NULL);
			if (s->fd < 0) {
				return -1;
			}
			send(s->fd , welcome , sz , 0 );
		}
	}
	if (fdcanread(s->fd)) {
		return s->fd;
	}
	return -1;
	
}

static int
lread(lua_State *L) {
	struct socket * s = lua_touserdata(L,1);
	if (s == NULL || s->listen_fd < 0) {
		return luaL_error(L, "start socket first");
	}
	size_t sz = 0;
	const char * welcome = luaL_checklstring(L,2,&sz);
	int fd = test(s, welcome,sz);
	if (fd >= 0) {
		char buffer[BUFFER_SIZE];
		int rd = recv(fd, buffer, BUFFER_SIZE, 0);
		if (rd <= 0) {
			s->closed = 1;
			lua_pushboolean(L, 0);
			return 1;
		}
		lua_pushlstring(L, buffer, rd);
		return 1;
	}
	return 0;
}

static int
lwrite(lua_State *L) {
	struct socket * s = lua_touserdata(L,1);
	if (s == NULL || s->listen_fd < 0 || s->fd < 0) {
		return luaL_error(L, "start socket first");
	}
	size_t sz = 0;
	const char * buffer = luaL_checklstring(L, 2, &sz);
	int p = 0;
	for (;;) {
		int wt = send(s->fd, buffer+p, sz-p, 0);
		if (wt < 0) {
			switch(errno) {
			case EWOULDBLOCK:
			case EINTR:
				continue;
			default:
				closesocket(s->fd);
				s->fd = -1;
				lua_pushboolean(L,0);
				return 1;
			}
		}
		if (wt == sz - p)
			break;
		p+=wt;
	}
	if (s->closed) {
		closesocket(s->fd);
		s->fd = -1;
		s->closed = 0;
	}

	return 0;
}

static int
lyield(lua_State *L) {
	yield();
	return 0;
}

int
luaopen_ldebug_socket(lua_State *L) {
	luaL_checkversion(L);
	startup();
	luaL_Reg l[] = {
		{ "start", lstart },
		{ "read", lread },
		{ "write", lwrite },
		{ "yield", lyield },
		{ NULL, NULL },
	};

	luaL_newlib(L,l);

	return 1;
}
