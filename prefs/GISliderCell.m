#import "GISliderCell.h"

@interface PSTableCell ()
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@implementation GISliderCell {
    UILabel *_valueLabel;
    BOOL _wiredSlider;
}

- (instancetype)initWithStyle:(long)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryType = UITableViewCellAccessoryNone;
        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        _valueLabel.textColor = UIColor.labelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];
    }
    return self;
}

- (UISlider *)glassSlider {
    // Search the whole view hierarchy (PSSliderTableCell may nest the slider).
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self.contentView];
    if (self.superview) [queue addObject:self];
    while (queue.count) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        for (UIView *child in node.subviews) {
            if ([child isKindOfClass:UISlider.class]) return (UISlider *)child;
            [queue addObject:child];
        }
    }
    return nil;
}

- (void)glassWireSlider {
    if (_wiredSlider) return;
    UISlider *slider = [self glassSlider];
    if (!slider) return;
    [slider addTarget:self action:@selector(glassValueChanged:) forControlEvents:UIControlEventValueChanged];
    _wiredSlider = YES;
}

- (void)glassUpdateValue {
    if (!self.specifier) return;
    UISlider *slider = [self glassSlider];
    if (!slider) return;

    double minimum = [[self.specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[self.specifier propertyForKey:@"max"] doubleValue];
    if (maximum <= minimum) maximum = minimum + 1.0;

    id value = [self readPreferenceValue:self.specifier];
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : minimum;
    number = fmax(minimum, fmin(maximum, number));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    slider.minimumValue = (float)minimum;
    slider.maximumValue = (float)maximum;
    slider.value = (float)number;
    [CATransaction commit];

    _valueLabel.text = [NSString stringWithFormat:@"%.2f", number];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // PSSliderTableCell places its own UISlider; find it anywhere in the hierarchy.
    UISlider *slider = [self glassSlider];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat valueWidth = 96.0;
    CGFloat midY = self.contentView.bounds.size.height * 0.5;

    if (slider) {
        CGRect frame = slider.frame;
        frame.origin.x = 16.0;
        frame.size.width = width - valueWidth - 56.0;
        frame.origin.y = midY - frame.size.height * 0.5;
        slider.frame = frame;
        [self glassWireSlider];
    }
    _valueLabel.frame = CGRectMake(width - valueWidth - 16.0, midY - 10.0, valueWidth, 20.0);
    [self glassUpdateValue];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _valueLabel.text = nil;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self glassUpdateValue];
}

- (void)glassValueChanged:(UISlider *)slider {
    _valueLabel.text = [NSString stringWithFormat:@"%.2f", slider.value];
    [self setPreferenceValue:@((double)slider.value) specifier:self.specifier];
}

@end
