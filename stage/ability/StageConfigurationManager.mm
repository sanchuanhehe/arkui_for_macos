/*
 * Copyright (c) 2023-2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <AppKit/AppKit.h>
#import "StageConfigurationManager.h"

#include <string>
#include <app_main.h>

#define APPLICATION_DIRECTION @"ohos.application.direction"
#define COLOR_MODE_LIGHT @"light"
#define COLOR_MODE_DARK @"dark"
#define DIRECTION_VERTICAL @"vertical"
#define DIRECTION_HORIZONTAL @"horizontal"
#define EMPTY_JSON ""
#define UNKNOWN @""
#define SYSTEM_COLORMODE @"ohos.system.colorMode"
#define APPLICATION_DENSITY @"ohos.application.densitydpi"
#define DEVICE_TYPE @"const.build.characteristics"
#define DEVICE_TYPE_PHONE @"Phone"
#define DEVICE_TYPE_TABLET @"Tablet"
#define SYSTEM_LANGUAGE @"ohos.system.language"
#define SYSTEM_FONT_SIZE_SCALE @"system.font.size.scale"
using AppMain = OHOS::AbilityRuntime::Platform::AppMain;
@interface StageConfigurationManager ()

@property (nonatomic, strong) NSMutableDictionary *configuration;

@end

@implementation StageConfigurationManager

+ (instancetype)configurationManager {
    static StageConfigurationManager *_configurationManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LOGI("StageConfigurationManager share instance");
        _configurationManager = [[StageConfigurationManager alloc] init];
    });
    return _configurationManager;
}

- (void)registConfiguration {
    LOGI("initConfiguration called");
    // macOS: orientation/device-idiom dropped in M1; report a desktop color mode + language.
    [self setColorMode:[self currentColorMode]];
    [self setLanguage:[self getCurrentLanguage]];
    [self setfontSizeScale:1.0];
    std::string json = [self getJsonString:self.configuration];

    if (json.empty()) {
        AppMain::GetInstance()->InitConfiguration(EMPTY_JSON);
    }
    AppMain::GetInstance()->InitConfiguration(json);
    // macOS: CapabilityRegistry::Register() not part of the macOS M1 entrance; dropped.
}

- (void)directionUpdate:(NSInteger)direction {
    // macOS: no-op. Orientation has no AppKit equivalent.
}

- (void)colorModeUpdate:(MacOSUserInterfaceStyle)colorMode {
    LOGI("colorModeUpdate called");
    [self setColorMode:colorMode];
    std::string json = [self getJsonString:self.configuration];
    if (json.empty()) {
        AppMain::GetInstance()->OnConfigurationUpdate(EMPTY_JSON);
    }
    AppMain::GetInstance()->OnConfigurationUpdate(json);
}

- (void)fontSizeScaleUpdate:(CGFloat)fontSizeScale {
    LOGI("fontSizeScaleUpdate called");
    [self setfontSizeScale:fontSizeScale];
    std::string json = [self getJsonString:self.configuration];
    if (json.empty()) {
        AppMain::GetInstance()->OnConfigurationUpdate(EMPTY_JSON);
    }
    else {
        AppMain::GetInstance()->OnConfigurationUpdate(json);
    }
}

- (void)setDirection:(NSInteger)direction {
    // macOS: no-op. Orientation has no AppKit equivalent.
}

- (void)setLanguage:(NSString*)language {
    [self.configuration setObject:language forKey:SYSTEM_LANGUAGE];
}

- (void)setfontSizeScale:(CGFloat)fontScale {
    [self.configuration setObject:[NSString stringWithFormat:@"%.2f", fontScale] forKey:SYSTEM_FONT_SIZE_SCALE];
}

- (NSString*)getCurrentLanguage {
    NSString* preferredLanguage = [[NSLocale preferredLanguages] firstObject];
    return preferredLanguage;
}

// Resolve the effective system appearance (NSAppearance) into the mirrored enum.
- (MacOSUserInterfaceStyle)currentColorMode {
    if (@available(macOS 10.14, *)) {
        NSAppearance *appearance = [NSApp effectiveAppearance];
        NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
        if ([name isEqualToString:NSAppearanceNameDarkAqua]) {
            return MacOSUserInterfaceStyleDark;
        }
        return MacOSUserInterfaceStyleLight;
    }
    return MacOSUserInterfaceStyleLight;
}

- (void)setColorMode:(MacOSUserInterfaceStyle)colorMode {
    switch (colorMode) {
        case MacOSUserInterfaceStyleLight: {
            [self.configuration setObject:COLOR_MODE_LIGHT forKey:SYSTEM_COLORMODE];
        }
        break;
        case MacOSUserInterfaceStyleDark: {
            [self.configuration setObject:COLOR_MODE_DARK forKey:SYSTEM_COLORMODE];
        }
        break;
        default: {
            [self.configuration setObject:UNKNOWN forKey:APPLICATION_DIRECTION];
        }
        break;
    }
}

- (void)setDeviceType:(NSInteger)deviceType {
    // macOS: no-op. Device idiom (phone/tablet) has no AppKit equivalent.
}

- (std::string)getJsonString:(id)object {
    if (!object) {
        return EMPTY_JSON;
    }
    NSError *parseError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object
                                                       options:kNilOptions
                                                         error:&parseError];
    if (parseError) {
        LOGE("parsing failed, code: %{public}ld", (long)parseError.code);
        return EMPTY_JSON;
    }
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [jsonString UTF8String];
}

#pragma mark - lazy load
- (NSMutableDictionary *)configuration {
    if (!_configuration) {
        _configuration = [[NSMutableDictionary alloc] init];
    }
    return _configuration;
}
@end
