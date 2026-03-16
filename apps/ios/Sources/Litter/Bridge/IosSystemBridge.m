#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <TargetConditionals.h>
#include <Foundation/Foundation.h>

#if TARGET_OS_SIMULATOR
// ── Simulator path ──────────────────────────────────────────────────────────
// The iOS Simulator runs as a macOS process, so posix_spawn/popen work fine.
// ios_system is not linked for simulator (its perl xcframeworks lack that
// slice), so we use popen here instead.

void codex_ios_system_init(void) {}

NSString *codex_ios_default_cwd(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[@"home/codex", @"tmp", @"var/log", @"etc"];
    for (NSString *dir in dirs) {
        NSString *path = [docs stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return [docs stringByAppendingPathComponent:@"home/codex"];
}

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
extern void ios_switchSession(const void *sessionid);
extern void ios_setContext(const void *context);
extern __thread void *thread_context;
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

/// Returns the sandbox root (~/Documents), creating a Unix-like directory layout inside it.
static NSString *codex_sandbox_root(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        @"home/codex",
        @"tmp",
        @"var/log",
        @"etc",
    ];
    for (NSString *dir in dirs) {
        NSString *path = [docs stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    return docs;
}

static FILE *codex_ios_command_stdin(void) {
    static FILE *nullInput = NULL;
    if (nullInput == NULL) {
        nullInput = fopen("/dev/null", "r");
    }
    return nullInput != NULL ? nullInput : stdin;
}

static const char *codex_ios_session_name(void) {
    static __thread char *sessionName = NULL;
    if (sessionName == NULL) {
        char buffer[64];
        snprintf(buffer, sizeof(buffer), "codex_session_%p", (void *)pthread_self());
        sessionName = strdup(buffer);
    }
    return sessionName;
}

/// Returns the default working directory for codex sessions (/home/codex inside the sandbox).
NSString *codex_ios_default_cwd(void) {
    NSString *root = codex_sandbox_root();
    if (!root) return nil;
    return [root stringByAppendingPathComponent:@"home/codex"];
}

void codex_ios_system_init(void) {
    initializeEnvironment();
    codex_load_command_list(@"commandDictionary");
    codex_load_command_list(@"extraCommandsDictionary");

    // Set up the sandbox filesystem layout.
    NSString *root = codex_sandbox_root();

    // Configure environment for bundled tools.
    NSString *home = NSHomeDirectory();
    if (home) {
        // SSH/curl config directories.
        setenv("SSH_HOME", [root stringByAppendingPathComponent:@"home/codex"].UTF8String, 0);
        setenv("CURL_HOME", [root stringByAppendingPathComponent:@"home/codex"].UTF8String, 0);
    }
}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    NSLog(@"[ios-system] run cmd='%s' cwd='%s'", cmd, cwd ? cwd : "(null)");

    // ios_system treats both session IDs and session contexts as C strings and
    // compares them with strcmp(). Using an Objective-C object pointer here
    // leads to undefined behavior once signal handling checks the session.
    const char *sessionName = codex_ios_session_name();
    ios_setContext(NULL);
    thread_context = NULL;
    ios_switchSession(sessionName);
    ios_setContext(sessionName);
    thread_context = (void *)sessionName;

    int old_cwd_fd = open(".", O_RDONLY);
    if (cwd) {
        // Ensure the cwd exists (iOS temp dirs may not be pre-created).
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cwdStr = [NSString stringWithUTF8String:cwd];
        if (![fm fileExistsAtPath:cwdStr]) {
            [fm createDirectoryAtPath:cwdStr withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (chdir(cwd) != 0) {
            NSLog(@"[ios-system] chdir FAILED errno=%d (%s) for cwd='%s', falling back to /home/codex", errno, strerror(errno), cwd);
            NSString *fallback = codex_ios_default_cwd();
            if (!fallback || chdir(fallback.UTF8String) != 0) {
                NSLog(@"[ios-system] fallback chdir also FAILED");
                if (old_cwd_fd >= 0) close(old_cwd_fd);
                return -1;
            }
        }
    }

    // Capture output via a temp file. We intentionally NEVER fclose the FILE* —
    // ios_system's background thread cleanup may still reference it.
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
    ios_setStreams(codex_ios_command_stdin(), wf, wf);
    int code = ios_system(cmd);
    joinMainThread = savedJoin;
    fflush(wf);
    ios_setStreams(stdin, stdout, stderr);

    // Read captured output.
    NSData *data = [NSData dataWithContentsOfFile:tmpPath];
    unlink(tmpPath.UTF8String);

    size_t total = 0;
    char *buf = NULL;
    if (data.length > 0) {
        buf = malloc(data.length + 1);
        if (buf) {
            memcpy(buf, data.bytes, data.length);
            total = data.length;
        }
    }

    NSLog(@"[ios-system] code=%d output_len=%zu for cmd='%s'", code, total, cmd);

    if (old_cwd_fd >= 0) {
        fchdir(old_cwd_fd);
        close(old_cwd_fd);
    }

    if (buf && total > 0) {
        buf[total] = '\0';
        *output = buf;
        *output_len = total;
    } else {
        free(buf);
    }
    return code;
}

#endif
