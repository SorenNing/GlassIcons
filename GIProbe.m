#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// GIProbe: standalone, hook-free class dumper. Loads in SpringBoard, waits for
// the home screen to settle, then writes the icon-pipeline class inventory to
// /var/mobile/Documents/GlassIconsDump.txt exactly once. It installs NO hooks
// and touches NO SpringBoard logic — if anything goes wrong it can only fail
// to write the file.


// Explicit allow-list instead of prefix-scanning every class in the process:
// prefix matching during early startup was the respring-loop suspect.
static NSArray<NSString *> *GIAllowList(void) {
    return @[
        @"SBIconImageView", @"SBIconView", @"SBLeafIcon", @"SBApplicationIcon",
        @"SBApplication", @"SBHIconImageCache", @"SBFolderIconImageCache",
        @"SBIconImageCrossfadeView", @"SBLiveIconImageView", @"SBFolderIconView",
        @"SBFolderIconImageView", @"SBClockApplicationIconImageView",
        @"SBHClockApplicationIconImageView", @"SBIconModel", @"SBIconController",
        @"SBIconBadgeView", @"SBIconListGridView", @"SBIconImageCache",
        @"SBFolderIconBackgroundView", @"SBIconLocationModel",
        @"SBHLibraryAdditionalItemsIndicatorIcon", @"SBBookmarkIcon",
    ];
}


static NSString * const kProbeLog = @"/var/mobile/Library/GlassIconsProbe.log";

static void GIPLog(NSString *line) {
    @try {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kProbeLog];
        if (!h) {
            [[NSFileManager defaultManager] createFileAtPath:kProbeLog contents:nil attributes:nil];
            h = [NSFileHandle fileHandleForWritingAtPath:kProbeLog];
        }
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[[NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line]
                          dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (__unused NSException *e) {}
}

static void GIWriteDump(void) {
    @try {
        GIPLog(@"dump start");
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"GlassIcons runtime class dump\n"
                          @"generated: %@\n"
                          @"SpringBoard build: %@\n\n",
         [NSDate date],
         [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?"];


        // Direct lookups only: objc_getClassList + copyMethodList across the whole
        // process crashed SpringBoard (log stopped right after "dump start").
        NSInteger matched = 0;
        for (NSString *name in GIAllowList()) {
            Class cls = objc_getClass(name.UTF8String);
            if (!cls) {
                [out appendFormat:@"== %@ == (NOT FOUND)\n\n", name];
                continue;
            }

            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            if (!methods) {
                [out appendFormat:@"== %@ == (no methods)\n\n", name];
                continue;
            }

            NSMutableString *block = [NSMutableString string];
            [block appendFormat:@"== %@ ==\n", name];
            NSInteger kept = 0;
            unsigned int cap = count < 500 ? count : 500;
            for (unsigned int i = 0; i < cap; i++) {
                const char *selName = sel_getName(method_getName(methods[i]));
                if (!selName) continue;
                NSString *selector = [NSString stringWithUTF8String:selName] ?: @"?";
                const char *type = method_getTypeEncoding(methods[i]);
                [block appendFormat:@"  -%@  (%s)\n", selector, type ?: "?"];
                kept++;
            }
            free(methods);
            [block appendFormat:@"  [%ld methods]\n\n", (long)kept];
            [out appendString:block];
            matched++;
        }

        [out appendFormat:@"\nmatched classes: %ld\n", (long)matched];

        NSArray<NSString *> *paths = @[
            @"/var/mobile/Documents/GlassIconsDump.txt",
            @"/var/jb/var/mobile/Documents/GlassIconsDump.txt",
            @"/var/mobile/Library/GlassIconsDump.txt",
            @"/var/jb/var/mobile/Library/GlassIconsDump.txt",
        ];
        for (NSString *path in paths) {
            NSError *err = nil;
            if ([out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
                GIPLog([NSString stringWithFormat:@"dump written: %@", path]);
            } else {
                GIPLog([NSString stringWithFormat:@"dump write FAILED %@: %@",
                        path, err.localizedDescription ?: @"?"]);
            }
        }
    } @catch (NSException *exception) {
        GIPLog([NSString stringWithFormat:@"dump EXCEPTION: %@", exception]);
    }
}

__attribute__((constructor)) static void GIProbeEntry(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

    // Wait well past the respring storm, then dump once on a background queue.
    // 45s: well after launch, and only touch classes on the allow-list.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        GIWriteDump();
    });
}
