#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <TargetConditionals.h>
#include <Foundation/Foundation.h>

#if TARGET_OS_SIMULATOR
// ── Simulator path ──────────────────────────────────────────────────────────
// The iOS Simulator runs as a macOS process, so posix_spawn/popen work fine.
// ios_system is not linked for simulator (its perl xcframeworks lack that
// slice), so we use popen here instead.

void codex_ios_system_init(void) {}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    int old_cwd_fd = open(".", O_RDONLY);
    if (cwd) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cwdStr = [NSString stringWithUTF8String:cwd];
        if (![fm fileExistsAtPath:cwdStr]) {
            [fm createDirectoryAtPath:cwdStr withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (chdir(cwd) != 0) {
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            if (docs && chdir(docs.UTF8String) != 0) {
                if (old_cwd_fd >= 0) close(old_cwd_fd);
                return -1;
            }
        }
    }

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    size_t buf_size = 8192;
    char *buf = malloc(buf_size);
    if (!buf) {
        pclose(fp);
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    size_t total = 0;
    size_t n;
    while ((n = fread(buf + total, 1, buf_size - total - 1, fp)) > 0) {
        total += n;
        if (total + 256 >= buf_size) {
            buf_size *= 2;
            char *nb = realloc(buf, buf_size);
            if (!nb) break;
            buf = nb;
        }
    }
    int code = pclose(fp);
    if (old_cwd_fd >= 0) {
        fchdir(old_cwd_fd);
        close(old_cwd_fd);
    }
    buf[total] = '\0';
    *output = buf;
    *output_len = total;
    return WEXITSTATUS(code);
}

#else
// ── Device path ─────────────────────────────────────────────────────────────
// Use ios_system (linked via the ios_system Swift Package) for fork-free exec.

extern int ios_system(const char *cmd);
extern FILE *ios_popen(const char *command, const char *type);
extern void ios_setStreams(FILE *in_stream, FILE *out_stream, FILE *err_stream);
extern void ios_waitpid(pid_t pid);
extern pid_t ios_currentPid(void);
extern bool joinMainThread;
extern void initializeEnvironment(void);
extern NSError *addCommandList(NSString *fileLocation);

static NSString *codex_find_command_plist(NSString *name) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithCapacity:4];
    NSString *path = [mainBundle pathForResource:name ofType:@"plist"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    path = [mainBundle pathForResource:name ofType:@"plist" inDirectory:@"ios_system"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    path = [mainBundle pathForResource:name ofType:@"plist" inDirectory:@"Resources/ios_system"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    NSString *resourceRoot = [mainBundle resourcePath];
    if (resourceRoot.length > 0) {
        path = [resourceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", name]];
        [candidates addObject:path];
    }
    for (NSString *path in candidates) {
        if (path != nil && path.length > 0) {
            return path;
        }
    }
    return nil;
}

static void codex_load_command_list(NSString *name) {
    NSString *path = codex_find_command_plist(name);
    if (path == nil) {
        NSLog(@"[codex-ios] %@.plist not found in app bundle", name);
        return;
    }
    NSError *error = addCommandList(path);
    if (error != nil) {
        NSLog(@"[codex-ios] failed to load %@.plist: %@", name, error.localizedDescription);
    } else {
        NSLog(@"[codex-ios] loaded %@.plist", name);
    }
}

void codex_ios_system_init(void) {
    initializeEnvironment();
    codex_load_command_list(@"commandDictionary");
    codex_load_command_list(@"extraCommandsDictionary");
}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    NSLog(@"[ios-system] run cmd='%s' cwd='%s'", cmd, cwd ? cwd : "(null)");

    int old_cwd_fd = open(".", O_RDONLY);
    if (cwd) {
        // Ensure the cwd exists (iOS temp dirs may not be pre-created).
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cwdStr = [NSString stringWithUTF8String:cwd];
        if (![fm fileExistsAtPath:cwdStr]) {
            [fm createDirectoryAtPath:cwdStr withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (chdir(cwd) != 0) {
            NSLog(@"[ios-system] chdir FAILED errno=%d (%s) for cwd='%s', falling back to Documents", errno, strerror(errno), cwd);
            // Fall back to the app's Documents directory.
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            if (docs && chdir(docs.UTF8String) != 0) {
                NSLog(@"[ios-system] fallback chdir to Documents also FAILED");
                if (old_cwd_fd >= 0) close(old_cwd_fd);
                return -1;
            }
        }
    }

    // Use ios_setStreams to capture output via a temp file.
    // joinMainThread=true makes ios_system block until all sub-commands finish.
    // We intentionally NEVER fclose the FILE* — ios_system's background
    // thread cleanup accesses it after return and crashes in flockfile if
    // we close it. The FILE* is leaked but the temp file is unlinked, so
    // the kernel reclaims it when all fds/FILE*s are released naturally.
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codex_exec_%u.tmp", arc4random()]];
    FILE *wf = fopen(tmpPath.UTF8String, "w");
    if (!wf) {
        NSLog(@"[ios-system] tmpfile FAILED for cmd='%s'", cmd);
        if (old_cwd_fd >= 0) { fchdir(old_cwd_fd); close(old_cwd_fd); }
        return -1;
    }

    bool savedJoin = joinMainThread;
    joinMainThread = true;
    ios_setStreams(NULL, wf, wf);
    int code = ios_system(cmd);
    joinMainThread = savedJoin;
    fflush(wf);
    // DO NOT fclose(wf) — ios_system threads may still reference it.
    ios_setStreams(NULL, stdout, stderr);

    NSLog(@"[ios-system] ios_system code=%d for cmd='%s'", code, cmd);

    if (old_cwd_fd >= 0) {
        fchdir(old_cwd_fd);
        close(old_cwd_fd);
    }

    // Read the output from the temp file via a separate fd.
    NSData *data = [NSData dataWithContentsOfFile:tmpPath];
    unlink(tmpPath.UTF8String);

    if (data.length == 0) {
        return code;
    }

    char *buf = malloc(data.length + 1);
    if (!buf) { return code; }
    memcpy(buf, data.bytes, data.length);
    buf[data.length] = '\0';
    *output = buf;
    *output_len = data.length;
    return code;
}

#endif
