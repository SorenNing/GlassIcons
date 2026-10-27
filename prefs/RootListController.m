#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <unistd.h>

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

@interface GlassIconsRootListController : PSListController
@end

static BOOL gLoadingSpecifiers = NO;

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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GlassIcons";
    if (!gLoadingSpecifiers) {
        gLoadingSpecifiers = YES;
        @try { [self loadSpecifiersFromPlistName:@"Root" target:self]; }
        @catch (NSException *e) { GILog(@"viewDidLoad load exception: %@", e); }
        gLoadingSpecifiers = NO;
    }
    NSArray *loaded = nil;
    @try { loaded = [super specifiers]; } @catch (__unused NSException *e) {}
    GILog(@"viewDidLoad done, loaded=%lu", (unsigned long)loaded.count);
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

- (NSArray *)glassFallbackSpecifiers {
    NSMutableArray *list = [NSMutableArray array];

    NSString *bundlePath = [[NSBundle bundleForClass:[self class]] bundlePath];
    NSString *rootPath = [bundlePath stringByAppendingPathComponent:@"Root.plist"];
    NSArray *plistSpecifiers = [NSArray arrayWithContentsOfFile:rootPath];
    if (!plistSpecifiers) plistSpecifiers = [NSDictionary dictionaryWithContentsOfFile:rootPath][@"specifiers"];
    NSString *diagnostic = [NSString stringWithFormat:
        @"无法加载 Root.plist，已启用代码兜底。\nbundle=%@\nRoot.plist=%@（%lu 项）\nclass=%@",
        bundlePath.lastPathComponent,
        [[NSFileManager defaultManager] fileExistsAtPath:rootPath] ? @"存在" : @"缺失",
        (unsigned long)plistSpecifiers.count,
        NSStringFromClass([self class])];

    PSSpecifier *group = [self glassSpecifier:@"诊断" cell:PSGlassGroupCell key:nil value:nil];
    [group setProperty:diagnostic forKey:@"footerText"];
    [list addObject:group];

    [list addObject:[self glassSpecifier:@"启用" cell:PSGlassSwitchCell key:@"Enabled" value:@YES]];

    PSSpecifier *appearance = [self glassSpecifier:@"外观" cell:PSGlassGroupCell key:nil value:nil];
    [list addObject:appearance];

    for (NSString *labelKey in @[@"整体强度|Intensity|0.90", @"高光强度|Sheen|0.70", @"描边强度|Rim|0.75"]) {
        NSArray *parts = [labelKey componentsSeparatedByString:@"|"];
        PSSpecifier *slider = [self glassSpecifier:parts[0] cell:PSGlassSliderCell key:parts[1]
                                             value:@([parts[2] doubleValue])];
        [slider setProperty:@0.0 forKey:@"min"];
        [slider setProperty:@1.0 forKey:@"max"];
        [slider setProperty:@YES forKey:@"showValue"];
        [slider setProperty:@YES forKey:@"isContinuous"];
        [list addObject:slider];
    }

    PSSpecifier *footer = [self glassSpecifier:@"" cell:PSGlassGroupCell key:nil value:nil];
    [footer setProperty:@"深色图标会自动减弱高光。" forKey:@"footerText"];
    [list addObject:footer];

    return list;
}

- (NSArray *)specifiers {
    if (gLoadingSpecifiers) {
        NSArray *current = nil;
        @try { current = [super specifiers]; } @catch (__unused NSException *e) {}
        return current ?: @[];
    }

    NSArray *list = nil;
    @try { list = [super specifiers]; } @catch (NSException *e) { GILog(@"super specifiers exception: %@", e); }
    GILog(@"specifiers: super count=%lu", (unsigned long)list.count);

    if (list.count == 0) {
        gLoadingSpecifiers = YES;
        @try { [self loadSpecifiersFromPlistName:@"Root" target:self]; }
        @catch (NSException *e) { GILog(@"loadSpecifiersFromPlistName exception: %@", e); }
        gLoadingSpecifiers = NO;
        @try { list = [super specifiers]; } @catch (NSException *e) { GILog(@"reload specifiers exception: %@", e); }
        GILog(@"specifiers: after explicit load count=%lu", (unsigned long)list.count);
    }

    if (list.count > 0) return list;
    GILog(@"specifiers: falling back to code-built list");
    return [self glassFallbackSpecifiers];
}

@end
