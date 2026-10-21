#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
// Darwin arm64 passes variadic openat mode on the stack. Keep that ABI boundary in C;
// a fixed-signature managed P/Invoke of variadic openat can create files with wrong mode.
__attribute__((visibility("default")))
int gw_open_content_file(int directory, const char *name) {
    int fd = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != geteuid()) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

#include <stdlib.h>
#include <string.h>
static int private_directory(int fd) {
    struct stat info;
    return fstat(fd, &info) == 0 && S_ISDIR(info.st_mode) && info.st_uid == geteuid() && (info.st_mode & 0077) == 0;
}
__attribute__((visibility("default")))
int gw_open_private_root(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    char *copy = strdup(path);
    if (!copy) { close(fd); return -1; }
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part,".") || !strcmp(part,"..")) { free(copy); close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        close(fd); fd = next;
        if (fd < 0) { free(copy); return -1; }
    }
    free(copy);
    if (!private_directory(fd)) { close(fd); errno = EPERM; return -1; }
    return fd;
}
__attribute__((visibility("default")))
int gw_open_private_subdirectory(int parent, const char *name) {
    if (mkdirat(parent, name, 0700) != 0 && errno != EEXIST) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd >= 0 && !private_directory(fd)) { close(fd); errno = EPERM; return -1; }
    return fd;
}
__attribute__((visibility("default")))
int gw_write_checkpoint(int directory, const char *temporary, const unsigned char *data, int length) {
    if (length < 0 || length > 1024 * 1024) { errno = EFBIG; return -1; }
    int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int offset = 0;
    while (offset < length) {
        ssize_t n = write(fd, data + offset, (size_t)(length - offset));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); unlinkat(directory, temporary, 0); return -1; }
        offset += (int)n;
    }
    if (fsync(fd) != 0) { close(fd); unlinkat(directory, temporary, 0); return -1; }
    close(fd);
    if (renameat(directory, temporary, directory, "checkpoint.json") != 0) { unlinkat(directory, temporary, 0); return -1; }
    return fsync(directory);
}

#include <dirent.h>
typedef int (*gw_entry_callback)(const char *, int);
static int walk_content(int directory, const char *prefix, int depth, int *count, gw_entry_callback callback) {
    if (depth > 32) return -1;
    int duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (duplicate < 0) return -1;
    DIR *entries = fdopendir(duplicate);
    if (!entries) { close(duplicate); return -1; }
    int result = 0;
    errno = 0;
    for (struct dirent *entry = readdir(entries); entry; entry = readdir(entries)) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (++*count > 40000) { result = -1; break; }
        char path[1025];
        int length = snprintf(path, sizeof(path), "%s%s%s", prefix, *prefix ? "/" : "", entry->d_name);
        if (length < 0 || length >= (int)sizeof(path)) { result = -1; break; }
        struct stat info;
        if (fstatat(directory, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0 || info.st_uid != geteuid()) { result = -1; break; }
        int is_directory = S_ISDIR(info.st_mode);
        if ((!is_directory && (!S_ISREG(info.st_mode) || info.st_nlink != 1)) || !callback(path,is_directory)) { result = -1; break; }
        if (is_directory) {
            int child = openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            if (child < 0) { result = -1; break; }
            result = walk_content(child,path,depth+1,count,callback);
            close(child);
            if (result != 0) break;
        }
        errno = 0;
    }
    if (errno != 0) result = -1;
    closedir(entries);
    return result;
}
__attribute__((visibility("default")))
int gw_validate_content_tree(int directory, gw_entry_callback callback) {
    int count = 0;
    return walk_content(directory,"",0,&count,callback);
}

__attribute__((visibility("default")))
int gw_engine_cache_admit(int directory, const char *fingerprint, int maximum) {
    if (!fingerprint || strlen(fingerprint) != 64 || maximum < 1 || maximum > 32) { errno = EINVAL; return -1; }
    for (int i = 0; i < 64; i++)
        if (!((fingerprint[i] >= '0' && fingerprint[i] <= '9') || (fingerprint[i] >= 'a' && fingerprint[i] <= 'f'))) { errno = EINVAL; return -1; }
    int duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (duplicate < 0) return -1;
    DIR *entries = fdopendir(duplicate);
    if (!entries) { close(duplicate); return -1; }
    int count = 0, found = 0, result = 0;
    errno = 0;
    for (struct dirent *entry = readdir(entries); entry; entry = readdir(entries)) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (!strcmp(entry->d_name,"active-receipt.json")) {
            struct stat receipt;
            if (fstatat(directory, entry->d_name, &receipt, AT_SYMLINK_NOFOLLOW) != 0 ||
                !S_ISREG(receipt.st_mode) || receipt.st_uid != geteuid() || receipt.st_nlink != 1 ||
                (receipt.st_mode & 0077) != 0 || receipt.st_size < 0 || receipt.st_size > 65536) { result = -1; break; }
            errno = 0;
            continue;
        }
        if (strlen(entry->d_name) != 64) { result = -1; break; }
        for (int i = 0; i < 64; i++)
            if (!((entry->d_name[i] >= '0' && entry->d_name[i] <= '9') || (entry->d_name[i] >= 'a' && entry->d_name[i] <= 'f'))) { result = -1; break; }
        if (result != 0) break;
        struct stat info;
        if (fstatat(directory, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(info.st_mode) ||
            info.st_uid != geteuid() || (info.st_mode & 0077) != 0) { result = -1; break; }
        count++; if (!strcmp(entry->d_name,fingerprint)) found = 1;
        if (count > maximum) { result = -1; break; }
        errno = 0;
    }
    if (errno != 0) result = -1;
    closedir(entries);
    if (result == 0 && !found && count >= maximum) { errno = ENOSPC; result = -2; }
    return result;
}
