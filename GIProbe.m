#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// GIProbe: standalone, hook-free class dumper. Loads in SpringBoard, waits for
// the home screen to settle, then writes the icon-pipeline class inventory to
// /var/mobile/Documents/GlassIconsDump.txt exactly once. It installs NO hooks
// and touches NO SpringBoard logic — if anything goes wrong it can only fail
// to write the file.

static NSArray<NSString *> *GIPrefixes(void) {
    return @[@"SBIcon", @"SBApplicationIcon", @"SBLeafIcon", @"SBApplication",
             @"SBLiveIcon", @"SBHIcon", @"SnowBoard", @"SBDockIcon",
             @"SBFolderIcon", @"SBIconImage", @"SBIconBadge", @"SBIconModel",
             @"SBIconManager", @"SBIconController"];
}

static BOOL GILookLikeIconPipeline(NSString *name) {
    for (NSString *prefix in GIPrefixes()) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

static void GIWriteDump(void) {
    @try {
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
                for (unsigned int i = 0; i < count; i++) {
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

        NSString *path = @"/var/mobile/Documents/GlassIconsDump.txt";
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[GIProbe] dump written: %@ (matched %ld)", path, (long)matched);
    } @catch (NSException *exception) {
        NSLog(@"[GIProbe] dump failed: %@", exception);
    }
}

__attribute__((constructor)) static void GIProbeEntry(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

    // Wait well past the respring storm, then dump once on a background queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        GIWriteDump();
    });
}
