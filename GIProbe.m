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

static BOOL GILookLikeIconPipeline(NSString *name) {
    return [GIAllowList() containsObject:name];
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

        NSArray<NSString *> *selectorNames = @[
            @"imageForIcon:", @"cachedImageForIcon:", @"realImageForIcon:",
            @"iconImageWithInfo:", @"iconImageForIcon:image:",
            @"generateIconImage:", @"generateIconImageWithInfo:",
            @"genericIconImageWithInfo:", @"unmaskedIconImageWithInfo:",
            @"getUnmaskedIconImage:", @"imageForBundleIdentifier:withScale:",
            @"imageForBundleIdentifier:withScale:withOverrides:",
            @"_applicationIconImageForBundleIdentifier:format:scale:",
            @"_applicationIconImageForBundleIdentifier:format:",
            @"imageForApplicationIconFormat:activityCategory:",
            @"_iconForResourceProxy:format:",
            @"_iconForResourceProxy:variant:options:variantsScale:",
            @"iconForBundleIdentifier:", @"appIconForBundleIdentifier:",
            @"_notifyImageDidUpdate", @"setIconImage:", @"setImage:",
        ];

        NSInteger classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) return;
        Class *buffer = (Class *)malloc(sizeof(Class) * classCount);
        if (!buffer) return;
        classCount = objc_getClassList(buffer, classCount);

        NSMutableArray<Class> *all = [NSMutableArray arrayWithCapacity:classCount];
        for (NSInteger i = 0; i < classCount; i++) [all addObject:buffer[i]];
        free(buffer);

        NSInteger matched = 0;
        for (Class cls in all) {
            @try {
                NSString *name = NSStringFromClass(cls);
                if (!GILookLikeIconPipeline(name)) continue;

                unsigned int count = 0;
                Method *methods = class_copyMethodList(cls, &count);
                if (!methods) continue;

                NSMutableString *block = [NSMutableString string];
                [block appendFormat:@"== %@ ==\n", name];
                NSInteger kept = 0;
                unsigned int cap = count < 400 ? count : 400;
                for (unsigned int i = 0; i < cap; i++) {
                    SEL sel = method_getName(methods[i]);
                    NSString *selector = NSStringFromSelector(sel);
                    BOOL relevant = NO;
                    for (NSString *candidate in selectorNames) {
                        if ([selector isEqualToString:candidate]) { relevant = YES; break; }
                    }
                    if (!relevant &&
                        ![selector containsString:@"mage"] &&
                        ![selector.lowercaseString containsString:@"icon"]) continue;
                    const char *type = method_getTypeEncoding(methods[i]);
                    [block appendFormat:@"  -%@  (%s)\n", selector, type ?: "?"];
                    kept++;
                }
                free(methods);
                if (kept > 0) {
                    [out appendString:block];
                    matched++;
                }
            } @catch (__unused NSException *e) {
                continue;
            }
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
