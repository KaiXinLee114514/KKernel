#ifndef _UNISTD_H
#define _UNISTD_H
#include <stddef.h>
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_TRUNC  0x200
int   open(const char *, int, ...);
int   close(int);
int   read(int, void *, int);
int   write(int, const void *, int);
int   lseek(int, int, int);
int   unlink(const char *);
char *getcwd(char *, unsigned int);
char *realpath(const char *, char *);
int   execvp(const char *, char *const []);
int   getpid(void);
unsigned int sleep(unsigned int);
int   isatty(int);
char *strerror(int);
#endif
