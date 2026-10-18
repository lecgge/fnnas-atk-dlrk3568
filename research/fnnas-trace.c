#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/mount.h>
#include <mntent.h>
#include <dirent.h>

static int gfd = -1;
static __thread int busy = 0;

static void tr(const char *fmt, ...)
{
    if (busy) return;
    busy = 1;
    if (gfd < 0) {
        const char *p = getenv("FNNAS_TRACE");
        if (!p) p = "/var/log/fnnas-trace.log";
        gfd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (gfd >= 0) {
        char buf[3072];
        va_list ap; va_start(ap, fmt);
        int n = vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        if (n > 0) { if (n > (int)sizeof buf) n = (int)sizeof buf; if (write(gfd, buf, n) < 0) {} }
    }
    busy = 0;
}

/* 只记录与存储/vol/挂载相关的路径，避免日志爆炸 */
static int interesting(const char *p)
{
    if (!p || !*p) return 0;
    if (strstr(p, "vol")) return 1;
    if (strstr(p, "trim_")) return 1;
    if (strstr(p, "dm-")) return 1;
    if (strstr(p, "md127") || strstr(p, "md1")) return 1;
    if (strstr(p, "nvme")) return 1;
    if (strstr(p, "mtab") || strstr(p, "mounts") || strstr(p, "fstab")) return 1;
    return 0;
}

/* ---------------- popen / system ---------------- */
FILE *popen(const char *cmd, const char *mode)
{
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "popen");
    tr("[popen] %s\n", cmd ? cmd : "(null)");
    return real(cmd, mode);
}

int system(const char *cmd)
{
    static int (*real)(const char *);
    if (!real) real = dlsym(RTLD_NEXT, "system");
    tr("[system] %s\n", cmd ? cmd : "(null)");
    return real(cmd);
}

/* ---------------- stat 家族 ---------------- */
int stat(const char *path, struct stat *b)
{
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "stat");
    int r = real(path, b);
    if (interesting(path)) tr("[stat] %s -> %d\n", path, r);
    return r;
}

int lstat(const char *path, struct stat *b)
{
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "lstat");
    int r = real(path, b);
    if (interesting(path)) tr("[lstat] %s -> %d\n", path, r);
    return r;
}

int statx(int dirfd, const char *path, int flags, unsigned int mask, struct statx *b)
{
    static int (*real)(int, const char *, int, unsigned int, struct statx *);
    if (!real) real = dlsym(RTLD_NEXT, "statx");
    int r = real(dirfd, path, flags, mask, b);
    if (interesting(path)) tr("[statx] %s -> %d\n", path, r);
    return r;
}

int fstatat(int dirfd, const char *path, struct stat *b, int flags)
{
    static int (*real)(int, const char *, struct stat *, int);
    if (!real) real = dlsym(RTLD_NEXT, "fstatat");
    int r = real(dirfd, path, b, flags);
    if (interesting(path)) tr("[fstatat] %s -> %d\n", path, r);
    return r;
}

/* ---------------- 目录 / 路径 ---------------- */
char *realpath(const char *path, char *out)
{
    static char *(*real)(const char *, char *);
    if (!real) real = dlsym(RTLD_NEXT, "realpath");
    char *r = real(path, out);
    if (interesting(path)) tr("[realpath] %s -> %s\n", path ? path : "(null)", r ? r : "(NULL)");
    return r;
}

int mkdir(const char *path, mode_t m)
{
    static int (*real)(const char *, mode_t);
    if (!real) real = dlsym(RTLD_NEXT, "mkdir");
    int r = real(path, m);
    if (interesting(path)) tr("[mkdir] %s mode=%o -> %d\n", path, (unsigned)m, r);
    return r;
}

int open(const char *path, int flags, ...)
{
    static int (*real)(const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "open");
    mode_t m = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); }
    int r = real(path, flags, m);
    if (interesting(path)) tr("[open] %s flags=0x%x -> %d\n", path, flags, r);
    return r;
}

int openat(int dfd, const char *path, int flags, ...)
{
    static int (*real)(int, const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    mode_t m = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); }
    int r = real(dfd, path, flags, m);
    if (interesting(path)) tr("[openat] %s -> %d\n", path, r);
    return r;
}

int access(const char *path, int mode)
{
    static int (*real)(const char *, int);
    if (!real) real = dlsym(RTLD_NEXT, "access");
    int r = real(path, mode);
    if (interesting(path)) tr("[access] %s mode=%d -> %d\n", path, mode, r);
    return r;
}

/* ---------------- 挂载 ---------------- */
int mount(const char *src, const char *tgt, const char *type,
          unsigned long flags, const void *data)
{
    static int (*real)(const char *, const char *, const char *, unsigned long, const void *);
    if (!real) real = dlsym(RTLD_NEXT, "mount");
    tr("[mount] src=%s tgt=%s type=%s flags=0x%lx data=%s\n",
       src ? src : "", tgt ? tgt : "", type ? type : "(null)", flags, data ? (const char *)data : "(null)");
    return real(src, tgt, type, flags, data);
}

int umount2(const char *tgt, int flags)
{
    static int (*real)(const char *, int);
    if (!real) real = dlsym(RTLD_NEXT, "umount2");
    tr("[umount2] %s flags=%d\n", tgt ? tgt : "", flags);
    return real(tgt, flags);
}

FILE *setmntent(const char *f, const char *t)
{
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "setmntent");
    tr("[setmntent] %s\n", f ? f : "");
    return real(f, t);
}

DIR *opendir(const char *name)
{
    static DIR *(*real)(const char *);
    if (!real) real = dlsym(RTLD_NEXT, "opendir");
    if (interesting(name)) tr("[opendir] %s\n", name);
    return real(name);
}
