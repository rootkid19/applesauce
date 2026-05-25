#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSURL *URLFromArgument(const char *arg, NSString **errorString) {
    NSString *raw = [NSString stringWithUTF8String:arg];
    if (raw.length == 0) {
        if (errorString) {
            *errorString = @"empty URL/path argument";
        }
        return nil;
    }

    if ([raw hasPrefix:@"file://"]) {
        if (![raw hasPrefix:@"file:///"] && ![raw hasPrefix:@"file://localhost/"]) {
            if (errorString) {
                *errorString = @"file URL host must be empty or localhost";
            }
            return nil;
        }

        NSURL *url = [NSURL URLWithString:raw];
        NSString *urlPath = [url path];
        if (url && [url isFileURL] && urlPath.length > 0 && [urlPath hasPrefix:@"/"]) {
            NSString *host = [url host];
            if (host.length > 0 && ![host isEqualToString:@"localhost"]) {
                if (errorString) {
                    *errorString = @"file URL host must be empty or localhost";
                }
                return nil;
            }
            return url;
        }

        NSString *path = raw;
        if ([path hasPrefix:@"file://localhost"]) {
            path = [path substringFromIndex:[@"file://localhost" length]];
        } else {
            path = [path substringFromIndex:[@"file://" length]];
        }

        path = [path stringByRemovingPercentEncoding] ?: path;
        if (![path hasPrefix:@"/"]) {
            if (errorString) {
                *errorString = @"file URL did not resolve to an absolute local path";
            }
            return nil;
        }

        return [NSURL fileURLWithPath:[path stringByStandardizingPath]];
    }

    if ([raw containsString:@"://"]) {
        if (errorString) {
            *errorString = @"only local paths and file:// URLs are supported";
        }
        return nil;
    }

    return [NSURL fileURLWithPath:[raw stringByStandardizingPath]];
}

static NSString *StringFromArgument(const char *arg) {
    return [NSString stringWithUTF8String:arg];
}

static void PrintObject(NSString *label, id obj) {
    if (!obj) {
        printf("%s=(null)\n", [label UTF8String]);
        return;
    }

    printf("%s.class=%s\n", [label UTF8String], object_getClassName(obj));
    printf("%s.description=%s\n", [label UTF8String], [[obj description] UTF8String]);

    NSArray<NSString *> *selectors = @[
        @"url",
        @"promiseURL",
        @"scope",
        @"promiseScope",
        @"originalDocumentURLWrapper",
        @"providerIdentifier",
        @"identifier",
        @"domainIdentifier",
        @"path"
    ];

    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![obj respondsToSelector:selector]) {
            continue;
        }

        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(obj, selector);
        } @catch (NSException *exception) {
            printf("%s.%s.exception=%s\n", [label UTF8String], [selectorName UTF8String], [[exception reason] UTF8String]);
            continue;
        }

        printf("%s.%s=%s\n", [label UTF8String], [selectorName UTF8String], [[value description] UTF8String]);
    }
}

static BOOL WaitForSemaphore(dispatch_semaphore_t semaphore, int timeoutSeconds) {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSeconds * NSEC_PER_SEC);
    return dispatch_semaphore_wait(semaphore, deadline) == 0;
}

static id SharedDaemonConnection(void) {
    dlopen("/System/Library/Frameworks/FileProvider.framework/FileProvider", RTLD_NOW);

    Class connectionClass = NSClassFromString(@"FPDaemonConnection");
    if (!connectionClass) {
        fprintf(stderr, "missing FPDaemonConnection class\n");
        return nil;
    }

    SEL selector = NSSelectorFromString(@"sharedConnection");
    if (![connectionClass respondsToSelector:selector]) {
        fprintf(stderr, "FPDaemonConnection does not respond to sharedConnection\n");
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(connectionClass, selector);
}

static int RunList(void) {
    id connection = SharedDaemonConnection();
    if (!connection) {
        return 2;
    }

    printf("connection.class=%s\n", object_getClassName(connection));
    printf("connection.description=%s\n", [[connection description] UTF8String]);

    NSArray<NSString *> *selectorNames = @[
        @"providersCompletionHandler:",
        @"providerDomainsCompletionHandler:"
    ];

    __block int failures = 0;
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        printf("calling=%s\n", [selectorName UTF8String]);

        if (![connection respondsToSelector:selector]) {
            printf("result.%s=unsupported\n", [selectorName UTF8String]);
            failures++;
            continue;
        }

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        void (^completion)(id, id) = ^(id first, id second) {
            if ([first isKindOfClass:[NSError class]]) {
                printf("error.%s.first=%s\n", [selectorName UTF8String], [[first description] UTF8String]);
                failures++;
            }
            if ([second isKindOfClass:[NSError class]]) {
                printf("error.%s.second=%s\n", [selectorName UTF8String], [[second description] UTF8String]);
                failures++;
            }
            PrintObject([NSString stringWithFormat:@"first.%@", selectorName], first);
            PrintObject([NSString stringWithFormat:@"second.%@", selectorName], second);
            dispatch_semaphore_signal(semaphore);
        };

        ((void (*)(id, SEL, id))objc_msgSend)(connection, selector, completion);
        if (!WaitForSemaphore(semaphore, 30)) {
            printf("timeout.%s=30s\n", [selectorName UTF8String]);
            failures++;
        }
    }

    return failures == 0 ? 0 : 1;
}

static int RunWrapper(NSURL *url, BOOL readonly, int repeatCount) {
    dlopen("/System/Library/Frameworks/FileProvider.framework/FileProvider", RTLD_NOW);

    Class wrapperClass = NSClassFromString(@"FPSandboxingURLWrapper");
    if (!wrapperClass) {
        fprintf(stderr, "missing FPSandboxingURLWrapper class\n");
        return 2;
    }

    SEL selector = NSSelectorFromString(@"wrapperWithURL:readonly:error:");
    if (![wrapperClass respondsToSelector:selector]) {
        fprintf(stderr, "FPSandboxingURLWrapper does not respond to wrapperWithURL:readonly:error:\n");
        return 2;
    }

    int failures = 0;
    for (int i = 0; i < repeatCount; i++) {
        NSError *error = nil;
        id wrapper = ((id (*)(id, SEL, NSURL *, BOOL, NSError **))objc_msgSend)(wrapperClass, selector, url, readonly, &error);
        printf("iteration=%d\n", i);
        printf("url=%s\n", [[url path] UTF8String]);
        printf("readonly=%s\n", readonly ? "true" : "false");
        if (error) {
            printf("error=%s\n", [[error description] UTF8String]);
            failures++;
        }
        PrintObject(@"wrapper", wrapper);
    }

    return failures == 0 ? 0 : 1;
}

static int RunExtend(NSURL *url, NSString *providerID, NSString *consumerID, int repeatCount) {
    id connection = SharedDaemonConnection();
    if (!connection) {
        return 2;
    }

    SEL selector = NSSelectorFromString(@"extendSandboxForFileURL:fromProviderID:toConsumerID:completionHandler:");
    if (![connection respondsToSelector:selector]) {
        fprintf(stderr, "FPDaemonConnection does not respond to extendSandboxForFileURL:fromProviderID:toConsumerID:completionHandler:\n");
        return 2;
    }

    __block int failures = 0;
    for (int i = 0; i < repeatCount; i++) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        void (^completion)(id, NSError *) = ^(id wrapper, NSError *error) {
            printf("iteration=%d\n", i);
            printf("url=%s\n", [[url path] UTF8String]);
            printf("providerID=%s\n", [providerID UTF8String]);
            printf("consumerID=%s\n", [consumerID UTF8String]);
            if (error) {
                printf("error=%s\n", [[error description] UTF8String]);
                failures++;
            }
            PrintObject(@"wrapper", wrapper);
            dispatch_semaphore_signal(semaphore);
        };

        ((void (*)(id, SEL, NSURL *, NSString *, NSString *, id))objc_msgSend)(connection, selector, url, providerID, consumerID, completion);
        if (!WaitForSemaphore(semaphore, 30)) {
            printf("iteration=%d\n", i);
            printf("timeout=30s\n");
            failures++;
        }
    }

    return failures == 0 ? 0 : 1;
}

static void Usage(const char *argv0) {
    fprintf(stderr,
            "usage:\n"
            "  %s list\n"
            "  %s wrapper <file-url-or-path> [readonly|readwrite] [repeat]\n"
            "  %s extend <file-url-or-path> <provider-id> <consumer-id> [repeat]\n",
            argv0, argv0, argv0);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            Usage(argv[0]);
            return 2;
        }

        NSString *mode = StringFromArgument(argv[1]);

        if ([mode isEqualToString:@"list"]) {
            return RunList();
        }

        if ([mode isEqualToString:@"wrapper"]) {
            if (argc < 3) {
                Usage(argv[0]);
                return 2;
            }
            NSString *urlError = nil;
            NSURL *url = URLFromArgument(argv[2], &urlError);
            if (!url) {
                fprintf(stderr, "invalid file-url-or-path: %s\n", [urlError UTF8String]);
                return 2;
            }
            BOOL readonly = YES;
            if (argc >= 4 && strcmp(argv[3], "readwrite") == 0) {
                readonly = NO;
            }
            int repeatCount = argc >= 5 ? MAX(1, atoi(argv[4])) : 1;
            return RunWrapper(url, readonly, repeatCount);
        }

        if ([mode isEqualToString:@"extend"]) {
            if (argc < 5) {
                Usage(argv[0]);
                return 2;
            }
            NSString *urlError = nil;
            NSURL *url = URLFromArgument(argv[2], &urlError);
            if (!url) {
                fprintf(stderr, "invalid file-url-or-path: %s\n", [urlError UTF8String]);
                return 2;
            }
            int repeatCount = argc >= 6 ? MAX(1, atoi(argv[5])) : 1;
            return RunExtend(url, StringFromArgument(argv[3]), StringFromArgument(argv[4]), repeatCount);
        }

        Usage(argv[0]);
        return 2;
    }
}
