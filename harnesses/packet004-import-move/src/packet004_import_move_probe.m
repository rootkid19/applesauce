#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

static void printUsage(void) {
    fprintf(stderr, "usage: packet004_import_move_probe <copy|move|coord-copy|coord-move> <source-path-or-file-url> <target-path-or-file-url>\n");
}

static NSURL *URLFromArgument(NSString *arg, NSString *label) {
    if (arg.length == 0) {
        fprintf(stderr, "%s argument is empty\n", label.UTF8String);
        return nil;
    }

    if ([arg hasPrefix:@"file://"]) {
        NSURL *url = [NSURL URLWithString:arg];
        if (url == nil || !url.isFileURL || url.path.length == 0 || url.host.length != 0) {
            fprintf(stderr, "%s must be a local file URL or absolute path: %s\n", label.UTF8String, arg.UTF8String);
            return nil;
        }
        return url;
    }

    if (![arg hasPrefix:@"/"]) {
        fprintf(stderr, "%s must be absolute: %s\n", label.UTF8String, arg.UTF8String);
        return nil;
    }

    return [NSURL fileURLWithPath:arg];
}

static void printURLState(NSString *label, NSURL *url) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:url.path isDirectory:&isDir];
    printf("%s.exists=%s\n", label.UTF8String, exists ? "1" : "0");
    printf("%s.isDir=%s\n", label.UTF8String, isDir ? "1" : "0");

    if (!exists) {
        return;
    }

    NSError *error = nil;
    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:url.path error:&error];
    if (attrs == nil) {
        printf("%s.attributesError=%s\n", label.UTF8String, error.localizedDescription.UTF8String ?: "(unknown)");
        return;
    }

    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    printf("%s.size=%llu\n", label.UTF8String, size == nil ? 0ULL : size.unsignedLongLongValue);
    printf("%s.mtime=%s\n", label.UTF8String, mtime == nil ? "" : mtime.description.UTF8String);

    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) == 0) {
        printf("%s.dev=%llu\n", label.UTF8String, (unsigned long long)st.st_dev);
        printf("%s.ino=%llu\n", label.UTF8String, (unsigned long long)st.st_ino);
        printf("%s.mode=%o\n", label.UTF8String, st.st_mode);
    }
}

static BOOL runPlainOperation(NSString *mode, NSURL *source, NSURL *target, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([mode isEqualToString:@"copy"]) {
        return [fm copyItemAtURL:source toURL:target error:error];
    }
    if ([mode isEqualToString:@"move"]) {
        return [fm moveItemAtURL:source toURL:target error:error];
    }
    return NO;
}

static BOOL runCoordinatedOperation(NSString *mode, NSURL *source, NSURL *target, NSError **error) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block BOOL ok = NO;
    __block NSError *operationError = nil;

    [coordinator coordinateReadingItemAtURL:source
                                    options:0
                                      error:error
                                 byAccessor:^(NSURL *newSource) {
        if ([mode isEqualToString:@"coord-copy"]) {
            ok = [[NSFileManager defaultManager] copyItemAtURL:newSource toURL:target error:&operationError];
        } else if ([mode isEqualToString:@"coord-move"]) {
            ok = [[NSFileManager defaultManager] moveItemAtURL:newSource toURL:target error:&operationError];
        } else {
            operationError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                 code:NSFeatureUnsupportedError
                                             userInfo:@{NSLocalizedDescriptionKey: @"unknown coordinated operation"}];
            ok = NO;
        }
    }];

    if (!ok && operationError != nil && error != NULL && *error == nil) {
        *error = operationError;
    }

    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            printUsage();
            return 2;
        }

        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *sourceArg = [NSString stringWithUTF8String:argv[2]];
        NSString *targetArg = [NSString stringWithUTF8String:argv[3]];

        BOOL validMode = [mode isEqualToString:@"copy"] ||
                         [mode isEqualToString:@"move"] ||
                         [mode isEqualToString:@"coord-copy"] ||
                         [mode isEqualToString:@"coord-move"];
        if (!validMode) {
            printUsage();
            return 2;
        }

        NSURL *source = URLFromArgument(sourceArg, @"source");
        NSURL *target = URLFromArgument(targetArg, @"target");
        if (source == nil || target == nil) {
            return 2;
        }

        printf("mode=%s\n", mode.UTF8String);
        printf("pid=%d\n", getpid());
        printf("source=%s\n", source.path.UTF8String);
        printf("target=%s\n", target.path.UTF8String);
        printURLState(@"source.before", source);
        printURLState(@"target.before", target);

        NSError *error = nil;
        BOOL ok = NO;
        if ([mode hasPrefix:@"coord-"]) {
            ok = runCoordinatedOperation(mode, source, target, &error);
        } else {
            ok = runPlainOperation(mode, source, target, &error);
        }

        printf("result=%s\n", ok ? "success" : "failure");
        if (error != nil) {
            printf("error.domain=%s\n", error.domain.UTF8String);
            printf("error.code=%ld\n", (long)error.code);
            printf("error.description=%s\n", error.localizedDescription.UTF8String ?: "(unknown)");
        }

        printURLState(@"source.after", source);
        printURLState(@"target.after", target);
        return ok ? 0 : 1;
    }
}
