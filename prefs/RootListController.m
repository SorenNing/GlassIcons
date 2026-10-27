#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

#define kGlassDomain CFSTR("com.soren.glassicons")

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

static NSString * const kKeys[] = {@"Intensity", @"Sheen", @"Rim"};
static NSString * const kNames[] = {@"整体强度", @"高光强度", @"描边强度"};
static double const kDefaults[] = {0.90, 0.70, 0.75};

@interface GlassIconsRootListController : UITableViewController
@end

@implementation GlassIconsRootListController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GlassIcons";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60.0;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    GILog(@"custom table ready (no PSListController pipeline)");
}

- (double)currentValueForKey:(NSString *)key fallback:(double)fallback {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kGlassDomain);
    double result = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = fallback;
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
            result = number;
        }
        CFRelease(value);
    }
    return result;
}

- (BOOL)currentEnabled {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), kGlassDomain);
    BOOL result = YES;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)value);
        }
        CFRelease(value);
    }
    return result;
}

- (void)writeValue:(id)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kGlassDomain);
    CFPreferencesAppSynchronize(kGlassDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soren.glassicons.changed"), NULL, NULL, true);
}

#pragma mark - Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"玻璃图标" : @"外观";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"给桌面图标叠加玻璃高光与描边。文件夹与小预览自动跳过，深色图标自动减弱。";
    }
    return @"调整后立即生效（回桌面滑动一下即可刷新）。紧急停用：创建 /var/mobile/Library/local.glassicons.disabled 后 respring。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"启用";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [self currentEnabled];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.detailTextLabel.text = nil;
        return cell;
    }

    NSInteger index = indexPath.row;
    cell.textLabel.text = kNames[index];

    CGFloat value = (CGFloat)[self currentValueForKey:kKeys[index] fallback:kDefaults[index]];
    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 20)];
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    valueLabel.textColor = UIColor.secondaryLabelColor;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100.0];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
    slider.minimumValue = 0.0;
    slider.maximumValue = 1.0;
    slider.value = value;
    slider.tag = index;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];

    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 206, 32)];
    valueLabel.frame = CGRectMake(0, 6, 44, 20);
    slider.frame = CGRectMake(52, 1, 150, 30);
    [accessory addSubview:valueLabel];
    [accessory addSubview:slider];
    cell.accessoryView = accessory;
    cell.detailTextLabel.text = nil;
    return cell;
}

#pragma mark - Actions

- (void)toggleChanged:(UISwitch *)toggle {
    [self writeValue:@(toggle.on) forKey:@"Enabled"];
    GILog(@"Enabled -> %@", toggle.on ? @"YES" : @"NO");
}

- (void)sliderChanged:(UISlider *)slider {
    NSInteger index = slider.tag;
    double value = slider.value;
    [self writeValue:@(value) forKey:kKeys[index]];

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:1]];
    UIView *accessory = cell.accessoryView;
    UILabel *label = accessory.subviews.firstObject;
    label.text = [NSString stringWithFormat:@"%.0f%%", value * 100.0];
}

@end
