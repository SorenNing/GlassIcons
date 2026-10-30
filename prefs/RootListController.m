#import "RootListController.h"
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kGISettingsDomain = @"com.soren.glassicons";
static NSString *const kGIThemePreferenceKey = @"IconPackTheme";
static NSString *const kGIThemeDefaultValue = @"Default";
static NSString *const kGIIconPackDefaultPath = @"/var/mobile/Library/GlassIcons/Icons";
static NSString *const kGIThemeRootPath = @"/var/mobile/Library/GlassIcons/Themes";
static NSString *const kGISettingsChangedNotification = @"com.soren.glassicons.changed";
static NSString *const kGIIconPackChangedNotification = @"com.soren.glassicons.iconpack";

static NSString *GITrimThemeName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return nil;
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL GIThemeNameIsSafe(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    if (![name isEqualToString:GITrimThemeName(name)]) return NO;
    if ([name caseInsensitiveCompare:kGIThemeDefaultValue] == NSOrderedSame) return NO;
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
    if ([name rangeOfCharacterFromSet:unsafe].location != NSNotFound) return NO;
    if ([name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return NO;
    const char *bytes = name.fileSystemRepresentation;
    return bytes && strlen(bytes) > 0 && strlen(bytes) <= NAME_MAX;
}

static NSError *GIFileError(int code, NSString *operation) {
    NSString *reason = [NSString stringWithUTF8String:strerror(code)] ?: @"未知文件错误";
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"%@：%@", operation, reason]}];
}

// Anchor all managed components at the real mobile Library, then open each
// component relative to its parent without following symlinks. /var itself is
// normally a system symlink on iOS and is intentionally allowed as an ancestor.
static int GIOpenChildDirectory(int parent, NSString *component, BOOL create,
                                BOOL exclusive, NSError **error) {
    const char *bytes = [component isKindOfClass:[NSString class]] ? component.fileSystemRepresentation : NULL;
    if (!bytes || !*bytes) {
        if (error) *error = GIFileError(EINVAL, @"无效目录名");
        return -1;
    }
    if (create && mkdirat(parent, bytes, 0755) != 0) {
        int code = errno;
        if (code != EEXIST || exclusive) {
            if (error) *error = GIFileError(code, @"创建目录失败");
            return -1;
        }
    }
    int fd = openat(parent, bytes, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && error) *error = GIFileError(errno, @"目录不存在、不可访问或是符号链接");
    return fd;
}

static int GIOpenGlassRoot(BOOL create, NSError **error) {
    int library = open("/var/mobile/Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (library < 0) {
        if (error) *error = GIFileError(errno, @"无法打开 /var/mobile/Library");
        return -1;
    }
    int root = GIOpenChildDirectory(library, @"GlassIcons", create, NO, error);
    close(library);
    return root;
}

static int GIOpenThemeRoot(BOOL create, NSError **error) {
    int root = GIOpenGlassRoot(create, error);
    if (root < 0) return -1;
    int themes = GIOpenChildDirectory(root, @"Themes", create, NO, error);
    close(root);
    return themes;
}

// A named theme must already exist; only the legacy default can be created here.
static int GIOpenThemeDirectory(NSString *name, BOOL createDefault, NSError **error) {
    if ([name isKindOfClass:[NSString class]] && [name isEqualToString:kGIThemeDefaultValue]) {
        int root = GIOpenGlassRoot(createDefault, error);
        if (root < 0) return -1;
        int icons = GIOpenChildDirectory(root, @"Icons", createDefault, NO, error);
        close(root);
        return icons;
    }
    if (!GIThemeNameIsSafe(name)) {
        if (error) *error = GIFileError(EINVAL, @"无效主题名");
        return -1;
    }
    int themes = GIOpenThemeRoot(NO, error);
    if (themes < 0) return -1;
    int theme = GIOpenChildDirectory(themes, name, NO, NO, error);
    close(themes);
    return theme;
}

static BOOL GICreateThemeDirectory(NSString *name, NSError **error) {
    if (!GIThemeNameIsSafe(name)) {
        if (error) *error = GIFileError(EINVAL, @"无效主题名");
        return NO;
    }
    int themes = GIOpenThemeRoot(YES, error);
    if (themes < 0) return NO;
    // Exclusive creation prevents a pre-existing file, symlink or directory
    // from being silently accepted as a newly created theme.
    int theme = GIOpenChildDirectory(themes, name, YES, YES, error);
    close(themes);
    if (theme < 0) return NO;
    close(theme);
    return YES;
}

// An absent theme selects Default; a malformed stored value is different:
// the plan B service rejects it rather than silently applying Default.
static NSString *GIStoredThemeName(BOOL *invalid) {
    if (invalid) *invalid = NO;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kGISettingsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIThemePreferenceKey,
                                                        (__bridge CFStringRef)kGISettingsDomain);
    if (!value) return kGIThemeDefaultValue;
    NSString *name = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        name = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    if ([name isEqualToString:kGIThemeDefaultValue] || GIThemeNameIsSafe(name)) return name;
    if (invalid) *invalid = YES;
    return kGIThemeDefaultValue;
}

static NSString *GIPathForThemeName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] ||
        [name isEqualToString:kGIThemeDefaultValue] || !GIThemeNameIsSafe(name)) {
        return kGIIconPackDefaultPath;
    }
    return [kGIThemeRootPath stringByAppendingPathComponent:name];
}

static NSArray<NSString *> *GIAvailableThemeNames(NSError **error) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:kGIThemeDefaultValue];
    int themes = GIOpenThemeRoot(YES, error);
    if (themes < 0) return names;
    DIR *directory = fdopendir(themes); // takes ownership of themes on success
    if (!directory) {
        int code = errno;
        close(themes);
        if (error) *error = GIFileError(code, @"读取主题列表失败");
        return names;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            if (errno && error) *error = GIFileError(errno, @"读取主题列表失败");
            break;
        }
        NSString *name = [fm stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!GIThemeNameIsSafe(name)) continue;
        struct stat st;
        if (fstatat(dirfd(directory), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode)) {
            [names addObject:name];
        }
    }
    closedir(directory);
    [names sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        if ([left isEqualToString:right]) return NSOrderedSame;
        if ([left isEqualToString:kGIThemeDefaultValue]) return NSOrderedAscending;
        if ([right isEqualToString:kGIThemeDefaultValue]) return NSOrderedDescending;
        NSComparisonResult result = [left localizedCaseInsensitiveCompare:right];
        return result == NSOrderedSame ? [left compare:right] : result;
    }];
    return names;
}

static void GIPostNotification(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, true);
}

// Reads must agree with consumers that require CFBoolean: malformed numeric
// switches fall back instead of looking enabled. Writes normalize 0/1 to CFBoolean.
static id GIValidatedPreferenceValue(id value, id fallback, BOOL writing) {
    if (![fallback isKindOfClass:[NSNumber class]] || ![value isKindOfClass:[NSNumber class]]) return nil;
    BOOL wantsBoolean = CFGetTypeID((__bridge CFTypeRef)fallback) == CFBooleanGetTypeID();
    BOOL isBoolean = CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
    double number = [value doubleValue];
    if (!isfinite(number)) return nil;
    if (wantsBoolean) {
        if (!isBoolean && !writing) return nil;
        if (number != 0.0 && number != 1.0) return nil;
        return @(number == 1.0);
    }
    return isBoolean ? nil : value;
}

@implementation GlassIconsRootListController

-(instancetype)init {
    if ((self = [super init])) self.title = @"GlassIcons";
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GlassIcons";
    // Best effort only; actions report errors explicitly if the path is unsafe.
    int icons = GIOpenThemeDirectory(kGIThemeDefaultValue, YES, NULL);
    if (icons >= 0) close(icons);
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
    id fallback = [specifier propertyForKey:@"default"];
    id key = [specifier propertyForKey:@"key"];
    id domain = [specifier propertyForKey:@"defaults"];
    if (![key isKindOfClass:[NSString class]] || ![key length]) return fallback;
    if (![domain isKindOfClass:[NSString class]] || ![domain length]) domain = kGISettingsDomain;
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)domain);
    id result = value ? GIValidatedPreferenceValue((__bridge id)value, fallback, NO) : nil;
    // The plan B service fails closed for a malformed, present pack switch;
    // an absent key still uses the legacy YES default.
    if (value && !result && [key isEqualToString:@"IconPackEnabled"]) result = @NO;
    if (value) CFRelease(value);
    return result ?: fallback;
}

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    id key = [specifier propertyForKey:@"key"];
    id domain = [specifier propertyForKey:@"defaults"];
    if (![key isKindOfClass:[NSString class]] || ![key length]) return;
    if (![domain isKindOfClass:[NSString class]] || ![domain length]) domain = kGISettingsDomain;
    id validated = GIValidatedPreferenceValue(value, [specifier propertyForKey:@"default"], YES);
    if (!validated) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)validated,
                             (__bridge CFStringRef)domain);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)domain)) {
        [self glassAlertWithTitle:@"设置同步失败"
                          message:@"无法确认设置已写入；进程内缓存可能已改变。请检查权限并重新打开设置核对。"
                         copyPath:nil];
        return;
    }
    GIPostNotification(kGISettingsChangedNotification);
    if ([key isEqualToString:@"IconPackEnabled"]) GIPostNotification(kGIIconPackChangedNotification);
    if ([key isEqualToString:@"IconServiceEnabled"]) {
        [self glassAlertWithTitle:@"服务开关已保存"
                          message:@"更改后需重启 iconservicesagent 进程；关闭开关不会卸载已运行进程中的 hook。设置页不会自动重启进程，也无法确认更改已生效。旧的 IconPackEnabled 设置保持不变，图标替换需要两个开关同时开启。"
                         copyPath:nil];
    }
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

-(void)saveSelectedTheme:(NSString *)name {
    NSError *error = nil;
    int dir = GIOpenThemeDirectory(name, YES, &error);
    if (dir < 0) {
        [self glassAlertWithTitle:@"无法选择主题"
                          message:[NSString stringWithFormat:@"目录不存在、不可访问或不安全：%@", error.localizedDescription ?: @"未知错误"]
                         copyPath:nil];
        return;
    }
    close(dir);
    CFPreferencesSetAppValue((__bridge CFStringRef)kGIThemePreferenceKey,
                             (__bridge CFStringRef)name, (__bridge CFStringRef)kGISettingsDomain);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)kGISettingsDomain)) {
        [self glassAlertWithTitle:@"主题同步失败"
                          message:@"无法确认首选项已写入；进程内缓存可能已改变。请检查权限并重新打开设置核对。已创建的目录会保留。"
                         copyPath:GIPathForThemeName(name)];
        return;
    }
    GIPostNotification(kGISettingsChangedNotification);
    GIPostNotification(kGIIconPackChangedNotification);
    NSString *path = GIPathForThemeName(name);
    NSString *message = [NSString stringWithFormat:
        @"已保存主题“%@”并发送变更及重载通知。\n设置中的目录：\n%@\n\n无法确认图标服务已收到通知或桌面缓存已更新；服务安全开关变更需重启进程。",
        [name isEqualToString:kGIThemeDefaultValue] ? @"默认（旧 Icons 目录）" : name, path];
    [self glassAlertWithTitle:@"主题已保存" message:message copyPath:path];
}

-(void)selectIconPackTheme:(PSSpecifier *)specifier {
    (void)specifier;
    BOOL invalid = NO;
    NSString *current = GIStoredThemeName(&invalid);
    NSError *error = nil;
    NSArray<NSString *> *names = GIAvailableThemeNames(&error);
    NSString *currentLabel = invalid ? @"存储值无效，请重新选择" :
        ([current isEqualToString:kGIThemeDefaultValue] ? @"默认（旧 Icons 目录）" : current);
    BOOL currentMissing = !invalid && ![names containsObject:current];
    NSString *message = [NSString stringWithFormat:
        @"当前选择：%@\n选择只会保存并发送通知，不保证运行中的服务或桌面缓存已更新。%@%@",
        currentLabel,
        currentMissing ? @"\n当前主题目录不存在、不可访问或不安全；请重新选择。" : @"",
        error ? [NSString stringWithFormat:@"\n\n读取主题目录失败：%@", error.localizedDescription] : @""];
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择主题"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        NSString *label = [name isEqualToString:kGIThemeDefaultValue] ? @"默认（旧 Icons 目录）" : name;
        if (!invalid && [name isEqualToString:current]) label = [label stringByAppendingString:@" ✓"];
        [picker addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            // Let the action sheet finish dismissing before presenting feedback.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self saveSelectedTheme:name]; });
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = picker.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:picker animated:YES completion:nil];
}

-(void)createIconPackTheme:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"创建主题"
        message:@"输入目录名。不能使用 /、\\、:、控制字符，不能使用 .、.. 或保留名 Default；最多 255 字节。创建空目录并保存为当前选择，不保证图标服务或桌面缓存已更新。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"主题目录名";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"创建并选择" style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        NSString *name = GITrimThemeName(weakAlert.textFields.firstObject.text);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!GIThemeNameIsSafe(name)) {
                [self glassAlertWithTitle:@"主题名无效" message:@"请使用单个安全目录名，不能使用路径、保留名或控制字符。" copyPath:nil];
                return;
            }
            NSError *error = nil;
            if (!GICreateThemeDirectory(name, &error)) {
                [self glassAlertWithTitle:@"创建主题失败"
                                  message:[NSString stringWithFormat:@"%@\n已有同名目录时请在“选择主题”中选择。", error.localizedDescription ?: @"未知错误"]
                                 copyPath:nil];
                return;
            }
            [self saveSelectedTheme:name];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void)reloadIconPack:(PSSpecifier *)specifier {
    (void)specifier;
    GIPostNotification(kGIIconPackChangedNotification);
    BOOL invalid = NO;
    NSString *name = GIStoredThemeName(&invalid);
    if (invalid) {
        [self glassAlertWithTitle:@"重新加载图标包"
                          message:@"已发送重载请求，但存储的主题值无效；请先在“选择主题”中重新选择有效主题。不能确认服务或桌面缓存已更新。"
                         copyPath:nil];
        return;
    }
    NSString *path = GIPathForThemeName(name);
    NSString *message = [NSString stringWithFormat:
        @"已发送重载请求，无法确认运行中的服务是否监听、收到或重建索引，也无法保证桌面缓存已更新。\n设置中选择的目录：\n%@\n\n重载不会开启服务；服务安全开关变更需重启进程。", path];
    [self glassAlertWithTitle:@"重新加载图标包" message:message copyPath:path];
}

-(void)openIconPackFolder:(PSSpecifier *)specifier {
    (void)specifier;
    BOOL invalid = NO;
    NSString *name = GIStoredThemeName(&invalid);
    if (invalid) {
        [self glassAlertWithTitle:@"无法打开目录"
                          message:@"存储的主题值无效，请先在“选择主题”中重新选择有效主题。"
                         copyPath:nil];
        return;
    }
    NSString *path = GIPathForThemeName(name);
    NSError *error = nil;
    int dir = GIOpenThemeDirectory(name, YES, &error);
    if (dir < 0) {
        [self glassAlertWithTitle:@"无法打开目录"
                          message:[NSString stringWithFormat:@"目录不存在、不可访问或不安全：%@\n\n%@", error.localizedDescription ?: @"未知错误", path]
                         copyPath:path];
        return;
    }
    close(dir);

    // NSURLComponents percent-encodes spaces, non-ASCII and URL delimiters.
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"filza";
    components.host = @"view";
    components.path = path;
    NSURL *url = components.URL;
    if (!url) {
        [self glassAlertWithTitle:@"图标目录" message:@"无法生成文件管理器链接，请复制路径手动打开。" copyPath:path];
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self glassAlertWithTitle:@"图标目录"
                              message:[NSString stringWithFormat:@"无法打开 Filza，请复制路径并用文件管理器手动进入：\n%@", path]
                             copyPath:path];
        });
    }];
}

@end
