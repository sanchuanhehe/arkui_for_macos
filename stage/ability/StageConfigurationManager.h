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

#ifndef FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_CONFIGURATION_MANAGER_H
#define FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_CONFIGURATION_MANAGER_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// macOS has no UIUserInterfaceStyle enum; mirror its ordering so call sites that
// pass a "color mode" integer keep working: 0 = Unspecified, 1 = Light, 2 = Dark.
typedef NS_ENUM(NSInteger, MacOSUserInterfaceStyle) {
    MacOSUserInterfaceStyleUnspecified = 0,
    MacOSUserInterfaceStyleLight = 1,
    MacOSUserInterfaceStyleDark = 2,
};

@interface StageConfigurationManager : NSObject

+ (instancetype)configurationManager;

// macOS: no-op. Orientation has no AppKit equivalent; kept for source parity.
- (void)setDirection:(NSInteger)direction;

// macOS: no-op. Orientation has no AppKit equivalent; kept for source parity.
- (void)directionUpdate:(NSInteger)direction;

- (void)setColorMode:(MacOSUserInterfaceStyle)colorMode;

- (void)colorModeUpdate:(MacOSUserInterfaceStyle)colorMode;

// Resolve the current system appearance (NSApp.effectiveAppearance) into the
// mirrored Light/Dark enum. Used to seed the color mode at launch and on live
// appearance switches instead of assuming Light.
- (MacOSUserInterfaceStyle)currentColorMode;

// macOS: device-idiom (phone/tablet) has no AppKit equivalent; kept for parity.
- (void)setDeviceType:(NSInteger)deviceType;

- (void)registConfiguration;
@end

NS_ASSUME_NONNULL_END
#endif // FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_CONFIGURATION_MANAGER_H
