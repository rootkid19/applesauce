#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <unistd.h>

static NSString *ArgValue(NSArray<NSString *> *args, NSString *key, NSString *fallback) {
    NSUInteger idx = [args indexOfObject:key];
    if (idx == NSNotFound || idx + 1 >= args.count) {
        return fallback;
    }
    return args[idx + 1];
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

static NSWindow *CreateForegroundWindow(void) {
    NSRect rect = NSMakeRect(80, 80, 360, 120);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"LS Foreground Helper"];
    [window makeKeyAndOrderFront:nil];
    return window;
}

static void DrainRunLoop(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([[NSDate date] compare:until] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        NSString *stateDir = ArgValue(args, @"--state-dir", @"/tmp/ls-stale-state");
        NSString *kind = ArgValue(args, @"--kind", @"background");
        NSString *holdSecondsString = ArgValue(args, @"--hold-seconds", @"120");
        NSTimeInterval holdSeconds = MAX(1.0, holdSecondsString.doubleValue);

        EnsureDirectory(stateDir);

        NSString *logPath = [stateDir stringByAppendingPathComponent:@"state.log"];
        NSString *pidPath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.pid", kind]];
        NSString *donePath = [stateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"helper-%@.done", kind]];
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";

        NSWindow *window = nil;
        [NSApplication sharedApplication];
        if ([kind isEqualToString:@"foreground"]) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            window = CreateForegroundWindow();
            [NSApp activateIgnoringOtherApps:YES];
        } else {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        }
        DrainRunLoop(0.25);

        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:pidPath
                                                        atomically:YES
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ helper start kind=%@ pid=%d bundle=%@ id=%@ hold=%.1f",
                             [NSDate date], kind, getpid(), bundlePath, bundleID, holdSeconds]);

        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:holdSeconds];
        while ([[NSDate date] compare:until] == NSOrderedAscending) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }

        if (window != nil) {
            [window close];
        }

        [@"done\n" writeToFile:donePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        AppendLine(logPath, [NSString stringWithFormat:@"%@ helper exit kind=%@ pid=%d",
                             [NSDate date], kind, getpid()]);
    }
    return 0;
}
