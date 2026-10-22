/* The C side of gffs: PCRE2 for the regex engine, and the few POSIX calls
   the Goose `os` module does not have (entry types while listing a
   directory, isatty, fstat of stdin, realpath, errno for error messages).

   Values cross as spec §7.10 says: a `u8[:]` is { data, len }, a `bool` a
   uint8_t, a `u8[>..]&` a gs_rref that C appends to with gs_bld_append. */

#include "goose.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

typedef struct { const uint8_t *data; int64_t len; } ffs_slice;
typedef struct { int64_t start; int64_t end; } ffs_span;

/* A slice as a NUL-terminated path; false if it does not fit or holds a NUL. */
static int ffs_cpath(ffs_slice s, char *buf) {
    if (s.len <= 0 || s.len >= PATH_MAX || memchr(s.data, 0, (size_t)s.len)) return 0;
    memcpy(buf, s.data, (size_t)s.len);
    buf[s.len] = 0;
    return 1;
}

/* ---- Regex --------------------------------------------------------------

   One pattern per process, compiled once before the search starts. The
   match data is per thread, so the search could run on several. UTF mode
   with invalid UTF allowed: a file that is not UTF-8 still searches, and
   \w, \b, \d and -i are Unicode-aware as in ripgrep. */

static pcre2_code *ffs_re;
static _Thread_local pcre2_match_data *ffs_md;

uint8_t ffs_re_compile(ffs_slice pat, uint8_t ignore_case, gs_rref err) {
    /* ALT_CIRCUMFLEX: `^` also matches after a newline that ends the
       subject, which is where an empty line starts when the search looks
       at one line alone (search.goose). */
    uint32_t opts = PCRE2_UTF | PCRE2_MATCH_INVALID_UTF | PCRE2_UCP | PCRE2_MULTILINE |
                    PCRE2_ALT_CIRCUMFLEX;
    if (ignore_case) opts |= PCRE2_CASELESS;
    int code = 0;
    PCRE2_SIZE offset = 0;
    /* An empty pattern still needs a valid pointer. */
    PCRE2_SPTR p = pat.len > 0 ? (PCRE2_SPTR)pat.data : (PCRE2_SPTR) "";
    ffs_re = pcre2_compile(p, (PCRE2_SIZE)pat.len, opts, &code, &offset, NULL);
    if (!ffs_re) {
        PCRE2_UCHAR msg[256];
        int n = pcre2_get_error_message(code, msg, sizeof msg);
        if (n > 0) gs_bld_append(err, msg, n);
        return 0;
    }
    /* No JIT on this machine is not an error: the interpreter still works. */
    pcre2_jit_compile(ffs_re, PCRE2_JIT_COMPLETE);
    return 1;
}

/* The leftmost match in text[from..], or false. 2 means PCRE2 gave up
   (its match limit): not "no match", the caller reports it. */
uint8_t ffs_re_find(ffs_slice text, int64_t from, ffs_span *out) {
    if (!ffs_md) ffs_md = pcre2_match_data_create_from_pattern(ffs_re, NULL);
    PCRE2_SPTR s = text.len > 0 ? (PCRE2_SPTR)text.data : (PCRE2_SPTR) "";
    int rc = pcre2_match(ffs_re, s, (PCRE2_SIZE)text.len, (PCRE2_SIZE)from, 0, ffs_md, NULL);
    if (rc == PCRE2_ERROR_NOMATCH) return 0;
    if (rc < 0) return 2;
    PCRE2_SIZE *ov = pcre2_get_ovector_pointer(ffs_md);
    out->start = (int64_t)ov[0];
    out->end = (int64_t)ov[1];
    return 1;
}

/* ---- Files ------------------------------------------------------------- */

/* Appends one line per entry, "d name" or "f name": directories and
   regular files only, so symbolic links and special files are left out, as
   ripgrep leaves them out without -L. Names holding a newline are left out
   too. False if the directory cannot be read. */
uint8_t ffs_list_dir(ffs_slice path, gs_rref out) {
    char p[PATH_MAX];
    if (!ffs_cpath(path, p)) return 0;
    DIR *d = opendir(p);
    if (!d) return 0;
    int fd = dirfd(d);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        const char *n = e->d_name;
        if (n[0] == '.' && (!n[1] || (n[1] == '.' && !n[2]))) continue;
        size_t len = strlen(n);
        if (memchr(n, '\n', len)) continue;
        int kind = 0;
        if (e->d_type == DT_DIR) kind = 'd';
        else if (e->d_type == DT_REG) kind = 'f';
        else if (e->d_type == DT_UNKNOWN) {
            struct stat st;
            if (fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0) {
                if (S_ISDIR(st.st_mode)) kind = 'd';
                else if (S_ISREG(st.st_mode)) kind = 'f';
            }
        }
        if (!kind) continue;
        char head[2] = { (char)kind, ' ' };
        gs_bld_append(out, head, 2);
        gs_bld_append(out, n, (int64_t)len);
        gs_bld_append(out, "\n", 1);
    }
    closedir(d);
    return 1;
}

/* What `path` is, following links: 1 a file (or anything not a directory),
   2 a directory, or -errno. */
int64_t ffs_stat(ffs_slice path) {
    char p[PATH_MAX];
    if (!ffs_cpath(path, p)) return -ENOENT;
    struct stat st;
    if (stat(p, &st) != 0) return -errno;
    return S_ISDIR(st.st_mode) ? 2 : 1;
}

/* Whether anything is at `path`, a broken link included. */
uint8_t ffs_exists(ffs_slice path) {
    char p[PATH_MAX];
    struct stat st;
    return ffs_cpath(path, p) && lstat(p, &st) == 0;
}

/* Appends the whole file, and returns 0, or errno (nothing appended). */
int64_t ffs_read_file(ffs_slice path, gs_rref out) {
    char p[PATH_MAX];
    if (!ffs_cpath(path, p)) return ENOENT;
    int fd = open(p, O_RDONLY);
    if (fd < 0) return errno;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return e;
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        return EISDIR;
    }
    /* Straight into the builder: its bytes go at its stack's top, which
       has gigabytes of address space reserved behind it, committed as it
       is touched. Then the top and the count move past what was read, as
       gs_bld_append would move them. Read until end of file: the size may
       change, and pipes have none. */
    for (;;) {
        ssize_t n = read(fd, out.stk->top, 1 << 20);
        if (n < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            close(fd);
            /* Nothing appended: what was read stays beyond the top. */
            return e;
        }
        if (n == 0) break;
        out.stk->top += n;
        out.hdr->len += n;
    }
    close(fd);
    return 0;
}

/* Appends the absolute path with links resolved; false if there is none. */
uint8_t ffs_realpath(ffs_slice path, gs_rref out) {
    char p[PATH_MAX], r[PATH_MAX];
    if (!ffs_cpath(path, p) || !realpath(p, r)) return 0;
    gs_bld_append(out, r, (int64_t)strlen(r));
    return 1;
}

/* Appends the C library's message for an errno, ripgrep-style. */
void ffs_strerror(int64_t err, gs_rref out) {
    const char *m = strerror((int)err);
    gs_bld_append(out, m, (int64_t)strlen(m));
}

/* ---- Streams ----------------------------------------------------------- */

uint8_t ffs_stdout_is_tty(void) { return isatty(1) != 0; }

/* Standard input is something to search: a pipe, a file or a socket, not a
   terminal and not /dev/null. */
uint8_t ffs_stdin_readable(void) {
    struct stat st;
    if (fstat(0, &st) != 0) return 0;
    return S_ISFIFO(st.st_mode) || S_ISREG(st.st_mode) || S_ISSOCK(st.st_mode);
}

/* Writes all of it to fd 1; false once the reader is gone (`| head`). */
uint8_t ffs_write_stdout(ffs_slice s) {
    const uint8_t *p = s.data;
    int64_t left = s.len;
    while (left > 0) {
        ssize_t n = write(1, p, (size_t)left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        p += n;
        left -= n;
    }
    return 1;
}

void ffs_write_stderr(ffs_slice s) {
    const uint8_t *p = s.data;
    int64_t left = s.len;
    while (left > 0) {
        ssize_t n = write(2, p, (size_t)left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        p += n;
        left -= n;
    }
}

/* ---- Bytes ------------------------------------------------------------

   The scans over whole files, with the C library's vectorized memchr. */

/* The first `c` in data[from..], or data.len. */
int64_t ffs_find_byte(ffs_slice data, int64_t from, uint8_t c) {
    if (from >= data.len) return data.len;
    const uint8_t *p = memchr(data.data + from, c, (size_t)(data.len - from));
    return p ? (int64_t)(p - data.data) : data.len;
}

/* How many times `c` is in `data`. */
int64_t ffs_count_byte(ffs_slice data, uint8_t c) {
    int64_t n = 0;
    const uint8_t *p = data.data, *end = data.data + data.len;
    while (p < end && (p = memchr(p, c, (size_t)(end - p))) != NULL) {
        n++;
        p++;
    }
    return n;
}

/* The default thread count, as ffs picks it: the performance cores on
   Apple silicon, where more threads mostly add kernel contention, and
   every logical CPU elsewhere. */
int64_t ffs_auto_jobs(void) {
#ifdef __APPLE__
    int n = 0;
    size_t len = sizeof n;
    if (sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, NULL, 0) == 0 && n > 0) return n;
#endif
    long c = sysconf(_SC_NPROCESSORS_ONLN);
    return c > 0 ? c : 1;
}
