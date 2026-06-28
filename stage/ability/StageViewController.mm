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

#import "StageViewController.h"

#import "InstanceIdGenerator.h"
#import "StageApplication.h"
#import "StageAssetManager.h"
#import "StageConfigurationManager.h"
#import "StageContainerView.h"
#import "WindowView.h"
#include "app_main.h"
#include "window_view_adapter.h"
#include "dump_helper.h"
#include "version_printer.h"

using AppMain = OHOS::AbilityRuntime::Platform::AppMain;
using WindowViwAdapter = OHOS::AbilityRuntime::Platform::WindowViewAdapter;
int32_t CURRENT_STAGE_INSTANCE_Id = 0;

// macOS M1: dropped iOS pickers (UIDocumentPicker/PHPicker), navigation controller,
// orientation, status bar, safe-area, traits, UIPress key handling, ArkUIX plugin
// registry, BridgePluginManager, AcePlatformPlugin, StageSecureContainerView.
@interface StageViewController () <WindowViewDelegate> {
    int32_t _instanceId;
    std::string _cInstanceName;
    WindowView *_windowView;
    StageContainerView* _stageContainerView;
    BOOL _needOnForeground;
}

@property(nonatomic, strong, readwrite) NSString* instanceName;
@property(nonatomic, copy) NSString* bundleName;
@property(nonatomic, copy) NSString* moduleName;
@property(nonatomic, copy) NSString* abilityName;
@end

@implementation StageViewController

#pragma mark - life cycle
- (instancetype)initWithInstanceName:(NSString *_Nonnull)instanceName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _instanceId = InstanceIdGenerator.getAndIncrement;
        self.instanceName = [NSString stringWithFormat:@"%@:%d", instanceName, _instanceId];
        LOGI("StageVC init, instanceName is : %{public}s", [self.instanceName UTF8String]);
        NSArray * nameArray = [self.instanceName componentsSeparatedByString:@":"];
        if (nameArray.count >= 3) {
            self.bundleName = nameArray[0];
            self.moduleName = nameArray[1];
            self.abilityName = nameArray[2];
            NSString *moduleNamePath = [NSString stringWithFormat:@"%@.%@",self.bundleName, self.moduleName];
            BOOL isExistsAtPath = [self ExistDir:moduleNamePath];
            if (isExistsAtPath && nameArray.count >= 4) {
                self.moduleName = moduleNamePath;
                self.instanceName = [NSString stringWithFormat:@"%@:%@:%@:%@",
                        nameArray[0], self.moduleName, nameArray[2], nameArray[3]];
            }
        }
        _cInstanceName = [self getCPPString:self.instanceName];
        self.homeIndicatorHidden = NO;
        OHOS::Ace::Platform::VersionPrinter::printVersion();
    }
    return self;
}

- (BOOL)ExistDir:(NSString *)filePath
{
    NSArray *pkgJsonFileList = [[StageAssetManager assetManager] getAssetAllFilePathList];
    for (NSString *pkgJsonPath in pkgJsonFileList) {
        if ([pkgJsonPath containsString:[NSString stringWithFormat:@"/%@", filePath]]) {
            return YES;
        }
    }
    return NO;
}

- (void)initColorMode {
    // Seed from the actual system appearance instead of hard-coding Light, so a
    // launch under Dark mode renders dark. Live switches are handled by
    // WindowView's -viewDidChangeEffectiveAppearance.
    StageConfigurationManager* mgr = [StageConfigurationManager configurationManager];
    [mgr colorModeUpdate:[mgr currentColorMode]];
}

- (void)initWindowView {
    _windowView = [[WindowView alloc] init];
    _windowView.instanceId = _instanceId;
    [_windowView startBaseDisplayLink];
    _windowView.frame = self.view.bounds;
    _windowView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    WindowViwAdapter::GetInstance()->AddWindowView(_cInstanceName, (__bridge void*)_windowView);
    [_stageContainerView addSubview: _windowView];
    [_stageContainerView setMainWindow:_windowView];
}

// NSViewController: the root view must be supplied via loadView (no nib in M1).
- (void)loadView {
    // Phase 0 path X (M1 window): give the root view a real initial frame so the
    // hosting NSWindow does not collapse to a title-bar sliver. The window resizes
    // this view to its content rect, and the WindowView autoresizes to fill it.
    // Keep this in sync with MacAppDelegate's window content rect (landscape desktop
    // default); a mismatched VC view size drives the window via its content size.
    _stageContainerView = [[StageContainerView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)];
    _stageContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = _stageContainerView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _stageContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _stageContainerView.notifyDelegate = self;
    _stageContainerView.wantsLayer = YES;
    _stageContainerView.layer.backgroundColor = NSColor.whiteColor.CGColor;
    LOGI("StageVC viewDidLoad call.instanceName: %{public}s", [self.instanceName UTF8String]);
    [self initColorMode];
    [self initWindowView];
    [_windowView createSurfaceNode];

    std::string paramsString = [self getCPPString:self.params.length ? self.params : @""];
    AppMain::GetInstance()->DispatchOnCreate(_cInstanceName, paramsString);
    AppMain::GetInstance()->DispatchOnForeground(_cInstanceName);
}

- (void)saveDumpFile:(NSArray<NSString *> *)dumpParams {
    LOGI("saveDumpFile enter");

    std::vector<std::string> dumpParamsVector;
    for (NSString *dumpParam in dumpParams) {
        dumpParamsVector.push_back([dumpParam UTF8String]);
    }

    OHOS::Ace::Platform::DumpHelper::Dump(_instanceId, dumpParamsVector);
    LOGI("saveDumpFile finished");
}

- (BOOL)supportWindowPrivacyMode {
    return false;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    LOGI("StageVC viewDidAppear call.instanceName: %{public}s", [self.instanceName UTF8String]);
}

- (void)viewWillAppear {
    [super viewWillAppear];

    LOGI("StageVC viewWillAppear call.instanceName: %{public}s", [self.instanceName UTF8String]);
    if (_needOnForeground) {
        AppMain::GetInstance()->DispatchOnForeground(_cInstanceName);
    }
    _needOnForeground = true;
    [_stageContainerView notifyForeground];
    [_stageContainerView notifyActiveChanged:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];

    LOGI("StageVC viewDidDisappear call.instanceName: %{public}s", [self.instanceName UTF8String]);
    AppMain::GetInstance()->DispatchOnBackground(_cInstanceName);
    [_stageContainerView notifyBackground];
    [_stageContainerView notifyActiveChanged:NO];
}

- (void)dealloc {
    LOGI("StageVC dealloc instanceName: %{public}s", [self.instanceName UTF8String]);
    [_windowView notifySurfaceDestroyed];
    [_windowView notifyWindowDestroyed];
    _windowView = nil;
    _stageContainerView = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    AppMain::GetInstance()->DispatchOnDestroy(_cInstanceName);
}

- (int32_t)getInstanceId {
    return _instanceId;
}

#pragma mark - private method
- (std::string)getCPPString:(NSString *)string {
    return [string UTF8String];
}

- (BOOL)isTopController {
    StageViewController *controller = [StageApplication getApplicationTopViewController];
    if ([controller respondsToSelector:@selector(instanceName)]) {
        NSString *topInstanceName = controller.instanceName;
        if ([self.instanceName isEqualToString:topInstanceName]) {
            return true;
        }
    }
    return false;
}

- (BOOL)processBackPress {
    return [_windowView processBackPressed];
}

#pragma mark - WindowViewDelegate
- (void)notifyApplicationWillEnterForeground {
    // macOS: no-op. Platform plugin lifecycle dropped in M1.
}

- (void)notifyApplicationDidEnterBackground {
    // macOS: no-op. Platform plugin lifecycle dropped in M1.
}

- (void)notifyApplicationWillTerminateNotification {
    // macOS: no-op. BridgePluginManager dropped in M1.
}

- (NSView *)getWindowView {
    return _windowView;
}
@end
