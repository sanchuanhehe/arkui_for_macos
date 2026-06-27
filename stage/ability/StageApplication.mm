/*
 * Copyright (c) 2023-2026 Huawei Device Co., Ltd.
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

#import "StageApplication.h"
#import <AppKit/AppKit.h>
#include <objc/objc.h>
#import "StageAssetManager.h"
#import "StageConfigurationManager.h"

#include <string>
#include "app_main.h"
#include "stage_application_info_adapter.h"

using AppMain = OHOS::AbilityRuntime::Platform::AppMain;
static NSString* const kEtsPathRegexPattern = @"^\\./ets/([^/]+/)*[^/]+$";
static bool g_isOnBackground = false;

@implementation StageApplication

#pragma mark - publice
+ (void)configModuleWithBundleDirectory:(NSString *_Nonnull)bundleDirectory {
    LOGI("%{public}s bundleDirectory : %{public}s", __func__, [bundleDirectory UTF8String]);
    [[StageAssetManager assetManager] moduleFilesWithbundleDirectory:bundleDirectory];
    OHOS::AbilityRuntime::Platform::AppMain::GetInstance()->SetResourceFilePrefixPath();
}

+ (void)launchApplication {
    LOGI("%{public}s", __FUNCTION__);
    [self initApplication:YES];
}

+ (void)launchApplicationWithoutUI {
    LOGI("%{public}s", __FUNCTION__);
    [self initApplication:NO];
}

+ (void)initApplication:(BOOL)isLoadArkUI {
    [self setPidAndUid];
    [self setLocale];
    [self setupNotificationCenterObservers];
    [[StageAssetManager assetManager] launchAbility:isLoadArkUI];
    [[StageConfigurationManager configurationManager] registConfiguration];
    // macOS: AceWebInfoManager user-agent update and HighContrastObserver dropped in M1.
    [self startAbilityDelegator];
}

+ (void)startAbilityDelegator {
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSArray *arguments = processInfo.arguments;
    @try {
        if (arguments) {
            if ([arguments containsObject:@"test"]) {
                NSString *bundleName = [NSString new];
                NSString *moduleName = [NSString new];
                NSString *unittest = [NSString new];
                NSString *timeout = [NSString new];
                NSString *socket = [NSString new];
                for (int i = 1; i < arguments.count; i++) {
                    if ([arguments[i] isEqualToString:@"bundleName"]) {
                        if (arguments.count > i+1) {
                            bundleName = arguments[i+1];
                        }
                    } else if ([arguments[i] isEqualToString:@"moduleName"]) {
                        if (arguments.count > i+1) {
                            moduleName = arguments[i+1];
                        }
                    } else if ([arguments[i] isEqualToString:@"unittest"]) {
                        if (arguments.count > i+1) {
                            unittest = arguments[i+1];
                        }
                    } else if ([arguments[i] isEqualToString:@"timeout"]) {
                        if (arguments.count > i+1) {
                            timeout = arguments[i+1];
                        }
                    } else if ([arguments[i] isEqualToString:@"socket"]) {
                        if (arguments.count > i+1) {
                            socket = arguments[i+1];
                        }
                    }
                }
                std::string bundleNameString = [bundleName UTF8String];
                std::string moduleNameString = [moduleName UTF8String];
                std::string unittestString = [unittest UTF8String];
                std::string timeoutString = [timeout UTF8String];
                std::string socketString = [socket UTF8String];
                AppMain::GetInstance()->PrepareAbilityDelegator(
                    bundleNameString, moduleNameString, unittestString, timeoutString, socketString);
            } else {
                LOGI("%{public}s, No need to start creating abilityDelegate", __FUNCTION__);
            }
        }
    } @catch (NSException *exception) {
        LOGE("NSException name: %{public}s", [exception.name UTF8String]);
    } @finally {
        LOGE("%{public}s, failed .arraySize=%{public}lu", __FUNCTION__, (unsigned long)arguments.count);
    }
}

+ (void)setupNotificationCenterObservers {
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];

    // UIApplication*Notification -> NSApplication hide/unhide as the macOS analogue.
    [center addObserver:self
               selector:@selector(DispatchApplicationOnBackground:)
                   name:NSApplicationDidHideNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(DispatchApplicationOnForeground:)
                   name:NSApplicationWillUnhideNotification
                 object:nil];
    // macOS: UIAccessibilityDarkerSystemColorsStatusDidChangeNotification (high contrast) dropped.
}

+ (void)DispatchApplicationOnForeground:(NSNotification *)notification {
    AppMain::GetInstance()->NotifyApplicationForeground();
    [self callCurrentAbilityOnForeground];
}

+ (void)DispatchApplicationOnBackground:(NSNotification *)notification {
    AppMain::GetInstance()->NotifyApplicationBackground();
    [self callCurrentAbilityOnBackground];
}

+ (void)setPidAndUid {
    int pid = [[NSProcessInfo processInfo] processIdentifier];
    int32_t uid = 0;
    LOGI("%{public}s pid : %{public}d", __func__, pid);
    OHOS::AbilityRuntime::Platform::AppMain::GetInstance()->SetPidAndUid(pid, uid);
}

+ (void)setLocale {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *customLanguages = [defaults objectForKey:@"ArkuiXApplePreferredLanguages"];
    NSString *currentLanguage;
    if (customLanguages && customLanguages.length != 0) {
        currentLanguage = customLanguages;
    } else {
        currentLanguage = [[NSLocale preferredLanguages] objectAtIndex:0];
    }

    NSArray *array = [currentLanguage componentsSeparatedByString:@"-"];
    std::string language = "";
    std::string country = "";
    std::string script = "";

    if ([currentLanguage hasPrefix:@"zh-Hans"]) {
        language = "zh";
        country = "CN";
        script = "Hans";
    } else if ([currentLanguage hasPrefix:@"zh-HK"] || [currentLanguage hasPrefix:@"zh-Hant-HK"]) {
        language = "zh";
        country = "HK";
        script = "Hant";
    } else if ([currentLanguage hasPrefix:@"zh-TW"] || [currentLanguage hasPrefix:@"zh-Hant"]) {
        language = "zh";
        country = "TW";
        script = "Hant";
    } else if (array.count == 1) {
        language = [array[0] UTF8String];
    } else if (array.count == 2) {
        language = [array[0] UTF8String];
        country = [array[1] UTF8String];
    } else if (array.count == 3) {
        language = [array[0] UTF8String];
        country = [array[2] UTF8String];
        script = [array[1] UTF8String];
    }
    LOGI("%{public}s, language : %{public}s, country : %{public}s script : %{public}s",
        __FUNCTION__, language.c_str(), country.c_str(), script.c_str());
    OHOS::AbilityRuntime::Platform::StageApplicationInfoAdapter::GetInstance()->SetLocale(language, country, script);
}

+ (void)setLocaleWithLanguage:(NSString *)language country:(NSString *)country script:(NSString *)script {
    std::string languageString = "";
    std::string countryString = "";
    std::string scriptString = "";
    if (language.length) {
        languageString = [language UTF8String];
    }
    if (country.length) {
        countryString = [country UTF8String];
    }
    if (script.length) {
        scriptString = [script UTF8String];
    }
    OHOS::AbilityRuntime::Platform::StageApplicationInfoAdapter::GetInstance()->SetLocale(languageString,
        countryString, scriptString);
}

+ (void)callCurrentAbilityOnForeground {
    if (!g_isOnBackground) {
        return;
    }
    g_isOnBackground = false;
    StageViewController *topVC = [self getApplicationTopViewController];
    if (![topVC isKindOfClass:[StageViewController class]]) {
        LOGI("callCurrentAbilityOnForeground is Not StageVC");
        return;
    }
    NSString *instanceName = topVC.instanceName;
    if (instanceName.length) {
        std::string cppInstanceName = [instanceName UTF8String];
        AppMain::GetInstance()->DispatchOnForeground(cppInstanceName);
    }
    LOGI("%{public}s, instanceName : %{public}s", __FUNCTION__, [instanceName UTF8String]);
}

+ (void)callCurrentAbilityOnBackground {
    if (g_isOnBackground) {
        return;
    }
    g_isOnBackground = true;
    StageViewController *topVC = [self getApplicationTopViewController];
    if (![topVC isKindOfClass:[StageViewController class]]) {
        LOGI("callCurrentAbilityOnBackground is Not StageVC");
        return;
    }
    NSString *instanceName = topVC.instanceName;
    if (instanceName.length) {
        std::string cppInstanceName = [instanceName UTF8String];
        AppMain::GetInstance()->DispatchOnBackground(cppInstanceName);
    }
    LOGI("%{public}s, instanceName : %{public}s", __FUNCTION__, [instanceName UTF8String]);
}

+ (BOOL)handleSingleton:(NSString *)bundleName moduleName:(NSString *)moduleName abilityName:(NSString *)abilityName {
    bool isSingle = AppMain::GetInstance()->IsSingleton([moduleName UTF8String], [abilityName UTF8String]);
    if (!isSingle) {
        return NO;
    }
    NSString *singleName = [NSString stringWithFormat:@"%@:%@:%@", bundleName, moduleName, abilityName];
    LOGI("%{public}s, singleName is %{public}s", __func__, [singleName UTF8String]);
    StageViewController *topVC = [self getApplicationTopViewController];
    if (![topVC isKindOfClass:[StageViewController class]]) {
        LOGI("handleSingleton is Not StageVC");
        return NO;
    }
    if ([topVC.instanceName containsString:singleName]) {
        std::string instanceName = [topVC.instanceName UTF8String];
        AppMain::GetInstance()->DispatchOnNewWant(instanceName);
        return YES;
    }
    // macOS M1: single-window only; iOS navigation-controller stack traversal dropped.
    return NO;
}

+ (void)releaseViewControllers {
    StageViewController *topVC = [StageApplication getApplicationTopViewController];
    if (![topVC isKindOfClass:[StageViewController class]]) {
        LOGI("releaseViewControllers is Not StageVC");
        return;
    }
    // macOS M1: single-window only; destroy the top StageViewController instance.
    NSString *instanceName = topVC.instanceName;
    if (instanceName.length) {
        LOGI("%{public}s, instanceName : %{public}s", __FUNCTION__, [instanceName UTF8String]);
        std::string cppInstanceName = [instanceName UTF8String];
        AppMain::GetInstance()->DispatchOnDestroy(cppInstanceName);
    }
}

+ (StageViewController *)getApplicationTopViewController {
    // UIApplication.delegate.window.rootViewController -> NSApplication key/main window
    // contentViewController on macOS (single-window M1).
    NSWindow* window = [NSApplication sharedApplication].keyWindow;
    if (!window) {
        window = [NSApplication sharedApplication].mainWindow;
    }
    if (!window) {
        NSArray<NSWindow*>* windows = [NSApplication sharedApplication].windows;
        window = windows.firstObject;
    }
    NSViewController* viewController = window.contentViewController;
    return (StageViewController *)[StageApplication findTopViewController:viewController];
}

+ (NSViewController *)findTopViewController:(NSViewController*)topViewController {
    // macOS M1: navigation / tab / presented controller traversal dropped. Walk the
    // presented-controller chain only (no UINavigationController/UITabBarController).
    while (topViewController.presentedViewControllers.count > 0) {
        NSViewController* presented = topViewController.presentedViewControllers.lastObject;
        if (!presented) {
            break;
        }
        topViewController = presented;
    }
    return topViewController;
}

- (NSString *)getTopAbility {
    StageViewController *topViewController = [StageApplication getApplicationTopViewController];
    if (![topViewController isKindOfClass:[StageViewController class]]) {
        return @"current views is null";
    }
    return topViewController.instanceName;
}

- (void)doAbilityForeground:(NSString *)fullname {
    // macOS: no-op. Navigation-controller view-controller reordering dropped in M1.
}

- (void)doAbilityBackground:(NSString *)fullname {
    // macOS: no-op. Navigation-controller view-controller reordering dropped in M1.
}

- (void)print:(NSString *)msg {
    if (msg.length >= 1000) {
        LOGI("print: The total length of the message exceed 1000 characters.");
    } else {
        LOGI("print: %{public}s", [msg UTF8String]);
    }
}

- (void)printSync:(NSString *)msg {
    if (msg.length >= 1000) {
        LOGI("printSync: The total length of the message exceed 1000 characters.");
    } else {
        LOGI("printSync: %{public}s", [msg UTF8String]);
    }
}

- (int)finishTest {
    LOGI("TestFinished-ResultMsg: your test finished!!!");
    int error = 0;
    @try {
       exit(0);
    } @catch (NSException *exception) {
        LOGE("TestFinished-ResultMsg exceptionName=%{public}s", [exception.name UTF8String]);
        error = 1;
    } @finally {
        return error;
    }
}

+ (void)preloadEtsModule:(NSString *)moduleName country:(NSString *)abilityName
{
    if (moduleName == nil || moduleName.length == 0) {
        LOGE("moduleName is null");
        return;
    }
    if (abilityName == nil || abilityName.length == 0) {
        LOGE("abilityName is null");
        return;
    }
    AppMain::GetInstance()->PreloadModule([moduleName UTF8String], [abilityName UTF8String]);
}

+ (void)loadModule:(NSString *)moduleName entryFile:(NSString *)entryFile {
    if (moduleName == nil || moduleName.length == 0) {
        LOGE("load module error: moduleName is null.");
        return;
    }
    if (entryFile == nil || entryFile.length == 0) {
        LOGE("load module error: path is null.");
        return;
    }
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression
                                    regularExpressionWithPattern:kEtsPathRegexPattern options:0 error:&error];
    if (error) {
        LOGE("load module error: %{public}s", [error.localizedDescription UTF8String]);
        return;
    }
    NSUInteger matches = [regex numberOfMatchesInString:entryFile options:0 range:NSMakeRange(0, entryFile.length)];
    if (matches == 0) {
        LOGE("load module error: path is invalid.");
        return;
    }
    AppMain::GetInstance()->LoadModule([moduleName UTF8String], [entryFile UTF8String]);
}

@end
