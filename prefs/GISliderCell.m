#import "GISliderCell.h"

static double GICellNumber(id value, double fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

@implementation GISliderCell {
    UISlider *_slider;
    UILabel *_valueLabel;
}

- (instancetype)initWithStyle:(long)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.clipsToBounds = NO;

        _slider = [[UISlider alloc] init];
        [_slider addTarget:self action:@selector(glassValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_slider];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        _valueLabel.textColor = UIColor.labelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];
    }
    return self;
}

- (double)glassReadPreference {
    @try {
        NSString *key = [self.specifier propertyForKey:@"key"];
        double fallback = GICellNumber([self.specifier propertyForKey:@"default"], 0.0);
        if (!key.length) return fallback;
        NSString *domain = [self.specifier propertyForKey:@"defaults"] ?: @"com.soren.glassicons";
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
        double result = fallback;
        if (value) {
            if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                double number = fallback;
                CFNumberGetValue(value, kCFNumberDoubleType, &number);
                result = number;
            }
            CFRelease(value);
        }
        return result;
    } @catch (__unused NSException *e) {
        return 0.0;
    }
}

- (void)glassWritePreference:(double)number {
    @try {
        NSString *key = [self.specifier propertyForKey:@"key"];
        if (!key.length) return;
        NSString *domain = [self.specifier propertyForKey:@"defaults"] ?: @"com.soren.glassicons";
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(number), (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.soren.glassicons.changed"), NULL, NULL, true);
    } @catch (__unused NSException *e) {}
}

- (void)glassSyncValue {
    if (!self.specifier || !_slider) return;
    @try {
        double minimum = GICellNumber([self.specifier propertyForKey:@"min"], 0.0);
        double maximum = GICellNumber([self.specifier propertyForKey:@"max"], 1.0);
        if (maximum <= minimum) maximum = minimum + 1.0;
        double value = [self glassReadPreference];
        value = fmax(minimum, fmin(maximum, value));

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _slider.minimumValue = (float)minimum;
        _slider.maximumValue = (float)maximum;
        _slider.value = (float)value;
        [CATransaction commit];

        _valueLabel.text = [NSString stringWithFormat:@"%.2f", value];
    } @catch (__unused NSException *e) {}
}

- (void)layoutSubviews {
    [super layoutSubviews];
    @try {
        CGFloat width = self.contentView.bounds.size.width;
        CGFloat midY = self.contentView.bounds.size.height * 0.5;
        CGFloat left = 16.0, right = 16.0, valueWidth = 96.0;
        _slider.frame = CGRectMake(left, midY - 15.5, width - left - valueWidth - right - 8.0, 31.0);
        _valueLabel.frame = CGRectMake(width - valueWidth - right, midY - 10.0, valueWidth, 20.0);
    } @catch (__unused NSException *e) {}
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self glassSyncValue];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self glassSyncValue];
}

- (void)glassValueChanged:(UISlider *)slider {
    _valueLabel.text = [NSString stringWithFormat:@"%.2f", slider.value];
    [self glassWritePreference:slider.value];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    // Reset slider highlight when cell is selected/deselected
    _slider.highlighted = NO;
}

@end
