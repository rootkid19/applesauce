#import <Foundation/Foundation.h>

#include <unistd.h>

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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *stateEnv = getenv("LS_STALE_STATE_DIR");
        const char *holdEnv = getenv("LS_STALE_HOLD_SECONDS");
        const char *kindEnv = getenv("LS_STALE_KIND");

        NSString *stateDir = stateEnv != NULL ? [NSString stringWithUTF8String:stateEnv] : @"/tmp/ls-stale-state";
        NSString *kind = kindEnv != NULL ? [NSString stringWithUTF8String:kindEnv] : @"pidjob";
        NSTimeInterval holdSeconds = holdEnv != NULL ? MAX(1.0, atof(holdEnv)) : 120.0;

        EnsureDirectory(stateDir);

        NSString *logPath = [stateDir stringByAppendingPathComponent:@"state.log"];
        NSString *pidPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.pid", kind]];
        NSString *donePath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.done", kind]];

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:pidPath
                                                        atomically:YES
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ helper-agent start kind=%@ pid=%d ppid=%d hold=%.1f",
                             [NSDate date], kind, getpid(), getppid(), holdSeconds]);

        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:holdSeconds];
        while ([[NSDate date] compare:until] == NSOrderedAscending) {
            sleep(1);
        }

        [@"done\n" writeToFile:donePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ helper-agent exit kind=%@ pid=%d",
                             [NSDate date], kind, getpid()]);
    }
    return 0;
}
