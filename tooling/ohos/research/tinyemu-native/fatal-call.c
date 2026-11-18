#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
#include "temu_embed.h"
#include "embed-fatal.h"
static void initialized(void *opaque) {
    int mode = *(int *)opaque;
    if (mode == 1) exit(23);
    if (mode == 2) abort();
    assert(mode != 3);
}
static int stop(void *opaque) { (void)opaque; return 0; }
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    int pair[2], mode=atoi(argv[2]);
    if (socketpair(AF_UNIX,SOCK_STREAM,0,pair)) return 65;
    int result=temu_embed_run_controlled(argv[1],pair[0],pair[0],initialized,stop,&mode);
    printf("{\"hostSurvived\":true,\"result\":%d,\"reason\":%d}\n",result,dsh_temu_fatal_reason);
    close(pair[0]);close(pair[1]);return result == -9 && dsh_temu_fatal_reason == mode ? 0 : 1;
}
