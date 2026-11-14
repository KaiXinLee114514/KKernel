#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct _FILE FILE;
extern FILE *stdin, *stdout, *stderr;
#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
FILE *fopen(const char *, const char *);
int   fclose(FILE *);
int   fflush(FILE *);
int   fgetc(FILE *);
int   getc(FILE *);
int   fputc(int, FILE *);
int   putc(int, FILE *);
char *fgets(char *, int, FILE *);
int   fputs(const char *, FILE *);
int   putchar(int);
int   puts(const char *);
int   printf(const char *, ...);
int   fprintf(FILE *, const char *, ...);
int   sprintf(char *, const char *, ...);
int   snprintf(char *, size_t, const char *, ...);
int   vprintf(const char *, va_list);
int   vfprintf(FILE *, const char *, va_list);
int   vsnprintf(char *, size_t, const char *, va_list);
size_t fread(void *, size_t, size_t, FILE *);
size_t fwrite(const void *, size_t, size_t, FILE *);
int   fseek(FILE *, long, int);
long  ftell(FILE *);
void  rewind(FILE *);
int   feof(FILE *);
int   ferror(FILE *);
int   fileno(FILE *);
int   ungetc(int, FILE *);
void  perror(const char *);
int   remove(const char *);
int   rename(const char *, const char *);
#endif
