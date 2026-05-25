#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static atomic_bool gStopRace = false;

static NSString *ArgValue(NSArray<NSString *> *args, NSString *name, NSString *fallback) {
    NSUInteger idx = [args indexOfObject:name];
    if (idx == NSNotFound || idx + 1 >= args.count) {
        return fallback;
    }
    return args[idx + 1];
}

static NSInteger ArgInteger(NSArray<NSString *> *args, NSString *name, NSInteger fallback) {
    NSString *value = ArgValue(args, name, nil);
    return value ? value.integerValue : fallback;
}

static NSString *StringOrNull(id obj) {
    if (!obj || obj == [NSNull null]) {
        return @"";
    }
    return [obj description] ?: @"";
}

static NSMutableDictionary *StatDictionary(NSString *path, BOOL follow) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"path"] = path ?: @"";
    d[@"follow"] = @(follow);

    struct stat st;
    int rc = follow ? stat(path.fileSystemRepresentation, &st) : lstat(path.fileSystemRepresentation, &st);
    if (rc != 0) {
        d[@"ok"] = @NO;
        d[@"errno"] = @(errno);
        d[@"error"] = [NSString stringWithUTF8String:strerror(errno)] ?: @"unknown";
        return d;
    }

    d[@"ok"] = @YES;
    d[@"dev"] = @((unsigned long long)st.st_dev);
    d[@"ino"] = @((unsigned long long)st.st_ino);
    d[@"mode"] = @((unsigned long long)st.st_mode);
    d[@"size"] = @((unsigned long long)st.st_size);
    d[@"mtime"] = @((long long)st.st_mtime);
    return d;
}

static BOOL SameIdentity(NSDictionary *a, NSDictionary *b) {
    if (![a[@"ok"] boolValue] || ![b[@"ok"] boolValue]) {
        return NO;
    }
    return [a[@"dev"] unsignedLongLongValue] == [b[@"dev"] unsignedLongLongValue] &&
           [a[@"ino"] unsignedLongLongValue] == [b[@"ino"] unsignedLongLongValue];
}

static NSString *ReadlinkString(NSString *path) {
    char buf[PATH_MAX];
    ssize_t n = readlink(path.fileSystemRepresentation, buf, sizeof(buf) - 1);
    if (n < 0) {
        return @"";
    }
    buf[n] = '\0';
    return [NSString stringWithUTF8String:buf] ?: @"";
}

static void EmitJSON(NSDictionary *dict) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!data) {
        fprintf(stdout, "{\"event\":\"json_error\",\"error\":\"%s\"}\n", error.localizedDescription.UTF8String ?: "unknown");
        fflush(stdout);
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static BOOL WriteText(NSString *path, NSString *text) {
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        EmitJSON(@{@"event": @"setup_error", @"path": path ?: @"", @"error": error.localizedDescription ?: @""});
    }
    return ok;
}

static NSString *MakeRoot(void) {
    NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"packet006-scopedbookmark.XXXXXX"];
    char buf[PATH_MAX];
    strlcpy(buf, templatePath.fileSystemRepresentation, sizeof(buf));
    char *made = mkdtemp(buf);
    if (!made) {
        return nil;
    }
    return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:made length:strlen(made)];
}

static void PrepareTree(NSString *root) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *stable = [root stringByAppendingPathComponent:@"stable.txt"];
    NSString *a = [root stringByAppendingPathComponent:@"A.txt"];
    NSString *b = [root stringByAppendingPathComponent:@"B.txt"];
    NSString *dirA = [root stringByAppendingPathComponent:@"dirA"];
    NSString *dirB = [root stringByAppendingPathComponent:@"dirB"];

    [fm createDirectoryAtPath:dirA withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:dirB withIntermediateDirectories:YES attributes:nil error:nil];
    WriteText(stable, @"packet006 stable\n");
    WriteText(a, @"packet006 identity A\n");
    WriteText(b, @"packet006 identity B\n");
    WriteText([dirA stringByAppendingPathComponent:@"race.txt"], @"packet006 dir identity A\n");
    WriteText([dirB stringByAppendingPathComponent:@"race.txt"], @"packet006 dir identity B\n");

    NSString *leaf = [root stringByAppendingPathComponent:@"symlink-leaf.txt"];
    NSString *raceLeaf = [root stringByAppendingPathComponent:@"race-link.txt"];
    NSString *raceDir = [root stringByAppendingPathComponent:@"race-dir"];
    NSString *raceLeafSwap = [root stringByAppendingPathComponent:@"race-link.swap"];
    NSString *raceDirSwap = [root stringByAppendingPathComponent:@"race-dir.swap"];
    unlink(leaf.fileSystemRepresentation);
    unlink(raceLeaf.fileSystemRepresentation);
    unlink(raceDir.fileSystemRepresentation);
    unlink(raceLeafSwap.fileSystemRepresentation);
    unlink(raceDirSwap.fileSystemRepresentation);
    symlink(a.fileSystemRepresentation, leaf.fileSystemRepresentation);
    symlink(a.fileSystemRepresentation, raceLeaf.fileSystemRepresentation);
    symlink(dirA.fileSystemRepresentation, raceDir.fileSystemRepresentation);
}

static NSString *TargetPathForMode(NSString *root, NSString *mode) {
    if ([mode isEqualToString:@"stable"]) {
        return [root stringByAppendingPathComponent:@"stable.txt"];
    }
    if ([mode isEqualToString:@"symlink-leaf"]) {
        return [root stringByAppendingPathComponent:@"symlink-leaf.txt"];
    }
    if ([mode isEqualToString:@"symlink-race"]) {
        return [root stringByAppendingPathComponent:@"race-link.txt"];
    }
    if ([mode isEqualToString:@"dir-race"]) {
        return [[root stringByAppendingPathComponent:@"race-dir"] stringByAppendingPathComponent:@"race.txt"];
    }
    if ([mode isEqualToString:@"hardlink"]) {
        NSString *hardlink = [root stringByAppendingPathComponent:@"hardlink-A.txt"];
        unlink(hardlink.fileSystemRepresentation);
        link([root stringByAppendingPathComponent:@"A.txt"].fileSystemRepresentation, hardlink.fileSystemRepresentation);
        return hardlink;
    }
    return [root stringByAppendingPathComponent:@"stable.txt"];
}

static void StartSymlinkRace(NSString *root, NSString *mode, useconds_t sleepUsec) {
    NSString *a = [root stringByAppendingPathComponent:@"A.txt"];
    NSString *b = [root stringByAppendingPathComponent:@"B.txt"];
    NSString *dirA = [root stringByAppendingPathComponent:@"dirA"];
    NSString *dirB = [root stringByAppendingPathComponent:@"dirB"];
    NSString *leaf = [root stringByAppendingPathComponent:@"race-link.txt"];
    NSString *dir = [root stringByAppendingPathComponent:@"race-dir"];
    NSString *leafSwap = [root stringByAppendingPathComponent:@"race-link.swap"];
    NSString *dirSwap = [root stringByAppendingPathComponent:@"race-dir.swap"];

    atomic_store(&gStopRace, false);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long i = 0;
        while (!atomic_load(&gStopRace)) {
            @autoreleasepool {
                NSString *linkPath = [mode isEqualToString:@"dir-race"] ? dir : leaf;
                NSString *swapPath = [mode isEqualToString:@"dir-race"] ? dirSwap : leafSwap;
                NSString *target = [mode isEqualToString:@"dir-race"] ? ((i % 2) ? dirB : dirA) : ((i % 2) ? b : a);
                unlink(swapPath.fileSystemRepresentation);
                if (symlink(target.fileSystemRepresentation, swapPath.fileSystemRepresentation) == 0) {
                    rename(swapPath.fileSystemRepresentation, linkPath.fileSystemRepresentation);
                    i++;
                }
                if (sleepUsec > 0) {
                    usleep(sleepUsec);
                }
            }
        }
    });
}

static NSMutableDictionary *ResourceSnapshot(NSURL *url) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!url) {
        return d;
    }

    NSArray<NSURLResourceKey> *keys = @[
        NSURLFileResourceIdentifierKey,
        NSURLVolumeIdentifierKey,
        NSURLIsSymbolicLinkKey,
        NSURLIsRegularFileKey,
        NSURLIsDirectoryKey
    ];
    for (NSURLResourceKey key in keys) {
        id value = nil;
        NSError *error = nil;
        if ([url getResourceValue:&value forKey:key error:&error]) {
            d[key] = StringOrNull(value);
        } else if (error) {
            d[[key stringByAppendingString:@".error"]] = error.localizedDescription ?: @"";
        }
    }
    return d;
}

static NSDictionary *RunOne(NSString *mode, NSString *targetPath, NSUInteger iteration) {
    NSURL *targetURL = [NSURL fileURLWithPath:targetPath];
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"event"] = @"iteration";
    event[@"mode"] = mode;
    event[@"iteration"] = @(iteration);
    event[@"target_path"] = targetPath;
    event[@"target_readlink"] = ReadlinkString(targetPath);
    event[@"pre_lstat"] = StatDictionary(targetPath, NO);
    event[@"pre_stat"] = StatDictionary(targetPath, YES);
    event[@"pre_resources"] = ResourceSnapshot(targetURL);

    NSError *bookmarkError = nil;
    NSData *bookmark = [targetURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                           includingResourceValuesForKeys:nil
                                            relativeToURL:nil
                                                    error:&bookmarkError];
    if (!bookmark) {
        event[@"bookmark_ok"] = @NO;
        event[@"bookmark_error_domain"] = bookmarkError.domain ?: @"";
        event[@"bookmark_error_code"] = @(bookmarkError.code);
        event[@"bookmark_error"] = bookmarkError.localizedDescription ?: @"";
        event[@"post_lstat"] = StatDictionary(targetPath, NO);
        event[@"post_stat"] = StatDictionary(targetPath, YES);
        event[@"sample_to_resolved_identity_comparable"] = @NO;
        event[@"sample_to_resolved_identity_diverged"] = @NO;
        return event;
    }

    event[@"bookmark_ok"] = @YES;
    event[@"bookmark_length"] = @(bookmark.length);

    BOOL stale = NO;
    NSError *resolveError = nil;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:bookmark
                                                options:NSURLBookmarkResolutionWithSecurityScope
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:&resolveError];
    event[@"resolve_stale"] = @(stale);
    if (!resolved) {
        event[@"resolve_ok"] = @NO;
        event[@"resolve_error_domain"] = resolveError.domain ?: @"";
        event[@"resolve_error_code"] = @(resolveError.code);
        event[@"resolve_error"] = resolveError.localizedDescription ?: @"";
    } else {
        BOOL accessed = [resolved startAccessingSecurityScopedResource];
        event[@"resolve_ok"] = @YES;
        event[@"resolved_path"] = resolved.path ?: @"";
        event[@"resolved_access_started"] = @(accessed);
        event[@"resolved_stat"] = StatDictionary(resolved.path, YES);
        event[@"resolved_resources"] = ResourceSnapshot(resolved);
        if (accessed) {
            [resolved stopAccessingSecurityScopedResource];
        }
    }

    event[@"post_lstat"] = StatDictionary(targetPath, NO);
    event[@"post_stat"] = StatDictionary(targetPath, YES);

    NSDictionary *pre = event[@"pre_stat"];
    NSDictionary *resolvedStat = event[@"resolved_stat"];
    BOOL comparable = [pre[@"ok"] boolValue] && resolvedStat && [resolvedStat[@"ok"] boolValue];
    BOOL diverged = [event[@"bookmark_ok"] boolValue] && [event[@"resolve_ok"] boolValue] &&
                    comparable && !SameIdentity(pre, resolvedStat);
    event[@"sample_to_resolved_identity_comparable"] = @(comparable);
    event[@"sample_to_resolved_identity_diverged"] = @(diverged);
    return event;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int i = 0; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]] ?: @""];
        }

        NSString *mode = ArgValue(args, @"--mode", @"stable");
        NSInteger iterations = ArgInteger(args, @"--iterations", [mode containsString:@"race"] ? 500 : 1);
        NSInteger raceSleepUsec = ArgInteger(args, @"--race-sleep-us", 100);
        NSString *root = ArgValue(args, @"--root", nil);
        if (!root || root.length == 0) {
            root = MakeRoot();
        }
        if (!root) {
            EmitJSON(@{@"event": @"fatal", @"error": @"mkdtemp failed", @"errno": @(errno)});
            return 2;
        }

        PrepareTree(root);
        NSString *targetPath = TargetPathForMode(root, mode);
        BOOL racing = [mode isEqualToString:@"symlink-race"] || [mode isEqualToString:@"dir-race"];
        if (racing) {
            StartSymlinkRace(root, mode, (useconds_t)MAX(0, raceSleepUsec));
        }

        EmitJSON(@{
            @"event": @"start",
            @"mode": mode,
            @"root": root,
            @"target_path": targetPath,
            @"iterations": @(iterations),
            @"race_sleep_us": @(raceSleepUsec),
            @"pid": @((int)getpid())
        });

        NSUInteger success = 0;
        NSUInteger failure = 0;
        NSUInteger divergence = 0;
        NSUInteger comparable = 0;
        NSUInteger preStatUnavailable = 0;
        NSUInteger resolvedStatUnavailable = 0;
        NSUInteger resolveFailure = 0;
        for (NSInteger i = 0; i < iterations; i++) {
            @autoreleasepool {
                NSDictionary *event = RunOne(mode, targetPath, (NSUInteger)i);
                if ([event[@"bookmark_ok"] boolValue]) {
                    success++;
                } else {
                    failure++;
                }
                if ([event[@"resolve_ok"] isEqual:@NO]) {
                    resolveFailure++;
                }
                if ([event[@"sample_to_resolved_identity_comparable"] boolValue]) {
                    comparable++;
                }
                if (![event[@"pre_stat"][@"ok"] boolValue]) {
                    preStatUnavailable++;
                }
                if ([event[@"bookmark_ok"] boolValue] && [event[@"resolve_ok"] boolValue] &&
                    ![event[@"resolved_stat"][@"ok"] boolValue]) {
                    resolvedStatUnavailable++;
                }
                if ([event[@"sample_to_resolved_identity_diverged"] boolValue]) {
                    divergence++;
                }
                EmitJSON(event);
            }
        }

        atomic_store(&gStopRace, true);
        usleep(20000);

        EmitJSON(@{
            @"event": @"summary",
            @"mode": mode,
            @"root": root,
            @"target_path": targetPath,
            @"iterations": @(iterations),
            @"bookmark_success": @(success),
            @"bookmark_failure": @(failure),
            @"resolve_failure": @(resolveFailure),
            @"sample_to_resolved_identity_comparable": @(comparable),
            @"sample_to_resolved_identity_divergence": @(divergence),
            @"pre_stat_unavailable": @(preStatUnavailable),
            @"resolved_stat_unavailable": @(resolvedStatUnavailable)
        });
    }
    return 0;
}
