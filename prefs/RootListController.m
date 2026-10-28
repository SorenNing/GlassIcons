#import "RootListController.h"

@implementation GlassIconsRootListController

-(instancetype)init {
    if ((self = [super init])) self.title = @"GlassIcons";
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GlassIcons";
    // Make the drop folder exist as soon as Settings is opened.
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/GlassIcons/Icons"
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

-(id)preferencesPlistName {
    return @"Root";
}

-(id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    }
    return _specifiers;
}

-(id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.soren.glassicons";
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)domain);
    if (value) return (__bridge_transfer id)value;
    return [specifier propertyForKey:@"default"];
}

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.soren.glassicons";
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soren.glassicons.changed"), NULL, NULL, true);
}

#pragma mark - Icon pack buttons

-(void)glassAlertWithTitle:(NSString *)title message:(NSString *)message copyPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (path.length) {
        [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = path;
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void)reloadIconPack:(PSSpecifier *)specifier {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soren.glassicons.iconpack"), NULL, NULL, true);

    NSString *dir = @"/var/mobile/Library/GlassIcons/Icons";
    NSUInteger count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL].count;
    NSString *message = [NSString stringWithFormat:
        @"已请求重绘桌面图标。\n目录中共 %lu 个文件。\n\n%@", (unsigned long)count, dir];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self glassAlertWithTitle:@"重新加载图标包" message:message copyPath:dir];
    });
}

-(void)openIconPackFolder:(PSSpecifier *)specifier {
    NSString *path = @"/var/mobile/Library/GlassIcons/Icons";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES attributes:nil error:NULL];

    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"filza://view%@", path],
        [NSString stringWithFormat:@"shareddocuments://%@", path],
    ];

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *string in candidates) {
        NSURL *url = [NSURL URLWithString:string];
        if (url) [urls addObject:url];
    }
    [self tryOpenIconFolderURLs:urls index:0 path:path];
}

-(void)tryOpenIconFolderURLs:(NSArray<NSURL *> *)urls index:(NSUInteger)index path:(NSString *)path {
    if (index >= urls.count) {
        [self glassAlertWithTitle:@"图标目录"
                          message:[NSString stringWithFormat:@"没能打开文件管理器，请用 Filza 进入：\n%@", path]
                         copyPath:path];
        return;
    }

    [UIApplication.sharedApplication openURL:urls[index] options:@{} completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) return;   // opened: stop here, do not chain further
            [self tryOpenIconFolderURLs:urls index:index + 1 path:path];
        });
    }];
}

@end
