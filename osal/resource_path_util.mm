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

#import <Foundation/Foundation.h>

#include "resource_path_util.h"
namespace OHOS::Ace {
std::string ResourcePathUtil::GetBundlePath()
{
    // resourcePath, not bundlePath: in an .app resources live under Contents/Resources;
    // for a bare exe resourcePath == bundlePath (the exe dir). See StageAssetManager.
    NSString* resourceRoot = [NSBundle mainBundle].resourcePath ?: [NSBundle mainBundle].bundlePath;
    NSString* bundlePath = [NSString stringWithFormat:@"%@/%@", resourceRoot, @"arkui-x"];
    return [bundlePath UTF8String];
}

std::string ResourcePathUtil::GetSandboxPath()
{
    // Application Support, not Documents: on macOS NSDocumentDirectory is the user's
    // ~/Documents, which triggers a TCC privacy prompt on every app launch. App
    // private data belongs in ~/Library/Application Support (no prompt).
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* documentsDirectory = [paths objectAtIndex:0];
    NSString* bundlePath = [NSString stringWithFormat:@"%@/%@/%@", documentsDirectory, @"files", @"arkui-x"];
    return [bundlePath UTF8String];
}
} // namespace OHOS::Ace