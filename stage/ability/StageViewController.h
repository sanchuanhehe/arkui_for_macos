/*
 * Copyright (c) 2023-2024 Huawei Device Co., Ltd.
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

#ifndef FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_STAGEVIEWCONTROLLER_H
#define FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_STAGEVIEWCONTROLLER_H

#import <AppKit/AppKit.h>

@interface StageViewController : NSViewController

@property (nonatomic, readonly) NSString *instanceName;
// macOS: status bar / home indicator have no AppKit equivalent; kept for parity, no-op.
@property (nonatomic, assign) BOOL statusBarHidden;
@property (nonatomic, assign) BOOL homeIndicatorHidden;
@property (nonatomic, strong) NSString *params;
@property (nonatomic, assign) BOOL privacyMode;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (NSView *)getWindowView;

/**
 * Initializes this StageViewController with the specified instance name.
 *
 *  instanceName(bundleName:moduleName:abilityName)
 *  This is used for pure stage application. It will combine the instanceName as the
 *  abilityDirectory.
 *
 * @param instanceName instance name.
 * @since 10
 */
- (instancetype)initWithInstanceName:(NSString *_Nonnull)instanceName;

/**
 * Get the Id of StageViewController.
 * @return The InstanceId.
 * @since 10
 */
- (int32_t)getInstanceId;

/**
 * processBackPress.
 * @return if uicontent handle return true ,otherwise return false.
 * @since 11
 */
- (BOOL)processBackPress;

/**
 * config privacy mode, if your ability need support privacy mode, please return YES, default is NO.
 * @since 20
 */
- (BOOL)supportWindowPrivacyMode;

/**
 * save dump file.
 * @param dumpParams dump params.
 * @return void
 */
- (void)saveDumpFile:(NSArray<NSString *> *)dumpParams;
@end

#endif // FOUNDATION_ACE_ADAPTER_MACOS_STAGE_ABILITY_STAGEVIEWCONTROLLER_H
