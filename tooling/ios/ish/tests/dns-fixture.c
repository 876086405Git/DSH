#include "guest_dns.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
int dsh_dns_test_config(char *out, size_t capacity) {
 const char *mode=getenv("DSH_TEST_DNS");
 if(mode && !strcmp(mode,"absent"))return EHOSTUNREACH;
 const char *servers[]={mode && !strcmp(mode,"invalid") ? "192.0.2.1\nsearch injected" : mode && !strcmp(mode,"changed") ? "192.0.2.2" : "192.0.2.1", "2001:db8::53"};
 return dsh_dns_format(servers,2,out,capacity);
}
