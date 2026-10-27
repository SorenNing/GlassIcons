#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

#define kGlassDomain CFSTR("com.soren.glassicons")

typedef NS_ENUM(NSInteger, PSGlassCellType) {
    PSGlassGroupCell = 0,
    PSGlassLinkCell = 1,
    PSGlassSliderCell = 5,
    PSGlassSwitchCell = 6
};

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(NSInteger)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface GlassIconsRootListController : PSListController
@end

static BOOL gApplyingSpecifiers = NO;

static void GILog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSString *path = @"/var/mobile/Library/GlassIconsPrefs.log";
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

@implementation GlassIconsRootListController

+ (void)load {
    GILog(@"bundle loaded: %@", [[NSBundle bundleForClass:self] bundlePath]);
}

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"GlassIcons";
        GILog(@"init ok, class=%@", NSStringFromClass([self class]));
    }
    return self;
}

- (NSString *)title {
    return @"GlassIcons";
}

- (id)glassReadValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    if (!key) return fallback ?: @(0);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kGlassDomain);
    id result = value ? (__bridge_transfer id)value : nil;
    return result ?: (fallback ?: @(0));
}

- (void)glassWriteValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kGlassDomain);
    CFPreferencesAppSynchronize(kGlassDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soren.glassicons.changed"), NULL, NULL, true);
}

- (PSSpecifier *)glassSpecifier:(NSString *)label cell:(NSInteger)cell key:(NSString *)key value:(id)value {
    PSSpecifier *specifier = nil;
    if (cell == PSGlassGroupCell) {
        specifier = [PSSpecifier preferenceSpecifierNamed:label target:self set:NULL get:NULL
                                                   detail:nil cell:PSGlassGroupCell edit:nil];
    } else {
        specifier = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                      set:@selector(glassWriteValue:specifier:)
                                                      get:@selector(glassReadValue:)
                                                   detail:nil cell:cell edit:nil];
        [specifier setProperty:key forKey:@"key"];
        [specifier setProperty:value forKey:@"default"];
    }
    return specifier;
}

- (NSArray *)glassCodeSpecifiers {
    NSMutableArray *list = [NSMutableArray array];

    NSString *bundlePath = [[NSBundle bundleForClass:[self class]] bundlePath];
    NSString *rootPath = [bundlePath stringByAppendingPathComponent:@"Root.plist"];
    BOOL rootExists = [[NSFileManager defaultManager] fileExistsAtPath:rootPath];

    PSSpecifier *diagnostic = [self glassSpecifier:@"诊断" cell:PSGlassGroupCell key:nil value:nil];
    [diagnostic setProperty:[NSString stringWithFormat:@"bundle=%@ · Root.plist=%@", bundlePath.lastPathComponent,
                                                      rootExists ? @"存在" : @"缺失"]
                     forKey:@"footerText"];
    [list addObject:diagnostic];

    [list addObject:[self glassSpecifier:@"启用" cell:PSGlassSwitchCell key:@"Enabled" value:@YES]];
    [list addObject:[self glassSpecifier:@"外观" cell:PSGlassGroupCell key:nil value:nil]];

    NSArray *sliders = @[@[@"整体强度", @"Intensity", @0.90],
                         @[@"高光强度", @"Sheen", @0.70],
                         @[@"描边强度", @"Rim", @0.75]];
    for (NSArray *parts in sliders) {
        PSSpecifier *slider = [self glassSpecifier:parts[0] cell:PSGlassSliderCell key:parts[1] value:parts[2]];
        [slider setProperty:@0.0 forKey:@"min"];
        [slider setProperty:@1.0 forKey:@"max"];
        [slider setProperty:@YES forKey:@"showValue"];
        [slider setProperty:@YES forKey:@"isContinuous"];
        [list addObject:slider];
    }

    PSSpecifier *footer = [self glassSpecifier:@"" cell:PSGlassGroupCell key:nil value:nil];
    [footer setProperty:@"深色图标会自动减弱高光。紧急停用：创建 /var/mobile/Library/local.glassicons.disabled 后 respring。"
                forKey:@"footerText"];
    [list addObject:footer];
    return list;
}

- (NSArray *)glassResolvedSpecifiers {
    NSArray *list = nil;
    @try { list = [super specifiers]; } @catch (__unused NSException *e) {}
    if (list.count > 0) return list;

    @try { [self loadSpecifiersFromPlistName:@"Root" target:self]; } @catch (__unused NSException *e) {}
    @try { list = [super specifiers]; } @catch (__unused NSException *e) {}
    if (list.count > 0) return list;

    return [self glassCodeSpecifiers];
}

- (NSArray *)specifiers {
    if (gApplyingSpecifiers) {
        NSArray *current = nil;
        @try { current = [super specifiers]; } @catch (__unused NSException *e) {}
        return current ?: @[];
    }
    return [self glassResolvedSpecifiers];
}

// iOS 17 drives the table straight from PSListController's internal specifier
// array, so overriding -specifiers alone is not enough: write the ivar by KVC.
- (void)glassApplySpecifiers {
    if (gApplyingSpecifiers) return;
    gApplyingSpecifiers = YES;

    NSArray *list = [self glassResolvedSpecifiers];
    BOOL didSet = NO;
    @try {
        [self setValue:list forKey:@"specifiers"];
        didSet = YES;
    } @catch (NSException *e) {
        GILog(@"KVC set specifiers failed: %@", e);
    }

    NSArray *stored = nil;
    @try { stored = [self valueForKey:@"specifiers"]; } @catch (__unused NSException *e) {}
    GILog(@"apply: built=%lu kvc=%d stored=%lu", (unsigned long)list.count, didSet, (unsigned long)stored.count);

    gApplyingSpecifiers = NO;

    @try { [self reloadSpecifiers]; } @catch (NSException *e) { GILog(@"reloadSpecifiers exception: %@", e); }

    NSArray *after = nil;
    @try { after = [self valueForKey:@"specifiers"]; } @catch (__unused NSException *e) {}
    GILog(@"apply done: stored=%lu", (unsigned long)after.count);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GlassIcons";
    [self glassApplySpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self glassApplySpecifiers];
}

@end
