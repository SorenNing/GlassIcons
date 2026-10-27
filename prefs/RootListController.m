#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

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
@end

@interface GlassIconsRootListController : PSListController
@end

@implementation GlassIconsRootListController

- (NSString *)title {
    return @"GlassIcons";
}

- (id)glassReadValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return @(0);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kGlassDomain);
    id result = value ? (__bridge_transfer id)value : nil;
    return result ?: @(0);
}

- (void)glassWriteValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kGlassDomain);
    CFPreferencesAppSynchronize(kGlassDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soren.glassicons.changed"), NULL, NULL, true);
}

- (PSSpecifier *)glassGroupWithLabel:(NSString *)label footer:(NSString *)footer {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:label
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSGlassGroupCell
                                                              edit:nil];
    if (footer) [specifier setProperty:footer forKey:@"footerText"];
    return specifier;
}

- (PSSpecifier *)glassSwitchWithLabel:(NSString *)label key:(NSString *)key defaultValue:(BOOL)fallback {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:label
                                                            target:self
                                                               set:@selector(glassWriteValue:specifier:)
                                                               get:@selector(glassReadValue:)
                                                            detail:nil
                                                              cell:PSGlassSwitchCell
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:@(fallback) forKey:@"default"];
    return specifier;
}

- (PSSpecifier *)glassSliderWithLabel:(NSString *)label key:(NSString *)key defaultValue:(double)fallback {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:label
                                                            target:self
                                                               set:@selector(glassWriteValue:specifier:)
                                                               get:@selector(glassReadValue:)
                                                            detail:nil
                                                              cell:PSGlassSliderCell
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:@(fallback) forKey:@"default"];
    [specifier setProperty:@0.0 forKey:@"min"];
    [specifier setProperty:@1.0 forKey:@"max"];
    [specifier setProperty:@YES forKey:@"showValue"];
    [specifier setProperty:@YES forKey:@"isContinuous"];
    return specifier;
}

- (NSArray *)specifiers {
    NSArray *cached = [super specifiers];
    if (cached && cached.count > 0) return cached;

    NSMutableArray *list = [NSMutableArray array];
    [list addObject:[self glassGroupWithLabel:@"玻璃图标"
                                       footer:@"给桌面图标叠加玻璃高光与描边。文件夹与小预览自动跳过。"]];
    [list addObject:[self glassSwitchWithLabel:@"启用" key:@"Enabled" defaultValue:YES]];
    [list addObject:[self glassGroupWithLabel:@"外观" footer:nil]];
    [list addObject:[self glassSliderWithLabel:@"整体强度" key:@"Intensity" defaultValue:0.90]];
    [list addObject:[self glassSliderWithLabel:@"高光强度" key:@"Sheen" defaultValue:0.70]];
    [list addObject:[self glassSliderWithLabel:@"描边强度" key:@"Rim" defaultValue:0.75]];
    [list addObject:[self glassGroupWithLabel:@""
                                       footer:@"深色图标会自动减弱高光。紧急停用：创建 /var/mobile/Library/local.glassicons.disabled 后 respring。"]];
    return list;
}

@end
