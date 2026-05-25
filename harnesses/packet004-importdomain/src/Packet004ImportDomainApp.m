#import <Foundation/Foundation.h>
#import <FileProvider/FileProvider.h>
#import <dlfcn.h>
#import <errno.h>
#import <limits.h>
#import <objc/runtime.h>
#import <stdbool.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

typedef id (*WrapperReadonlyIMP)(id, SEL, NSURL *, BOOL, NSError **);
typedef id (*WrapperExtensionClassIMP)(id, SEL, NSURL *, const char *, NSError **);
typedef id (*WrapperInitIMP)(id, SEL, NSURL *, const char *, BOOL, NSError **);
typedef id (*IssueSandboxIMP)(id, SEL, const char *, BOOL, NSError **);

static WrapperReadonlyIMP gOrigWrapperReadonly = NULL;
static WrapperExtensionClassIMP gOrigWrapperExtensionClass = NULL;
static WrapperInitIMP gOrigWrapperInit = NULL;
static IssueSandboxIMP gOrigIssueSandbox = NULL;

static const char *CString(NSString *string) {
    return string ? string.UTF8String : "(null)";
}

static const char *CArgumentString(const char *string) {
    return string ? string : "(null)";
}

static NSString *BoolString(BOOL value) {
    return value ? @"true" : @"false";
}

static NSString *RealpathForPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }

    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) == NULL) {
        return [NSString stringWithFormat:@"(error:%s)", strerror(errno)];
    }
    return [NSString stringWithUTF8String:resolved];
}

static void PrintNSError(NSString *prefix, NSError *error) {
    if (!error) {
        printf("%s.error=(null)\n", CString(prefix));
        return;
    }

    printf("%s.error.domain=%s\n", CString(prefix), CString(error.domain));
    printf("%s.error.code=%ld\n", CString(prefix), (long)error.code);
    printf("%s.error.description=%s\n", CString(prefix), CString(error.localizedDescription));
    printf("%s.error.full=%s\n", CString(prefix), CString(error.description));
}

static void PrintURLProbe(NSString *prefix, NSURL *url) {
    printf("%s.url.class=%s\n", CString(prefix), url ? object_getClassName(url) : "(null)");
    printf("%s.url.description=%s\n", CString(prefix), CString(url.description));
    if (!url.isFileURL) {
        return;
    }

    NSString *path = url.path;
    printf("%s.url.path=%s\n", CString(prefix), CString(path));
    printf("%s.url.realpath=%s\n", CString(prefix), CString(RealpathForPath(path)));
}

static void PrintObjectProbe(NSString *prefix, id object) {
    printf("%s.class=%s\n", CString(prefix), object ? object_getClassName(object) : "(null)");
    printf("%s.description=%s\n", CString(prefix), CString([object description]));
}

static id ProbeWrapperReadonly(id self, SEL _cmd, NSURL *url, BOOL readonly, NSError **error) {
    printf("probe.hit.selector=%s\n", sel_getName(_cmd));
    printf("probe.hit.kind=class-wrapper-readonly\n");
    printf("probe.hit.readonly=%s\n", CString(BoolString(readonly)));
    PrintURLProbe(@"probe.hit", url);
    fflush(stdout);

    id result = gOrigWrapperReadonly ? gOrigWrapperReadonly(self, _cmd, url, readonly, error) : nil;

    PrintObjectProbe(@"probe.result.wrapper-readonly", result);
    if (error != NULL) {
        PrintNSError(@"probe.result.wrapper-readonly", *error);
    }
    fflush(stdout);
    return result;
}

static id ProbeWrapperExtensionClass(id self, SEL _cmd, NSURL *url, const char *extensionClass, NSError **error) {
    printf("probe.hit.selector=%s\n", sel_getName(_cmd));
    printf("probe.hit.kind=class-wrapper-extension-class\n");
    printf("probe.hit.extensionClass=%s\n", CArgumentString(extensionClass));
    PrintURLProbe(@"probe.hit", url);
    fflush(stdout);

    id result = gOrigWrapperExtensionClass ? gOrigWrapperExtensionClass(self, _cmd, url, extensionClass, error) : nil;

    PrintObjectProbe(@"probe.result.wrapper-extension-class", result);
    if (error != NULL) {
        PrintNSError(@"probe.result.wrapper-extension-class", *error);
    }
    fflush(stdout);
    return result;
}

static id ProbeWrapperInit(id self, SEL _cmd, NSURL *url, const char *extensionClass, BOOL report, NSError **error) {
    printf("probe.hit.selector=%s\n", sel_getName(_cmd));
    printf("probe.hit.kind=instance-wrapper-init\n");
    printf("probe.hit.extensionClass=%s\n", CArgumentString(extensionClass));
    printf("probe.hit.report=%s\n", CString(BoolString(report)));
    PrintURLProbe(@"probe.hit", url);
    fflush(stdout);

    id result = gOrigWrapperInit ? gOrigWrapperInit(self, _cmd, url, extensionClass, report, error) : nil;

    PrintObjectProbe(@"probe.result.wrapper-init", result);
    if (error != NULL) {
        PrintNSError(@"probe.result.wrapper-init", *error);
    }
    fflush(stdout);
    return result;
}

static id ProbeIssueSandbox(id self, SEL _cmd, const char *extensionClass, BOOL report, NSError **error) {
    printf("probe.hit.selector=%s\n", sel_getName(_cmd));
    printf("probe.hit.kind=nsurl-issue-sandbox-extension\n");
    printf("probe.hit.extensionClass=%s\n", CArgumentString(extensionClass));
    printf("probe.hit.report=%s\n", CString(BoolString(report)));
    if ([self isKindOfClass:NSURL.class]) {
        PrintURLProbe(@"probe.hit.self", (NSURL *)self);
    } else {
        PrintObjectProbe(@"probe.hit.self", self);
    }
    fflush(stdout);

    id result = gOrigIssueSandbox ? gOrigIssueSandbox(self, _cmd, extensionClass, report, error) : nil;

    printf("probe.result.issue-sandbox-extension.pointer=%p\n", (__bridge void *)result);
    if (error != NULL) {
        PrintNSError(@"probe.result.issue-sandbox-extension", *error);
    }
    fflush(stdout);
    return result;
}

static BOOL InstallProbe(Class cls, BOOL classMethod, SEL selector, IMP replacement, IMP *originalOut) {
    if (!cls) {
        printf("probe.install.selector=%s status=missing-class\n", sel_getName(selector));
        return NO;
    }

    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) {
        printf("probe.install.selector=%s status=missing-method class=%s\n", sel_getName(selector), class_getName(cls));
        return NO;
    }

    const char *types = method_getTypeEncoding(method);
    *originalOut = method_setImplementation(method, replacement);
    printf("probe.install.selector=%s status=installed class=%s type=%s\n", sel_getName(selector), class_getName(cls), types ? types : "(null)");
    return YES;
}

static void InstallCallerProbes(void) {
    dlopen("/System/Library/Frameworks/FileProvider.framework/FileProvider", RTLD_NOW);

    Class wrapperClass = NSClassFromString(@"FPSandboxingURLWrapper");
    InstallProbe(wrapperClass, YES, NSSelectorFromString(@"wrapperWithURL:readonly:error:"), (IMP)ProbeWrapperReadonly, (IMP *)&gOrigWrapperReadonly);
    InstallProbe(wrapperClass, YES, NSSelectorFromString(@"wrapperWithURL:extensionClass:error:"), (IMP)ProbeWrapperExtensionClass, (IMP *)&gOrigWrapperExtensionClass);
    InstallProbe(wrapperClass, NO, NSSelectorFromString(@"initWithURL:extensionClass:report:error:"), (IMP)ProbeWrapperInit, (IMP *)&gOrigWrapperInit);
    InstallProbe(NSURL.class, NO, NSSelectorFromString(@"fp_issueSandboxExtensionOfClass:report:error:"), (IMP)ProbeIssueSandbox, (IMP *)&gOrigIssueSandbox);
    fflush(stdout);
}

static NSURL *FileURLFromArgument(NSString *raw, NSString **errorString) {
    if (raw.length == 0) {
        if (errorString) {
            *errorString = @"empty path";
        }
        return nil;
    }

    if ([raw hasPrefix:@"file://"]) {
        NSURL *url = [NSURL URLWithString:raw];
        if (!url.isFileURL || url.path.length == 0 || (url.host.length > 0 && ![url.host isEqualToString:@"localhost"])) {
            if (errorString) {
                *errorString = @"expected a local file URL";
            }
            return nil;
        }
        return url;
    }

    if ([raw containsString:@"://"]) {
        if (errorString) {
            *errorString = @"only local paths and file:// URLs are supported";
        }
        return nil;
    }

    if (![raw hasPrefix:@"/"]) {
        if (errorString) {
            *errorString = @"path must be absolute";
        }
        return nil;
    }

    return [NSURL fileURLWithPath:raw];
}

static BOOL WaitForSemaphore(dispatch_semaphore_t semaphore, int timeoutSeconds) {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSeconds * NSEC_PER_SEC);
    return dispatch_semaphore_wait(semaphore, deadline) == 0;
}

static void PrintPathSnapshot(NSString *label, NSString *path) {
    printf("%s.path=%s\n", CString(label), CString(path));

    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    printf("%s.exists=%s\n", CString(label), exists ? "1" : "0");
    printf("%s.isDirectoryFollowingLinks=%s\n", CString(label), isDir ? "1" : "0");

    struct stat lst;
    if (lstat(path.fileSystemRepresentation, &lst) == 0) {
        printf("%s.lstat.dev=%llu\n", CString(label), (unsigned long long)lst.st_dev);
        printf("%s.lstat.ino=%llu\n", CString(label), (unsigned long long)lst.st_ino);
        printf("%s.lstat.mode=%o\n", CString(label), lst.st_mode);
        printf("%s.lstat.type=%s\n", CString(label), S_ISLNK(lst.st_mode) ? "symlink" : (S_ISDIR(lst.st_mode) ? "directory" : (S_ISREG(lst.st_mode) ? "regular" : "other")));

        if (S_ISLNK(lst.st_mode)) {
            char linkTarget[PATH_MAX];
            ssize_t len = readlink(path.fileSystemRepresentation, linkTarget, sizeof(linkTarget) - 1);
            if (len >= 0) {
                linkTarget[len] = '\0';
                printf("%s.readlink=%s\n", CString(label), linkTarget);
            }
        }
    } else {
        printf("%s.lstat.error=%s\n", CString(label), strerror(errno));
    }

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0) {
        printf("%s.stat.dev=%llu\n", CString(label), (unsigned long long)st.st_dev);
        printf("%s.stat.ino=%llu\n", CString(label), (unsigned long long)st.st_ino);
        printf("%s.stat.mode=%o\n", CString(label), st.st_mode);
    } else {
        printf("%s.stat.error=%s\n", CString(label), strerror(errno));
    }

    printf("%s.realpath=%s\n", CString(label), CString(RealpathForPath(path)));
}

static void PrintEnvironment(void) {
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    printf("pid=%d\n", getpid());
    printf("processName=%s\n", CString(processInfo.processName));
    printf("operatingSystemVersionString=%s\n", CString(processInfo.operatingSystemVersionString));
    printf("bundle.path=%s\n", CString(NSBundle.mainBundle.bundlePath));
    printf("bundle.identifier=%s\n", CString(NSBundle.mainBundle.bundleIdentifier));
    char *cwd = getcwd(NULL, 0);
    printf("cwd=%s\n", cwd ? cwd : "(null)");
    free(cwd);
}

static void ListDomains(NSString *label, int timeoutSeconds) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray<NSFileProviderDomain *> *domains = nil;
    __block NSError *listError = nil;

    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *returnedDomains, NSError *error) {
        domains = returnedDomains;
        listError = error;
        dispatch_semaphore_signal(semaphore);
    }];

    if (!WaitForSemaphore(semaphore, timeoutSeconds)) {
        printf("%s.timeout=%ds\n", CString(label), timeoutSeconds);
        return;
    }

    if (listError) {
        PrintNSError([label stringByAppendingString:@".domains"], listError);
        return;
    }

    printf("%s.count=%lu\n", CString(label), (unsigned long)domains.count);
    [domains enumerateObjectsUsingBlock:^(NSFileProviderDomain *domain, NSUInteger idx, BOOL *stop) {
        (void)stop;
        printf("%s.%lu.identifier=%s\n", CString(label), (unsigned long)idx, CString(domain.identifier));
        printf("%s.%lu.displayName=%s\n", CString(label), (unsigned long)idx, CString(domain.displayName));
        printf("%s.%lu.hidden=%s\n", CString(label), (unsigned long)idx, CString(BoolString(domain.hidden)));
        printf("%s.%lu.description=%s\n", CString(label), (unsigned long)idx, CString(domain.description));
    }];
}

static NSError *RemoveDomain(NSFileProviderDomain *domain, int timeoutSeconds) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *removeError = nil;
    [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *error) {
        removeError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    if (!WaitForSemaphore(semaphore, timeoutSeconds)) {
        return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey: @"removeDomain timed out"}];
    }
    return removeError;
}

static void RemoveDomainAndReport(NSFileProviderDomain *domain, NSString *label, int timeoutSeconds) {
    NSError *removeError = RemoveDomain(domain, timeoutSeconds);
    if (removeError) {
        PrintNSError(label, removeError);
    } else {
        printf("%s.result=success\n", CString(label));
    }
}

static int RunImport(NSURL *directoryURL, NSString *domainID, NSString *domainName, NSString *mode, BOOL removeFirst, BOOL removeAfter, int timeoutSeconds) {
    NSFileProviderDomain *domain = [[NSFileProviderDomain alloc] initWithIdentifier:domainID displayName:domainName];
    domain.hidden = YES;

    printf("mode=%s\n", CString(mode));
    printf("domain.identifier=%s\n", CString(domain.identifier));
    printf("domain.displayName=%s\n", CString(domain.displayName));
    printf("domain.hidden=%s\n", CString(BoolString(domain.hidden)));
    PrintURLProbe(@"import.input", directoryURL);
    PrintPathSnapshot(@"import.input.snapshot.before", directoryURL.path);
    ListDomains(@"domains.before", 15);

    if (removeFirst) {
        RemoveDomainAndReport(domain, @"removeDomainFirst", 30);
        ListDomains(@"domains.after-remove-first", 15);
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *completionError = nil;
    __block BOOL completed = NO;

    printf("importDomain.call=begin\n");
    fflush(stdout);
    [NSFileProviderManager importDomain:domain fromDirectoryAtURL:directoryURL completionHandler:^(NSError *error) {
        completed = YES;
        completionError = error;
        printf("importDomain.completion.called=1\n");
        PrintNSError(@"importDomain.completion", error);
        fflush(stdout);
        dispatch_semaphore_signal(semaphore);
    }];

    if (!WaitForSemaphore(semaphore, timeoutSeconds)) {
        printf("importDomain.timeout=%ds\n", timeoutSeconds);
        PrintPathSnapshot(@"import.input.snapshot.after", directoryURL.path);
        ListDomains(@"domains.after-timeout", 15);
        if (removeAfter) {
            RemoveDomainAndReport(domain, @"removeDomainAfterTimeout", 30);
            ListDomains(@"domains.after-remove-timeout", 15);
        }
        return 124;
    }

    printf("importDomain.completed=%s\n", completed ? "1" : "0");
    PrintPathSnapshot(@"import.input.snapshot.after", directoryURL.path);
    ListDomains(@"domains.after", 15);
    if (removeAfter) {
        RemoveDomainAndReport(domain, @"removeDomainAfter", 30);
        ListDomains(@"domains.after-remove", 15);
    }
    return completionError ? 1 : 0;
}

static NSString *ValueForOption(NSArray<NSString *> *arguments, NSString *option, NSString *defaultValue) {
    NSUInteger idx = [arguments indexOfObject:option];
    if (idx == NSNotFound || idx + 1 >= arguments.count) {
        return defaultValue;
    }
    return arguments[idx + 1];
}

static BOOL HasOption(NSArray<NSString *> *arguments, NSString *option) {
    return [arguments containsObject:option];
}

static void Usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s --directory <absolute-path-or-file-url> --domain-id <id> [options]\n"
            "options:\n"
            "  --mode <normal|symlink-leaf|race>       label printed into the run output\n"
            "  --domain-name <name>                    display name for the temporary domain\n"
            "  --timeout <seconds>                     completion wait timeout; default 60\n"
            "  --remove-domain-first                   best-effort removal before import\n"
            "  --remove-domain-after                   best-effort cleanup after completion/timeout\n"
            "  --no-swizzle                            disable in-process private-method probes\n",
            argv0);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        NSString *directoryArg = ValueForOption(arguments, @"--directory", nil);
        NSString *domainID = ValueForOption(arguments, @"--domain-id", nil);
        if (directoryArg.length == 0 || domainID.length == 0) {
            Usage(argv[0]);
            return 2;
        }

        NSString *urlError = nil;
        NSURL *directoryURL = FileURLFromArgument(directoryArg, &urlError);
        if (!directoryURL) {
            fprintf(stderr, "invalid --directory: %s\n", CString(urlError));
            return 2;
        }

        NSString *mode = ValueForOption(arguments, @"--mode", @"normal");
        NSString *domainName = ValueForOption(arguments, @"--domain-name", [NSString stringWithFormat:@"Packet004 %@", mode]);
        int timeoutSeconds = MAX(1, ValueForOption(arguments, @"--timeout", @"60").intValue);
        BOOL removeFirst = HasOption(arguments, @"--remove-domain-first");
        BOOL removeAfter = HasOption(arguments, @"--remove-domain-after");
        BOOL swizzle = !HasOption(arguments, @"--no-swizzle");

        PrintEnvironment();
        if (swizzle) {
            InstallCallerProbes();
        } else {
            printf("probe.install.disabled=1\n");
        }

        return RunImport(directoryURL, domainID, domainName, mode, removeFirst, removeAfter, timeoutSeconds);
    }
}
