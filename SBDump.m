#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// SBDump: writes the class+method inventory of SpringBoard's icon pipeline to
// /var/mobile/Documents/GlassIconsDump.txt so the real fetch methods can be
// identified on-device. Runs once at SpringBoard startup.

static NSArray<NSString *> *DumpTargetClassPrefixes(void) {
    return @[@"SBIcon", @"SBApplicationIcon", @"SBLeafIcon", @"SBApplication",
             @"SBLiveIcon", @"SBHIcon", @"SnowBoard", @"SBDockIcon",
             @"SBFolderIcon", @"SBIconImage", @"SBIconBadge"];
}

static void GIAppendLine(NSMutableString *out, NSString *line) {
    [out appendFormat:@"%@\n", line];
}

__attribute__((constructor)) static void SBDumpEntry(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSMutableString *out = [NSMutableString string];
        GIAppendLine(out, @"=== GlassIcons runtime class dump (icon pipeline) ===");

        NSArray<NSString *> *prefixes = DumpTargetClassPrefixes();
        NSInteger classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) return;
        NSMutableArray<Class> *allClasses = [NSMutableArray arrayWithCapacity:classCount];
        Class *buffer = (Class *)malloc(sizeof(Class) * classCount);
        if (!buffer) return;
        classCount = objc_getClassList(buffer, classCount);
        for (NSInteger i = 0; i < classCount; i++) [allClasses addObject:buffer[i]];
        free(buffer);

        NSInteger matched = 0;
        for (Class cls in allClasses) {
            NSString *name = NSStringFromClass(cls);
            BOOL hit = NO;
            for (NSString *prefix in prefixes) {
                if ([name hasPrefix:prefix]) { hit = YES; break; }
            }
            if (!hit) continue;

            matched++;
            GIAppendLine(out, [NSString stringWithFormat:@"\n== %@ ==", name]);

            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int i = 0; i < methodCount; i++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                // Keep icon-image-related methods only to keep the file small.
                if ([selector containsString:@"image"] || [selector containsString:@"Icon"] ||
                    [selector containsString:@"icon"] || [selector containsString:@"render"] ||
                    [selector containsString:@"generate"]) {
                    const char *type = method_getTypeEncoding(methods[i]);
                    GIAppendLine(out, [NSString stringWithFormat:@"  -%@  (%s)", selector, type ?: "?"]);
                }
            }
            free(methods);
        }

        GIAppendLine(out, [NSString stringWithFormat:@"\nmatched classes: %ld", (long)matched]);

        NSString *path = @"/var/mobile/Documents/GlassIconsDump.txt";
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[GlassIconsDump] wrote %@ (%lu classes matched)", path, (long)matched);
    });
}
