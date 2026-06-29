/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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

#import "AcePlatformPluginMac.h"

#import "adapter/macos/capability/web/AceWebResourcePlugin.h"

#include "adapter/macos/entrance/ace_resource_register.h"
#include "adapter/macos/entrance/ace_platform_plugin.h"
#include "core/common/container_scope.h"
#include "base/log/log.h"

// Ported from adapter/ios/entrance/AcePlatformPlugin.mm, trimmed to the Web carrier. Creates the
// AceResourceRegisterOC, registers it into the C++ AcePlatformPlugin (so the web pattern's
// GetResRegister(instanceId) succeeds), then creates + registers AceWebResourcePlugin so a
// CreateResource("web", ...) from WebDelegateCross instantiates a WKWebView.
@interface AcePlatformPluginMac () <IAceOnCallEvent>
{
    AceResourceRegisterOC* _resRegister;
    AceWebResourcePlugin* _webResourcePlugin;
}
@property (nonatomic, assign) int32_t instanceId;
@end

@implementation AcePlatformPluginMac

- (instancetype)initPlatformPlugin:(id)target
    instanceId:(int32_t)instanceId moduleName:(NSString *_Nonnull)moduleName
{
    self = [super init];
    if (self) {
        if (target) {
            self.instanceId = instanceId;
            _resRegister = [[AceResourceRegisterOC alloc] initWithParent:self];
            auto aceResRegister =
                OHOS::Ace::Referenced::MakeRefPtr<OHOS::Ace::Platform::AceResourceRegister>(_resRegister);
            OHOS::Ace::Platform::AcePlatformPlugin::InitResRegister(instanceId, aceResRegister);

            if (moduleName && moduleName.length != 0) {
                _webResourcePlugin = [AceWebResourcePlugin createRegister:target abilityInstanceId:instanceId];
                [self addResourcePlugin:_webResourcePlugin];
            }
        }
    }
    return self;
}

- (void)addResourcePlugin:(AceResourcePlugin *)plugin
{
    if (plugin && _resRegister) {
        [_resRegister registerPlugin:plugin];
    }
}

- (void)notifyLifecycleChanged:(BOOL)isBackground
{
    if (_resRegister) {
        [_resRegister notifyLifecycleChanged:isBackground];
    }
}

- (void)platformRelease
{
    if (_webResourcePlugin) {
        [_webResourcePlugin releaseObject];
        _webResourcePlugin = nil;
    }
    if (_resRegister) {
        [_resRegister releaseObject];
        _resRegister = nil;
    }
}

#pragma mark IAceOnCallEvent
- (void)onEvent:(NSString *)eventId param:(NSString *)param
{
    auto resRegister = OHOS::Ace::Platform::AcePlatformPlugin::GetResRegister(self.instanceId);
    if (resRegister == nullptr) {
        return;
    }
    OHOS::Ace::ContainerScope scope(self.instanceId);
    resRegister->OnEvent([eventId UTF8String], [param UTF8String]);
}

@end
