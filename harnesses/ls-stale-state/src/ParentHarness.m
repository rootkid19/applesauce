#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSString *ArgValue(NSArray<NSString *> *args, NSString *key, NSString *fallback) {
    NSUInteger idx = [args indexOfObject:key];
    if (idx == NSNotFound || idx + 1 >= args.count) {
        return fallback;
    }
    return args[idx + 1];
}

static BOOL HasArg(NSArray<NSString *> *args, NSString *key) {
    return [args containsObject:key];
}

static void EnsureDirectory(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

static void AppendLine(NSString *path, NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static int LaunchHelper(NSString *helperApp, NSString *stateDir, NSString *helperKind, NSString *holdSeconds) {
    NSURL *helperURL = [NSURL fileURLWithPath:helperApp];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.arguments = @[
        @"--state-dir", stateDir,
        @"--kind", helperKind,
        @"--hold-seconds", holdSeconds
    ];
    configuration.activates = [helperKind isEqualToString:@"foreground"];

    __block NSInteger errorCode = 0;
    __block BOOL completed = NO;

    [[NSWorkspace sharedWorkspace] openApplicationAtURL:helperURL
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
        if (error != nil || app == nil) {
            errorCode = error != nil ? error.code : -1;
        }
        completed = YES;
    }];

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!completed && [[NSDate date] compare:until] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    return errorCode == 0 ? 0 : (int)errorCode;
}

static int LaunchSubprocessHelper(NSString *helperExec, NSString *stateDir, NSString *holdSeconds) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:helperExec];
    task.arguments = @[
        @"--state-dir", stateDir,
        @"--kind", @"subprocess",
        @"--hold-seconds", holdSeconds
    ];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return error != nil ? (int)error.code : -1;
    }
    return 0;
}

static void WriteCStringFile(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    size_t length = strlen(value);
    while (length > 0) {
        ssize_t written = write(fd, value, length);
        if (written <= 0) {
            break;
        }
        value += written;
        length -= (size_t)written;
    }
    close(fd);
}

static int ForkHoldChild(NSString *stateDir, NSString *holdSeconds) {
    const char *dir = [stateDir fileSystemRepresentation];
    int seconds = MAX(0, holdSeconds.intValue);

    pid_t child = fork();
    if (child < 0) {
        return -1;
    }

    if (child == 0) {
        char pidPath[PATH_MAX];
        char donePath[PATH_MAX];
        char logPath[PATH_MAX];
        char line[256];

        snprintf(pidPath, sizeof(pidPath), "%s/helper-forkhold.pid", dir);
        snprintf(donePath, sizeof(donePath), "%s/helper-forkhold.done", dir);
        snprintf(logPath, sizeof(logPath), "%s/forkhold-child.log", dir);
        snprintf(line, sizeof(line), "%d\n", getpid());
        WriteCStringFile(pidPath, line);

        int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            snprintf(line, sizeof(line), "forkhold child pid=%d ppid=%d hold=%d\n", getpid(), getppid(), seconds);
            write(fd, line, strlen(line));
            close(fd);
        }

        sleep((unsigned int)seconds);
        WriteCStringFile(donePath, "done\n");
        _exit(0);
    }

    return (int)child;
}

static int RunTask(NSString *execPath, NSArray<NSString *> *arguments, NSString *stateDir, NSString *name) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:execPath];
    task.arguments = arguments;

    NSString *stdoutPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.stdout.txt", name]];
    NSString *stderrPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.stderr.txt", name]];
    [[NSFileManager defaultManager] createFileAtPath:stdoutPath contents:nil attributes:nil];
    [[NSFileManager defaultManager] createFileAtPath:stderrPath contents:nil attributes:nil];
    task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:stderrPath];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return error != nil ? (int)error.code : -1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

static NSString *LaunchAgentDomain(void) {
    return [NSString stringWithFormat:@"gui/%u", getuid()];
}

static NSString *PIDDomain(void) {
    return [NSString stringWithFormat:@"pid/%d", getpid()];
}

static int WriteAndBootstrapLaunchdJob(NSString *helperExec,
                                       NSString *stateDir,
                                       NSString *holdSeconds,
                                       NSString *label,
                                       NSString *jobKind,
                                       NSString *domain,
                                       NSString **plistPathOut) {
    NSString *plistPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", label]];
    NSString *stdoutPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-helper.stdout.txt", jobKind]];
    NSString *stderrPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-helper.stderr.txt", jobKind]];

    NSDictionary *plist = @{
        @"Label": label,
        @"ProgramArguments": @[
            helperExec,
            @"--state-dir", stateDir,
            @"--kind", jobKind,
            @"--hold-seconds", holdSeconds
        ],
        @"RunAtLoad": @YES,
        @"StandardOutPath": stdoutPath,
        @"StandardErrorPath": stderrPath
    };

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data == nil || ![data writeToFile:plistPath atomically:YES]) {
        return -1;
    }

    if (plistPathOut != NULL) {
        *plistPathOut = plistPath;
    }

    int bootoutRC = RunTask(@"/bin/launchctl", @[@"bootout", domain, plistPath], stateDir,
                            [NSString stringWithFormat:@"launchctl-%@-pre-bootout", jobKind]);
    (void)bootoutRC;

    return RunTask(@"/bin/launchctl", @[@"bootstrap", domain, plistPath], stateDir,
                   [NSString stringWithFormat:@"launchctl-%@-bootstrap", jobKind]);
}

static int WriteAndBootstrapPIDJob(NSString *helperExec,
                                   NSString *stateDir,
                                   NSString *holdSeconds,
                                   NSString *label,
                                   NSString **plistPathOut) {
    NSString *plistPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", label]];
    NSString *stdoutPath = [stateDir stringByAppendingPathComponent:@"pidjob-helper.stdout.txt"];
    NSString *stderrPath = [stateDir stringByAppendingPathComponent:@"pidjob-helper.stderr.txt"];
    NSString *domain = PIDDomain();

    NSDictionary *plist = @{
        @"Label": label,
        @"Program": helperExec,
        @"RunAtLoad": @YES,
        @"KeepAlive": @YES,
        @"EnvironmentVariables": @{
            @"LS_STALE_STATE_DIR": stateDir,
            @"LS_STALE_HOLD_SECONDS": holdSeconds,
            @"LS_STALE_KIND": @"pidjob"
        },
        @"StandardOutPath": stdoutPath,
        @"StandardErrorPath": stderrPath
    };

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data == nil || ![data writeToFile:plistPath atomically:YES]) {
        return -1;
    }

    if (plistPathOut != NULL) {
        *plistPathOut = plistPath;
    }

    int bootoutRC = RunTask(@"/bin/launchctl", @[@"bootout", domain, plistPath], stateDir,
                            @"launchctl-pidjob-pre-bootout");
    (void)bootoutRC;

    return RunTask(@"/bin/launchctl", @[@"bootstrap", domain, plistPath], stateDir,
                   @"launchctl-pidjob-bootstrap");
}

static BOOL WaitForFile(NSString *path, NSTimeInterval timeout) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if ([[NSDate date] compare:until] != NSOrderedAscending) {
            return NO;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return YES;
}

static NSString *DigitsFromFile(NSString *path) {
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil] ?: @"";
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [[contents componentsSeparatedByCharactersInSet:notDigits] componentsJoinedByString:@""];
}

static NSString *BundleIDForHelperKind(NSString *helperKind) {
    if ([helperKind isEqualToString:@"background"]) {
        return @"com.chimera.lsstale.HelperBackground";
    }
    if ([helperKind isEqualToString:@"foreground"]) {
        return @"com.chimera.lsstale.HelperForeground";
    }
    return @"";
}

static void CaptureAppHelperState(NSString *stateDir, NSString *helperKind, NSString *helperPID) {
    if (helperPID.length > 0) {
        RunTask(@"/bin/launchctl", @[@"print", [NSString stringWithFormat:@"pid/%@", helperPID]], stateDir,
                [NSString stringWithFormat:@"launchctl-%@-print-helper-after-start", helperKind]);
        RunTask(@"/bin/launchctl", @[@"procinfo", helperPID], stateDir,
                [NSString stringWithFormat:@"launchctl-%@-procinfo-helper-after-start", helperKind]);
    }

    NSString *bundleID = BundleIDForHelperKind(helperKind);
    if (bundleID.length > 0) {
        RunTask(@"/usr/bin/lsappinfo", @[@"find", [NSString stringWithFormat:@"bundleid=%@", bundleID]], stateDir,
                [NSString stringWithFormat:@"lsappinfo-%@-find-after-start", helperKind]);
        RunTask(@"/usr/bin/lsappinfo", @[@"info", bundleID], stateDir,
                [NSString stringWithFormat:@"lsappinfo-%@-info-after-start", helperKind]);
        RunTask(@"/usr/bin/lsappinfo", @[@"info", @"-only", @"kLSParentASNKey", bundleID], stateDir,
                [NSString stringWithFormat:@"lsappinfo-%@-parentasn-after-start", helperKind]);
        RunTask(@"/usr/bin/lsappinfo", @[@"info", @"-only", @"__kLSApplicationAllRelatedApplicationASNsArrayKey", bundleID], stateDir,
                [NSString stringWithFormat:@"lsappinfo-%@-allrelated-after-start", helperKind]);
    }
}

static int KickstartLaunchAgent(NSString *stateDir, NSString *label) {
    return RunTask(@"/bin/launchctl",
                   @[@"kickstart", @"-k", [NSString stringWithFormat:@"%@/%@", LaunchAgentDomain(), label]],
                   stateDir,
                   @"launchctl-kickstart");
}

static int SubmitLaunchdJob(NSString *helperExec,
                            NSString *stateDir,
                            NSString *holdSeconds,
                            NSString *label) {
    NSString *stdoutPath = [stateDir stringByAppendingPathComponent:@"submit-helper.stdout.txt"];
    NSString *stderrPath = [stateDir stringByAppendingPathComponent:@"submit-helper.stderr.txt"];

    return RunTask(@"/bin/launchctl",
                   @[
                       @"submit",
                       @"-l", label,
                       @"-o", stdoutPath,
                       @"-e", stderrPath,
                       @"--",
                       helperExec,
                       @"--state-dir", stateDir,
                       @"--kind", @"submit",
                       @"--hold-seconds", holdSeconds
                   ],
                   stateDir,
                   @"launchctl-submit");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        NSString *phase = ArgValue(args, @"--phase", @"first");
        NSString *stateDir = ArgValue(args, @"--state-dir", @"/tmp/ls-stale-state");
        NSString *helperApp = ArgValue(args, @"--helper-app", @"");
        NSString *helperExec = ArgValue(args, @"--helper-exec", @"");
        NSString *helperKind = ArgValue(args, @"--helper-kind", @"none");
        NSString *launchAgentLabel = ArgValue(args, @"--launch-agent-label", @"com.chimera.lsstale.launchagent");
        NSString *pidDomainLabel = ArgValue(args, @"--pid-domain-label", @"com.chimera.lsstale.piddomain");
        NSString *pidJobLabel = ArgValue(args, @"--pid-job-label", @"com.chimera.lsstale.Parent.helper");
        NSString *submitLabel = ArgValue(args, @"--submit-label", @"com.chimera.lsstale.submit");
        NSString *holdSeconds = ArgValue(args, @"--hold-seconds", @"120");
        NSString *lingerSecondsString = ArgValue(args, @"--linger-seconds", @"4");
        NSString *jobStartWaitString = ArgValue(args, @"--job-start-wait-seconds", @"1");
        NSTimeInterval lingerSeconds = MAX(0.0, lingerSecondsString.doubleValue);
        NSTimeInterval jobStartWaitSeconds = MAX(0.0, jobStartWaitString.doubleValue);

        EnsureDirectory(stateDir);

        NSString *activationPolicy = ArgValue(args, @"--activation-policy", @"accessory");

        [NSApplication sharedApplication];
        if ([activationPolicy isEqualToString:@"regular"]) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            [NSApp activateIgnoringOtherApps:YES];
        } else {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }

        NSString *logPath = [stateDir stringByAppendingPathComponent:@"state.log"];
        NSString *pidPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"parent-%@.pid", phase]];
        NSString *donePath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"parent-%@.done", phase]];

        NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:pidPath
                                                        atomically:YES
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ parent phase=%@ pid=%d bundle=%@ id=%@ helperKind=%@ helperApp=%@",
                             [NSDate date], phase, getpid(), bundlePath, bundleID, helperKind, helperApp]);

        if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"subprocess"] && helperExec.length > 0) {
            int rc = LaunchSubprocessHelper(helperExec, stateDir, holdSeconds);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent launched subprocess helper exec=%@ rc=%d",
                                 [NSDate date], helperExec, rc]);
        } else if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"forkhold"]) {
            int childPID = ForkHoldChild(stateDir, holdSeconds);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent forked hold child pid_or_error=%d",
                                 [NSDate date], childPID]);
        } else if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"launchagent"] && helperExec.length > 0) {
            NSString *plistPath = nil;
            int rc = WriteAndBootstrapLaunchdJob(helperExec, stateDir, holdSeconds, launchAgentLabel, @"launchagent", LaunchAgentDomain(), &plistPath);
            if (rc == 0) {
                rc = KickstartLaunchAgent(stateDir, launchAgentLabel);
            }
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent bootstrapped launchagent label=%@ plist=%@ exec=%@ rc=%d",
                                 [NSDate date], launchAgentLabel, plistPath ?: @"", helperExec, rc]);
        } else if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"piddomain"] && helperExec.length > 0) {
            NSString *plistPath = nil;
            NSString *domain = PIDDomain();
            int rc = WriteAndBootstrapLaunchdJob(helperExec, stateDir, holdSeconds, pidDomainLabel, @"piddomain", domain, &plistPath);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent bootstrapped piddomain label=%@ domain=%@ plist=%@ exec=%@ rc=%d",
                                 [NSDate date], pidDomainLabel, domain, plistPath ?: @"", helperExec, rc]);
            RunTask(@"/bin/launchctl", @[@"print", domain], stateDir, @"launchctl-piddomain-print-after-bootstrap");
            RunTask(@"/bin/launchctl", @[@"blame", [NSString stringWithFormat:@"%@/%@", domain, pidDomainLabel]], stateDir, @"launchctl-piddomain-blame-after-bootstrap");
            if (jobStartWaitSeconds > 0.0) {
                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:jobStartWaitSeconds];
                while ([[NSDate date] compare:until] == NSOrderedAscending) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
            }
        } else if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"pidjob"] && helperExec.length > 0) {
            NSString *plistPath = nil;
            NSString *domain = PIDDomain();
            int rc = WriteAndBootstrapPIDJob(helperExec, stateDir, holdSeconds, pidJobLabel, &plistPath);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent bootstrapped pidjob label=%@ domain=%@ plist=%@ exec=%@ rc=%d",
                                 [NSDate date], pidJobLabel, domain, plistPath ?: @"", helperExec, rc]);
            RunTask(@"/bin/launchctl", @[@"print", domain], stateDir, @"launchctl-pidjob-print-after-bootstrap");
            RunTask(@"/bin/launchctl", @[@"blame", [NSString stringWithFormat:@"%@/%@", domain, pidJobLabel]], stateDir, @"launchctl-pidjob-blame-after-bootstrap");
            RunTask(@"/bin/launchctl", @[@"print", domain], stateDir, @"launchctl-pidjob-print-parent-before-exit");
            RunTask(@"/bin/launchctl", @[@"procinfo", [NSString stringWithFormat:@"%d", getpid()]], stateDir,
                    @"launchctl-pidjob-procinfo-parent-before-exit");

            NSString *helperPidPath = [stateDir stringByAppendingPathComponent:@"helper-pidjob.pid"];
            BOOL sawHelper = WaitForFile(helperPidPath, MAX(0.2, jobStartWaitSeconds));
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent pidjob helper_pid_seen=%@",
                                 [NSDate date], sawHelper ? @"yes" : @"no"]);
            if (sawHelper) {
                NSString *helperPID = [NSString stringWithContentsOfFile:helperPidPath
                                                                 encoding:NSUTF8StringEncoding
                                                                    error:nil] ?: @"";
                NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                NSString *trimmedPID = [[helperPID componentsSeparatedByCharactersInSet:notDigits] componentsJoinedByString:@""];
                if (trimmedPID.length > 0) {
                    RunTask(@"/bin/launchctl", @[@"print", [NSString stringWithFormat:@"pid/%@", trimmedPID]], stateDir,
                            @"launchctl-pidjob-print-helper-after-start");
                    RunTask(@"/bin/launchctl", @[@"procinfo", trimmedPID], stateDir,
                            @"launchctl-pidjob-procinfo-helper-after-start");
                }
            } else if (jobStartWaitSeconds > 0.0) {
                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:jobStartWaitSeconds];
                while ([[NSDate date] compare:until] == NSOrderedAscending) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
            }
        } else if ([phase isEqualToString:@"first"] && [helperKind isEqualToString:@"submit"] && helperExec.length > 0) {
            int removeRC = RunTask(@"/bin/launchctl", @[@"remove", submitLabel], stateDir, @"launchctl-submit-pre-remove");
            (void)removeRC;
            int rc = SubmitLaunchdJob(helperExec, stateDir, holdSeconds, submitLabel);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent submitted launchd job label=%@ exec=%@ rc=%d",
                                 [NSDate date], submitLabel, helperExec, rc]);
            RunTask(@"/bin/launchctl", @[@"print", [NSString stringWithFormat:@"gui/%u/%@", getuid(), submitLabel]], stateDir, @"launchctl-submit-print-after-submit");
            if (jobStartWaitSeconds > 0.0) {
                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:jobStartWaitSeconds];
                while ([[NSDate date] compare:until] == NSOrderedAscending) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
            }
        } else if ([phase isEqualToString:@"first"] && ![helperKind isEqualToString:@"none"] && helperApp.length > 0) {
            int rc = LaunchHelper(helperApp, stateDir, helperKind, holdSeconds);
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent launched helper kind=%@ rc=%d",
                                 [NSDate date], helperKind, rc]);
            NSString *helperPidPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.pid", helperKind]];
            BOOL sawHelper = WaitForFile(helperPidPath, MAX(1.0, jobStartWaitSeconds));
            AppendLine(logPath, [NSString stringWithFormat:@"%@ parent helper kind=%@ helper_pid_seen=%@",
                                 [NSDate date], helperKind, sawHelper ? @"yes" : @"no"]);
            if (sawHelper) {
                CaptureAppHelperState(stateDir, helperKind, DigitsFromFile(helperPidPath));
            }
        }

        if ([phase isEqualToString:@"second"] || HasArg(args, @"--linger")) {
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:lingerSeconds];
            while ([[NSDate date] compare:until] == NSOrderedAscending) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }

        [@"done\n" writeToFile:donePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ parent exiting phase=%@ pid=%d",
                             [NSDate date], phase, getpid()]);
    }
    return 0;
}
