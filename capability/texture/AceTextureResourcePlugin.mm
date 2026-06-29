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

#import "AceTextureResourcePlugin.h"

#import "AceTextureHolder.h"
#import "AceTexture.h"
#import "AceTextureDelegate.h"
#include "base/log/log.h"

@class NSViewController;

// Mirrors the iOS plugin's texture type tags. Video uses TEXTURETYPE_PLATFORMVIEW (the default),
// which registers the AceTexture's videoOutput so the Rosen texture surface can pull frames.
static const NSInteger TEXTURETYPE_PLATFORMVIEW = 0;

@interface AceTextureResourcePlugin()
@property (nonatomic, strong) NSMutableDictionary<NSString*, AceTexture*> *objectMap;
@property (nonatomic, assign) int32_t instanceId;
@property (nonatomic, weak) NSViewController *target;
@end

@implementation AceTextureResourcePlugin

+ (AceTextureResourcePlugin *)createTexturePluginWithTarget:(NSViewController *)target instanceId:(int32_t)instanceId
{
    return [[AceTextureResourcePlugin alloc] initTextureWithTarget:target instanceId:instanceId];
}

- (instancetype)initTextureWithTarget:(NSViewController *)target instanceId:(int32_t)instanceId
{
    self = [super init:@"texture" version:1];
    if (self) {
        self.objectMap = [NSMutableDictionary dictionary];
        self.instanceId = instanceId;
        if (target) {
            self.target = target;
        }
    }
    return self;
}

- (void)addResource:(int64_t)textureId texture:(AceTexture *)texture type:(NSInteger)type
{
    [self.objectMap setObject:texture forKey:[NSString stringWithFormat:@"%lld", textureId]];
    NSDictionary *callMethod = [texture getCallMethod];
    [self registerSyncCallMethod:callMethod];
    // Register the videoOutput pointer so AceViewSG::GetNativeWindowById (-> AcePlatformPlugin::
    // GetNativeWindow) can hand it to the Rosen RSSurfaceTextureMac as config.additionalData.
    if (type == TEXTURETYPE_PLATFORMVIEW) {
        [self.delegate registerSurfaceWithInstanceId:self.instanceId textureId:textureId
            textureObject:(__bridge void*)texture.videoOutput];
    }
    [AceTextureHolder addTexture:texture withId:textureId inceId:self.instanceId];
}

- (int64_t)create:(NSDictionary<NSString *, NSString *> *)param
{
    int64_t textureId = [self getAtomicId];
    IAceOnResourceEvent callback = [self getEventCallback];
    if (!callback) {
        return -1L;
    }
    NSInteger type = TEXTURETYPE_PLATFORMVIEW;
    if (param && param[@"type"]) {
        type = [param[@"type"] integerValue];
    }
    LOGI("AceTextureCreate type: %{public}ld", static_cast<long>(type));
    AceTexture *texture = [[AceTexture alloc] initWithEvents:callback textureId:textureId
        abilityInstanceId:self.instanceId];
    [self addResource:textureId texture:texture type:type];
    return textureId;
}

- (id)getObject:(NSString *)incId
{
    return [self.objectMap objectForKey:incId];
}

- (BOOL)release:(NSString *)incId
{
    LOGI("AceTextureResourcePlugin release inceId: %{public}s", [incId UTF8String]);
    AceTexture *texture = [self.objectMap objectForKey:incId];
    if (texture) {
        [self unregisterSyncCallMethod:[texture getCallMethod]];
        [texture releaseObject];
        [self.objectMap removeObjectForKey:incId];
        [AceTextureHolder removeTextureWithId:[incId intValue] inceId:self.instanceId];
        [self.delegate unregisterSurfaceWithInstanceId:self.instanceId textureId:[incId intValue]];
        texture = nil;
        return YES;
    }
    return NO;
}

- (void)releaseObject
{
    LOGI("AceTextureResourcePlugin releaseObject");
    if (self.objectMap) {
        [self.objectMap enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key,
            AceTexture *_Nonnull texture, BOOL * _Nonnull stop) {
            if (texture) {
                [texture releaseObject];
                texture = nil;
            }
        }];
        [self.objectMap removeAllObjects];
        self.objectMap = nil;
    }
}

- (void)dealloc
{
    LOGI("AceTextureResourcePlugin dealloc instanceId=%{public}d", self.instanceId);
}
@end
