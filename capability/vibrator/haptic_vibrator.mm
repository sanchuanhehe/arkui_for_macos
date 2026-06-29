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

#include "adapter/macos/capability/vibrator/haptic_vibrator.h"

// macOS desktops have no haptic engine (NSHapticFeedbackManager exists only for trackpads and
// is not a general vibration API). The Web carrier's selection-drag haptic is a no-op here.
namespace OHOS::Ace::Platform {
void HapticVibrator::StartVibraFeedback(const std::string& /* effectId */) {}
} // namespace OHOS::Ace::Platform
