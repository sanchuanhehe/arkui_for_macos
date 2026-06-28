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

#ifndef FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_ACCESSIBILITY_BRIDGE_H
#define FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_ACCESSIBILITY_BRIDGE_H

#include <cstdint>
#include <string>
#include <vector>

namespace OHOS::Ace::Platform {

// A flattened snapshot of one ArkUI accessibility node, used to bridge the
// engine's NG::FrameNode tree to macOS NSAccessibility (VoiceOver / Accessibility
// Inspector). Geometry is in window coordinates, top-left origin, in vp-scaled
// px as the engine reports them; the WindowView converts to screen coordinates.
struct MacA11yNode {
    int32_t id = -1;
    int32_t parentId = -1;
    std::string role;   // engine tag, e.g. "Text", "Button", "TextInput"
    std::string label;  // accessibility text / content
    std::string value;  // current value (e.g. text field contents)
    double x = 0, y = 0, w = 0, h = 0;
    bool visible = false;
    bool checkable = false;
    bool checked = false;
    bool enabled = true;
};

// Build a flattened accessibility tree for the given ArkUI instance. The first
// entry (if any) is the root; every other node's parentId references an earlier
// entry. Returns empty if the container / pipeline / root is not available yet.
std::vector<MacA11yNode> BuildMacA11yTree(int32_t instanceId);

} // namespace OHOS::Ace::Platform

#endif // FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_ACCESSIBILITY_BRIDGE_H
