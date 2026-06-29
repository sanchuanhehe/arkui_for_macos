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
#import "adapter/macos/capability/surface/AceSurfacePlugin.h"
#import "adapter/macos/capability/surface/IAceSurface.h"
#import "adapter/macos/capability/video/AceVideoResourcePlugin.h"
#import "adapter/macos/capability/texture/AceTextureResourcePlugin.h"
#import "adapter/macos/capability/texture/AceTextureDelegate.h"

#include "adapter/macos/entrance/ace_resource_register.h"
#include "adapter/macos/entrance/ace_platform_plugin.h"
#include "core/common/container_scope.h"
#include "base/log/log.h"

// Ported from adapter/ios/entrance/AcePlatformPlugin.mm, trimmed to the Web carrier. Creates the
// AceResourceRegisterOC, registers it into the C++ AcePlatformPlugin (so the web pattern's
// GetResRegister(instanceId) succeeds), then creates + registers AceWebResourcePlugin so a
// CreateResource("web", ...) from WebDelegateCross instantiates a WKWebView.
@interface AcePlatformPluginMac () <IAceOnCallEvent, IAceSurface, AceTextureDelegate>
{
    AceResourceRegisterOC* _resRegister;
    AceWebResourcePlugin* _webResourcePlugin;
    AceSurfacePlugin* _surfacePlugin;
    AceVideoResourcePlugin* _videoResourcePlugin;
    AceTextureResourcePlugin* _textureResourcePlugin;
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

                // M5 surface carrier (shared by Video/XComponent): self is the IAceSurface
                // delegate returning the CALayer pointer as the native window.
                _surfacePlugin = [AceSurfacePlugin createRegister:target abilityInstanceId:instanceId delegate:self];
                [self addResourcePlugin:_surfacePlugin];

                // M5 Video carrier: AVPlayer-backed video.
                _videoResourcePlugin = [AceVideoResourcePlugin createRegister:moduleName abilityInstanceId:instanceId];
                [self addResourcePlugin:_videoResourcePlugin];

                // M5 Video carrier (texture path): the AceTexture holds the AVPlayerItemVideoOutput;
                // self is the AceTextureDelegate that registers its videoOutput into the C++
                // AcePlatformPlugin native-window map (read back by AceViewSG::GetNativeWindowById ->
                // Rosen RSSurfaceTextureMac). This is what lets video frames composite as a GL texture
                // in the render tree (ArkUI controls on top) instead of a native AVPlayerLayer overlay.
                _textureResourcePlugin =
                    [AceTextureResourcePlugin createTexturePluginWithTarget:target instanceId:instanceId];
                _textureResourcePlugin.delegate = self;
                [self addResourcePlugin:_textureResourcePlugin];
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
    if (_videoResourcePlugin) {
        [_videoResourcePlugin releaseObject];
        _videoResourcePlugin = nil;
    }
    if (_textureResourcePlugin) {
        [_textureResourcePlugin releaseObject];
        _textureResourcePlugin = nil;
    }
    if (_surfacePlugin) {
        [_surfacePlugin releaseObject];
        _surfacePlugin = nil;
    }
    if (_resRegister) {
        [_resRegister releaseObject];
        _resRegister = nil;
    }
}

#pragma mark IAceSurface
- (uintptr_t)attachNaitveSurface:(CALayer *)layer
{
    // The CALayer's address is the native window handle the surface/video pattern stores.
    return reinterpret_cast<uintptr_t>(layer);
}

#pragma mark AceTextureDelegate
- (void)registerSurfaceWithInstanceId:(int32_t)instanceId textureId:(int64_t)textureId
    textureObject:(void*)textureObject
{
    OHOS::Ace::Platform::AcePlatformPlugin::RegisterSurface(instanceId, textureId, textureObject);
}

- (void)unregisterSurfaceWithInstanceId:(int32_t)instanceId textureId:(int64_t)textureId
{
    OHOS::Ace::Platform::AcePlatformPlugin::UnregisterSurface(instanceId, textureId);
}

- (void*)getNativeWindowWithInstanceId:(int32_t)instanceId textureId:(int64_t)textureId
{
    return OHOS::Ace::Platform::AcePlatformPlugin::GetNativeWindow(instanceId, textureId);
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
