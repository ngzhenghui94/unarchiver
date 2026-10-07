#ifndef CLIBARCHIVE_H
#define CLIBARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The macOS SDK ships libarchive as a system dylib but does not ship its
 * public C headers. Keep this declaration surface limited to the stable
 * writer/entry APIs used by Compressor.
 */
typedef struct archive archive;
typedef struct archive_entry archive_entry;
typedef int64_t la_int64_t;
typedef int64_t la_ssize_t;

enum {
    CLIB_ARCHIVE_OK = 0,
    CLIB_ARCHIVE_IFREG = 0100000,
    CLIB_ARCHIVE_IFDIR = 0040000,
    CLIB_ARCHIVE_IFLNK = 0120000
};

archive *archive_write_new(void);
int archive_write_set_format_zip(archive *);
int archive_write_set_option(archive *, const char *module, const char *option, const char *value);
int archive_write_set_passphrase(archive *, const char *passphrase);
int archive_write_open_filename(archive *, const char *filename);
la_ssize_t archive_write_data(archive *, const void *buffer, size_t length);
int archive_write_header(archive *, archive_entry *);
int archive_write_finish_entry(archive *);
int archive_write_close(archive *);
int archive_write_free(archive *);
const char *archive_error_string(archive *);

archive_entry *archive_entry_new(void);
void archive_entry_free(archive_entry *);
void archive_entry_set_pathname(archive_entry *, const char *pathname);
void archive_entry_set_filetype(archive_entry *, mode_t filetype);
void archive_entry_set_perm(archive_entry *, mode_t perm);
void archive_entry_set_size(archive_entry *, la_int64_t size);
void archive_entry_set_mtime(archive_entry *, time_t mtime, long nanoseconds);
void archive_entry_set_symlink(archive_entry *, const char *target);

#ifdef __cplusplus
}
#endif

#endif /* CLIBARCHIVE_H */
