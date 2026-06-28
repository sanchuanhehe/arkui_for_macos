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

#include "adapter/macos/entrance/mac_accessibility_bridge.h"

#include "base/memory/ace_type.h"
#include "base/utils/utils.h"
#include "core/common/ace_engine.h"
#include "core/components_ng/base/frame_node.h"
#include "core/components_ng/property/accessibility_property.h"
#include "core/pipeline_ng/pipeline_context.h"

namespace OHOS::Ace::Platform {
namespace {
// Walk the UINode tree, emitting a MacA11yNode for every FrameNode. Non-frame
// UINodes are transparent: their frame descendants reparent onto the nearest
// frame ancestor, matching how the engine's own accessibility walk collapses
// internal wrapper nodes.
void Traverse(const RefPtr<NG::UINode>& node, int32_t parentFrameId, std::vector<MacA11yNode>& out)
{
    CHECK_NULL_VOID(node);
    int32_t nextParent = parentFrameId;
    auto frameNode = AceType::DynamicCast<NG::FrameNode>(node);
    if (frameNode) {
        MacA11yNode info;
        info.id = frameNode->GetAccessibilityId();
        info.parentId = parentFrameId;
        info.role = frameNode->GetTag();
        auto prop = frameNode->GetAccessibilityProperty<NG::AccessibilityProperty>();
        if (prop) {
            info.label = prop->GetText();
            info.checkable = prop->IsCheckable();
            info.checked = prop->IsChecked();
        }
        auto rect = frameNode->GetTransformRectRelativeToWindow();
        info.x = rect.Left();
        info.y = rect.Top();
        info.w = rect.Width();
        info.h = rect.Height();
        info.visible = frameNode->IsVisible();
        out.push_back(info);
        nextParent = info.id;
    }
    for (const auto& child : node->GetChildren()) {
        Traverse(child, nextParent, out);
    }
}
} // namespace

std::vector<MacA11yNode> BuildMacA11yTree(int32_t instanceId)
{
    std::vector<MacA11yNode> out;
    auto container = AceEngine::Get().GetContainer(instanceId);
    CHECK_NULL_RETURN(container, out);
    auto pipeline = AceType::DynamicCast<NG::PipelineContext>(container->GetPipelineContext());
    CHECK_NULL_RETURN(pipeline, out);
    auto root = pipeline->GetRootElement();
    CHECK_NULL_RETURN(root, out);
    Traverse(root, -1, out);
    return out;
}

} // namespace OHOS::Ace::Platform
