/*
 * Copyright (c) 2023 Huawei Device Co., Ltd.
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

#import "AceWebResourcePlugin.h"
#import "AceWeb.h"
#import "StageViewController.h"
#include "base/log/log.h"

#define URL_SRC @"src"
#define PAGE_URL @"pageUrl"
#define INCOGNITO_MOD @"incognitoMode"
#define INCOGNITO_FLAG @"1"

@interface AceWebResourcePlugin()
@property (nonatomic, weak) NSViewController *target;
@property (nonatomic, assign) int32_t instanceId;
@end

@implementation AceWebResourcePlugin
static NSMutableDictionary<NSString*, AceWeb*> *objectMap;
+ (AceWebResourcePlugin *)createRegister:(NSViewController *)target abilityInstanceId:(int32_t)abilityInstanceId
{
    return [[AceWebResourcePlugin alloc] initWithTarget:target abilityInstanceId:abilityInstanceId];
}

- (instancetype)initWithTarget:(NSViewController *)target abilityInstanceId:(int32_t)abilityInstanceId{
    self = [super init:@"web" version:1];
    if (self) {
        objectMap = [[NSMutableDictionary alloc] init];
        self.target = target;
        self.instanceId = abilityInstanceId;
    }
    return self;
}

- (void)addResource:(int64_t)incId web:(AceWeb *)web{
    if (!objectMap) {
        LOGE("AceWebResourcePlugin addResource objectMap is empty");
        objectMap = [[NSMutableDictionary alloc] init];
    }
    [objectMap setObject:web forKey:[NSString stringWithFormat:@"%lld", incId]];
    NSDictionary *safeMethodMap = [[web getSyncCallMethod] copy];
    if (!safeMethodMap) {
        return;
    }
    [self registerSyncCallMethod:safeMethodMap];
}

- (int64_t)create:(NSDictionary <NSString *, NSString *> *)param{
    int64_t incId = [self getAtomicId];
    IAceOnResourceEvent callback = [self getEventCallback];
    bool incognitoMode =[[param valueForKey:INCOGNITO_MOD] isEqualToString:INCOGNITO_FLAG] ? true : false;
    AceWeb *aceWeb;
    if (incognitoMode) {
      aceWeb = [[AceWeb alloc] init:incId incognitoMode:incognitoMode target:(NSViewController*)self.target onEvent:callback abilityInstanceId:self.instanceId];
    } else {
      aceWeb = [[AceWeb alloc] init:incId target:(NSViewController*)self.target onEvent:callback abilityInstanceId:self.instanceId];
    }
    if (@available(macOS 13.3, *)) {
        [aceWeb getWeb].inspectable = [AceWeb getWebDebuggingAccess];
    }
    [aceWeb loadUrl:[param valueForKey:URL_SRC] header:[NSMutableDictionary dictionary]];
    StageViewController* controller = (StageViewController*)self.target;
    NSView *windowView = [controller getWindowView];
    // macOS: the GL WindowView is opaque, so the WKWebView must overlay ABOVE it (iOS inserts
    // below a transparent UIView). NSView uses addSubview:positioned:relativeTo: (no
    // insertSubview:belowSubview:). The web component's rect is applied via updateWebLayout.
    WKWebView* web = aceWeb.getWeb;
    web.translatesAutoresizingMaskIntoConstraints = YES;
    [windowView.superview addSubview:web positioned:NSWindowAbove relativeTo:windowView];
    [self addResource:incId web:aceWeb];
    return incId;
}

+ (NSDictionary<NSString*, AceWeb*>*) getObjectMap{
    return objectMap ;
}

- (id)getObject:(NSString *)incId{
    return [objectMap objectForKey:incId];
}

- (BOOL)release:(NSString *)incId{
    LOGI("AceWebResourcePlugin %{public}s release inceId: %{public}s", __func__, incId.UTF8String);
    AceWeb *web = [objectMap objectForKey:incId];
    if (web) {
        [self unregisterSyncCallMethod:[web getSyncCallMethod]];
        [web releaseObject];
        [objectMap removeObjectForKey:incId];
        web = nil;
        return YES;
    }
    return NO;
}

- (void)releaseObject{
    LOGI("AceWebResourcePlugin %{public}s", __func__);
    if (objectMap) {
        [objectMap enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, AceWeb * _Nonnull web, BOOL * _Nonnull stop) {
            if (web) {
                @try {
                    [web releaseObject];
                    web = nil;
                } @catch (NSException *exception) {
                    LOGE("AceWebResourcePlugin releaseObject releaseObject fail");
                }
            } else {
                LOGE("AceWebResourcePlugin releaseObject fail web is null");
            }
        }];
        [objectMap removeAllObjects];
        objectMap = nil;
    }
    self.target = nil;
}

- (void)dealloc
{
    LOGI("AceWebResourcePlugin dealloc instanceId=%{public}lld", static_cast<long long>(self.instanceId));
}
@end