#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Icon engine (GIIconEngine.m)
void GIIconEngineInstall(void);
void GIIconEngineReload(void);
BOOL GIEngineIconHasPackIcon(id icon);
BOOL GIEnginePackGlassOverlayEnabled(void);

// ============================================================
// GlassIcons.m — glass overlay on SpringBoard icon surfaces
// ============================================================

static const void *kGlassOverlayKey = &kGlassOverlayKey;
static const void *kGlassSignatureKey = &kGlassSignatureKey;
static const void *kPackIconSkipKey = &kPackIconSkipKey;

static NSHashTable *gTrackedViews = nil;

// ============================================================
// Logging
// ============================================================

void GILogMain(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSString *path = @"/var/mobile/Library/GlassIcons.log";
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *e) {}
}

// ============================================================
// Preferences
// ============================================================

static BOOL gEnabled = YES;
static CGFloat gIntensity = 0.35;
static CGFloat gRim = 0.50;
static CGFloat gSheen = 0.30;
static BOOL gBadgeGlass = YES;
static CFAbsoluteTime gLastPrefsLoad = 0;

static void GIReadPreferences(void) {
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("GlassIconEnabled"), CFSTR("com.soren.glassicons"));
    if (ref) {
        gEnabled = CFGetTypeID(ref) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)ref) : YES;
        CFRelease(ref);
    }
    ref = CFPreferencesCopyAppValue(CFSTR("GlassIconIntensity"), CFSTR("com.soren.glassicons"));
    if (ref) {
        gIntensity = [(__bridge NSNumber *)ref floatValue];
        CFRelease(ref);
    }
    ref = CFPreferencesCopyAppValue(CFSTR("GlassIconRim"), CFSTR("com.soren.glassicons"));
    if (ref) {
        gRim = [(__bridge NSNumber *)ref floatValue];
        CFRelease(ref);
    }
    ref = CFPreferencesCopyAppValue(CFSTR("GlassIconSheen"), CFSTR("com.soren.glassicons"));
    if (ref) {
        gSheen = [(__bridge NSNumber *)ref floatValue];
        CFRelease(ref);
    }
    ref = CFPreferencesCopyAppValue(CFSTR("BadgeGlass"), CFSTR("com.soren.glassicons"));
    if (ref) {
        gBadgeGlass = CFGetTypeID(ref) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)ref) : YES;
        CFRelease(ref);
    }
}

static void GIReloadPreferencesIfNeeded(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastPrefsLoad < 2.5) return;
    gLastPrefsLoad = now;
    GIReadPreferences();
}

// ============================================================
// Helpers
// ============================================================

static BOOL GIShouldSkipView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return YES;
    NSString *name = NSStringFromClass([view class]);
    if ([name containsString:@"Folder"]) return YES;
    if ([name containsString:@"SBIconImageCrossfadeView"]) return YES;
    // Cache the pack-icon skip result to avoid repeated KVC + file-system checks
    NSNumber *cachedSkip = objc_getAssociatedObject(view, kPackIconSkipKey);
    if (cachedSkip) return [cachedSkip boolValue];
    BOOL shouldSkip = NO;
    @try {
        id icon = [view valueForKey:@"icon"];
        if (icon) {
            NSString *iconName = NSStringFromClass([icon class]);
            if ([iconName containsString:@"Folder"]) shouldSkip = YES;
            // If this icon has a custom icon-pack replacement, skip glass overlay
            // unless the user explicitly asked for glass on top of pack icons.
            if (!shouldSkip && GIEngineIconHasPackIcon(icon)) {
                shouldSkip = !GIEnginePackGlassOverlayEnabled();
            }
        }
    } @catch (__unused NSException *e) {}
    objc_setAssociatedObject(view, kPackIconSkipKey, [NSNumber numberWithBool:shouldSkip], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return shouldSkip;
}

static CGFloat GIStrengthForView(UIImage *image, UIView *view) {
    CGFloat factor = 1.0;
    CGSize viewSize = view.bounds.size;
    CGFloat minSide = MIN(viewSize.width, viewSize.height);
    (void)minSide;
    if (image) {
        CGFloat imgMinSide = MIN(image.size.width, image.size.height);
        factor = imgMinSide / 180.0;
        if (factor < 0.5) factor = 0.5;
        if (factor > 1.5) factor = 1.5;
    }
    CGFloat strength = gIntensity * factor;
    if (strength > 0.6) strength = 0.6;
    if (strength < 0) strength = 0;
    return strength;
}

static UIImage *GITileImage(UIImage *image, CGSize targetSize, CGFloat cornerRadius) __attribute__((unused));
static UIImage *GITileImage(UIImage *image, CGSize targetSize, CGFloat cornerRadius) {
    (void)cornerRadius;
    UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    (void)ctx;
    CGFloat scale = targetSize.width / image.size.width;
    CGRect drawRect = (CGRect){{0, 0}, {image.size.width * scale, image.size.height * scale}};
    [image drawInRect:drawRect];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

// ============================================================
// Glass overlay
// ============================================================

static void GIUpdateOverlay(UIView *view) {
    if (!view) return;
    if (!gEnabled) {
        CALayer *existing = objc_getAssociatedObject(view, kGlassOverlayKey);
        if (existing) {
            [existing removeFromSuperlayer];
            objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (GIShouldSkipView(view)) return;

    GIReloadPreferencesIfNeeded();

    UIImage *image = nil;
    for (NSString *key in @[@"image"]) {
        @try {
            id val = [view valueForKey:key];
            if ([val isKindOfClass:[UIImage class]]) { image = val; break; }
        } @catch (__unused NSException *e) {}
    }
    if (!image) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)sub;
                if (iv.image) { image = iv.image; break; }
            }
        }
    }

    CGFloat strength = GIStrengthForView(image, view);
    NSString *signature = [NSString stringWithFormat:@"%.0fx%.0f|%.2f|%.0fx%.0f",
                           view.bounds.size.width, view.bounds.size.height,
                           strength, (image ? image.size.width : 0), (image ? image.size.height : 0)];

    CALayer *overlay = objc_getAssociatedObject(view, kGlassOverlayKey);
    NSString *oldSig = (NSString *)objc_getAssociatedObject(view, kGlassSignatureKey);
    if (overlay && [oldSig isEqualToString:signature]) return;

    if (overlay) [overlay removeFromSuperlayer];

    overlay = [CALayer layer];
    overlay.frame = view.bounds;
    overlay.cornerRadius = MIN(view.bounds.size.width, view.bounds.size.height) * 0.225;
    overlay.masksToBounds = YES;

    CALayer *rim = [CALayer layer];
    rim.frame = overlay.bounds;
    rim.cornerRadius = overlay.cornerRadius;
    rim.borderWidth = MAX(0.6, MIN(1.0, MIN(view.bounds.size.width, view.bounds.size.height) * 0.030));
    rim.borderColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:gRim * strength].CGColor;
    [overlay addSublayer:rim];

    [view.layer addSublayer:overlay];
    objc_setAssociatedObject(view, kGlassOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kGlassSignatureKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!gTrackedViews) gTrackedViews = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory];
    [gTrackedViews addObject:view];
}

// ============================================================
// Hook: SBIconImageView layoutSubviews
// ============================================================

static IMP gOrigLayoutSubviews = NULL;

static void GIHookedLayoutSubviews(id self, SEL _cmd) {
    if (gOrigLayoutSubviews) {
        ((void (*)(id, SEL))gOrigLayoutSubviews)(self, _cmd);
    }
    @try {
        GIUpdateOverlay(self);
    } @catch (__unused NSException *e) {}
}

static void GIHookInstall(void) {
    Class cls = NSClassFromString(@"SBIconImageView");
    if (!cls) {
        GILogMain(@"hook: class missing SBIconImageView");
        return;
    }
    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!method) {
        GILogMain(@"hook: SBIconImageView has no layoutSubviews");
        return;
    }
    gOrigLayoutSubviews = method_getImplementation(method);
    // class_addMethod adds to cls's own method list, shadowing inherited
    // implementations — safe for all views. Falls back to
    // method_setImplementation only if the selector already exists in
    // cls's own method list.
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, @selector(layoutSubviews), (IMP)GIHookedLayoutSubviews, types)) {
        GILogMain(@"hook ok: SBIconImageView layoutSubviews (class_addMethod)");
    } else {
        method_setImplementation(method, (IMP)GIHookedLayoutSubviews);
        GILogMain(@"hook ok: SBIconImageView layoutSubviews (method_setImplementation)");
    }
}

// ============================================================
// Window scan
// ============================================================

static void GIWalkForIcons(UIView *view, int depth) {
    if (!view || depth > 30) return;
    NSString *name = NSStringFromClass([view class]);
    if ([name hasPrefix:@"SBIconImageView"] || [name hasPrefix:@"SBIconImage"]) {
        @try { GIUpdateOverlay(view); } @catch (__unused NSException *e) {}
    }
    for (UIView *sub in view.subviews) {
        GIWalkForIcons(sub, depth + 1);
    }
}

static void GIScanAllIcons(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in app.windows) {
            (void)window;
            GIWalkForIcons(window, 0);
        }
#pragma clang diagnostic pop
    });
    GIReadPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *view in [gTrackedViews allObjects]) {
            if (view) {
                objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(view, kGlassSignatureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // Clear stale pack-icon skip cache so new icons are picked up after reload
                objc_setAssociatedObject(view, kPackIconSkipKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                @try { GIUpdateOverlay(view); } @catch (__unused NSException *e) {}
            }
        }
    });
}

// ============================================================
// Preferences change notification
// ============================================================

static void GIPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, void *object,
                                  CFDictionaryRef info) {
    (void)center; (void)observer; (void)object; (void)info;
    NSString *nameStr = (__bridge NSString *)name;
    BOOL isIconPack = [nameStr isEqualToString:@"com.soren.glassicons.iconpack"];
    BOOL isChanged = [nameStr isEqualToString:@"com.soren.glassicons.changed"];
    if (!isIconPack && !isChanged) return;
    if (isIconPack) GIIconEngineReload();
    GIReadPreferences();
    GIScanAllIcons();
}

// ============================================================
// Init
// ============================================================

extern void GIIconEngineInstall(void);

__attribute__((constructor)) static void GIInitialize(void) {
    gTrackedViews = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory];
    GIReadPreferences();

    // Icon replacement engine (data-layer hooks)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        GIIconEngineInstall();
    });

    // Glass overlay hook
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        GIHookInstall();
        GIScanAllIcons();
    });

    // Periodic scans for new icons
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GIScanAllIcons(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GIScanAllIcons(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GIScanAllIcons(); });

    // Preferences change notification
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwin, NULL,
                                    (CFNotificationCallback)GIPreferencesChanged,
                                    NULL, @"com.soren.glassicons.changed",
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(darwin, NULL,
                                    (CFNotificationCallback)GIPreferencesChanged,
                                    NULL, @"com.soren.glassicons.iconpack",
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
