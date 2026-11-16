#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
static char target[4096];static int fault,flushes,closes;
void retire_test_config(const char *path,int mode){snprintf(target,sizeof(target),"%s",path);fault=mode;}
int retire_test_flushes(void){return flushes;}
int retire_test_closes(void){return closes;}
static int selected(FILE *f){char p[64],name[4096];snprintf(p,sizeof(p),"/proc/self/fd/%d",fileno(f));ssize_t n=readlink(p,name,sizeof(name)-1);if(n<0)return 0;name[n]=0;return !strcmp(target,name);}
int __real_fflush(FILE *);
int __real_fclose(FILE *);
int __wrap_fflush(FILE *f){if(f&&selected(f)){flushes++;if(fault==1){errno=EIO;return EOF;}}return __real_fflush(f);}
int __wrap_fclose(FILE *f){if(selected(f)){closes++;if(fault==3){errno=EIO;return EOF;}int r=__real_fclose(f);if(fault==2){errno=EIO;return EOF;}return r;}return __real_fclose(f);}
