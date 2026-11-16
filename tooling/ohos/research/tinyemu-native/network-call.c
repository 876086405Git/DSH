#include "slirp/slirp.h"
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    int pair[2]; struct socket so = {0};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return 64;
    so.s=pair[0];close(pair[1]);
    ssize_t result=slirp_send(&so,"x",1,0);int error=errno;
    close(pair[0]);
    printf("{\"hostSurvived\":true,\"result\":%ld,\"errno\":%d}\n",(long)result,error);
    return result == -1 && error == EPIPE ? 0 : 1;
}
