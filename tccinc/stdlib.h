#ifndef _STDLIB_H
#define _STDLIB_H
#include <stddef.h>
#define RAND_MAX 0x7FFFFFFF
void  *malloc(size_t);
void  *calloc(size_t, size_t);
void  *realloc(void *, size_t);
void   free(void *);
int    atoi(const char *);
long   atol(const char *);
long   strtol(const char *, char **, int);
unsigned long      strtoul(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);
long long          strtoll(const char *, char **, int);
double strtod(const char *, char **);
float  strtof(const char *, char **);
int    abs(int);
long   labs(long);
void   exit(int);
char  *getenv(const char *);
int    system(const char *);
unsigned int rand(void);
void   srand(unsigned int);
void   qsort(void *, size_t, size_t, int (*)(const void *, const void *));
#endif
