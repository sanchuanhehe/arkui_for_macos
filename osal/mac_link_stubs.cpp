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

// Phase 0 path X (M1 link): centralized link stubs for the native-macOS app
// shell. These cover non-rendering-path symbols that are referenced by libace
// but whose real implementations are iOS/OHOS-only (or need deps not built for
// mac, e.g. ffmpeg). They let `ace_macos` link and open a window; the real
// implementations are follow-up work. Each stub no-ops / returns a default and
// is defined exactly once here (do not also stub these elsewhere).

#include <cstddef>
#include <cstdint>
#include <list>
#include <memory>
#include <string>

#include "base/log/log_wrapper.h"

// ---------------------------------------------------------------------------
// DynamicModule menu factories (extern "C", referenced by menu pattern bridge).
// ---------------------------------------------------------------------------
extern "C" void* OHOS_ACE_DynamicModule_Create_Menu()
{
    return nullptr;
}
extern "C" void* OHOS_ACE_DynamicModule_Create_MenuItem()
{
    return nullptr;
}
extern "C" void* OHOS_ACE_DynamicModule_Create_MenuItemGroup()
{
    return nullptr;
}

// ---------------------------------------------------------------------------
// LogInterfaceBridge free functions (declared in
// adapter/ios/entrance/logIntercept/LogInterfaceBridge.h). The macOS osal
// log_wrapper references these to optionally forward logs to a delegate; with
// no delegate they are inert.
// ---------------------------------------------------------------------------
bool HasDelegateMethod()
{
    return false;
}

void PassLogMessageOC(const std::string& /* domain */, const int& /* level */, const std::string& /* logInfo */)
{
}

OHOS::Ace::LogLevel GetCurrentLogLevel()
{
    return OHOS::Ace::LogLevel::INFO;
}

// ---------------------------------------------------------------------------
// Accessibility ObjC-bridge free functions (declared in
// adapter/ios/entrance/accessibility/AceAccessibilityBridge.h). The macOS osal
// accessibility_manager_impl.cpp references these; on mac accessibility is not
// wired to AppKit NSAccessibility yet, so they are inert.
// ---------------------------------------------------------------------------
#include "adapter/macos/osal/accessibility_manager_impl.h"

using namespace OHOS::Ace::Framework;

bool ExecuteActionOC(
    const int /* windowId */, const std::shared_ptr<AccessibilityManagerImpl::InteractionOperation>& /* op */)
{
    return false;
}

void UpdateNodesOC(
    const std::list<OHOS::Accessibility::AccessibilityElementInfo>& /* infos */, const int /* windowId */,
    const size_t /* eventType */)
{
}

void SendAccessibilityEventOC(const int64_t /* elementId */, const int /* windowId */, const size_t /* eventType */)
{
}

bool SubscribeState(
    const int /* windowId */, const std::shared_ptr<AccessibilityManagerImpl::AccessibilityStateObserver>& /* obs */)
{
    return false;
}

void UnSubscribeState(const int /* windowId */)
{
}

void AnnounceForAccessibilityOC(const std::string& /* text */)
{
}

bool IsUITestingEnabled(const uint32_t /* windowId */)
{
    return false;
}

// ---------------------------------------------------------------------------
// skia port stub. The mac build does not compile skia's platform SkDebugf
// (SkDebug_stdio/ohos), so provide an inert version. The SkFontMgr::Factory /
// HmSymbolConfig / runtimeOS symbols are now provided by skia's real mac font
// ports (skia_use_fonthost_mac=true / CoreText), so they are NOT stubbed here.
// ---------------------------------------------------------------------------

// SkDebugf has C++ linkage (declared in skia's SkDebug.h); match it.
void SkDebugf(const char* /* format */, ...)
{
}

// ---------------------------------------------------------------------------
// ace platform services (non-startup paths): static helpers + concrete-class
// methods that have no mac implementation. Inert so libace links; these cover
// vibration, html<->spanstring, and multi-type clipboard records.
// ---------------------------------------------------------------------------
#include <vector>

#include "core/common/vibrator/vibrator_utils.h"
// span_string.h provides the NG::SpanItem / FontStyle / TextLineStyle types used
// by the HtmlUtils overloads below.
#include "core/components_ng/pattern/text/span/span_string.h"
#include "core/text/html_utils.h"

namespace OHOS::Ace::NG {
void VibratorUtils::StartVibraFeedback(const std::string& /*vibratorType*/)
{
}
void VibratorUtils::StartViratorDirectly(const std::string& /*vibratorType*/)
{
}
} // namespace OHOS::Ace::NG

namespace OHOS::Ace {
RefPtr<MutableSpanString> HtmlUtils::FromHtml(const std::string& /*str*/)
{
    return nullptr;
}
std::string HtmlUtils::ToHtml(const SpanString* /*str*/)
{
    return std::string();
}
std::string HtmlUtils::ToHtml(const std::list<RefPtr<NG::SpanItem>>& /*spanItems*/)
{
    return std::string();
}
std::string HtmlUtils::ToHtmlForNormalType(
    const NG::FontStyle& /*fontStyle*/, const NG::TextLineStyle& /*textLineStyle*/, const std::u16string& /*content*/)
{
    return std::string();
}
} // namespace OHOS::Ace

// ---------------------------------------------------------------------------
// MultiTypeRecordImpl (concrete clipboard record). Real impl is iOS/OHOS-only;
// inert versions suffice for the M1 shell (no clipboard on the render path).
// ---------------------------------------------------------------------------
#include "adapter/macos/osal/multiType_record_impl.h"

namespace OHOS::Ace {
void MultiTypeRecordImpl::SetPlainText(const std::string /*plainText*/) {}
void MultiTypeRecordImpl::SetUri(const std::string /*uri*/) {}
void MultiTypeRecordImpl::SetPixelMap(RefPtr<PixelMap> /*pixelMap*/) {}
void MultiTypeRecordImpl::SetHtmlText(const std::string& /*htmlText*/) {}
std::vector<uint8_t>& MultiTypeRecordImpl::GetSpanStringBuffer()
{
    static std::vector<uint8_t> buffer;
    return buffer;
}
} // namespace OHOS::Ace

// ---------------------------------------------------------------------------
// Singleton services with no mac implementation. Pointer-returning factories
// return nullptr (callers on non-startup paths null-check); reference-returning
// abstract singletons get a minimal inert concrete subclass.
// ---------------------------------------------------------------------------
#include "base/network/download_manager.h"
#include "base/window/foldable_window.h"
#include "core/common/setting_data_manager.h"
#include "core/common/udmf/udmf_client.h"
#include "core/common/xcollie/xcollieInterface.h"

namespace OHOS::Ace {

// DownloadManager::GetInstance() is now implemented in download_manager_mac.mm (NSURLSession),
// enabling URL image / network downloads. It is intentionally NOT stubbed here.

RefPtr<FoldableWindow> FoldableWindow::CreateFoldableWindow(int32_t /*instanceId*/)
{
    return nullptr;
}

UdmfClient* UdmfClient::GetInstance()
{
    return nullptr;
}

// XcollieInterface has only non-pure virtuals (default empty bodies) -> a bare
// instance is concrete; return a static one.
XcollieInterface& XcollieInterface::GetInstance()
{
    static XcollieInterface instance;
    return instance;
}

namespace {
class MacStubSettingDataManager final : public SettingDataManager {
public:
    int32_t Initialize() override { return 0; }
    bool IsInitialized() const override { return false; }
    int32_t GetCurrentUserId() override { return INVALID_USER_ID; }
    int32_t RegisterObserver(const std::string&, const DataUpdateFunc&, int32_t) override { return 0; }
    int32_t UnregisterObserver(const std::string&, int32_t) override { return 0; }
    int32_t GetStringValue(const std::string&, std::string&, int32_t) const override { return 0; }
    int32_t GetInt32ValueStrictly(const std::string&, int32_t&, int32_t) const override { return 0; }
};
} // namespace

SettingDataManager& SettingDataManager::GetInstance()
{
    static MacStubSettingDataManager instance;
    return instance;
}

} // namespace OHOS::Ace

// ---------------------------------------------------------------------------
// Reporter (abstract, reference-returning) + UiSessionManager (pointer).
// ---------------------------------------------------------------------------
#include "core/common/reporter/reporter.h"
#include "interfaces/inner_api/ui_session/ui_session_manager.h"

namespace OHOS::Ace {
namespace NG {
namespace {
class MacStubReporter final : public Reporter {
public:
    void HandleUISessionReporting(const JsonReport&) const override {}
    void HandleInputEventInspectorReporting(const TouchEvent&) const override {}
    void HandleInputEventInspectorReporting(const MouseEvent&) const override {}
    void HandleInputEventInspectorReporting(const AxisEvent&) const override {}
    void HandleInputEventInspectorReporting(const KeyEvent&) const override {}
    void HandleWindowFocusInspectorReporting(bool) const override {}
    void HandleInspectorReporting(const JsonReport&) const override {}
};
} // namespace

Reporter& Reporter::GetInstance()
{
    static MacStubReporter instance;
    return instance;
}
} // namespace NG

namespace {
// Minimal concrete UiSessionManager so callers (e.g. StageManager::PushPage ->
// OnRouterChange) get a valid instance instead of dereferencing nullptr. All of the
// base-class hooks are no-op virtuals, so the default subclass is inert.
class MacStubUiSessionManager final : public UiSessionManager {};
} // namespace

UiSessionManager* UiSessionManager::GetInstance()
{
    static MacStubUiSessionManager instance;
    return &instance;
}
} // namespace OHOS::Ace

// ---------------------------------------------------------------------------
// Picker audio-haptic factory, environment proxy, and text-input handler/
// connection. These have UIKit/iOS-only real impls; inert versions here.
// ---------------------------------------------------------------------------
#include "adapter/ios/entrance/picker/picker_haptic_factory.h"
#include "adapter/ios/capability/environment/environment_proxy_impl.h"
#include "adapter/ios/capability/editing/text_input_client_handler.h"
#include "adapter/ios/capability/editing/text_input_connection_impl.h"

namespace OHOS::Ace {

namespace NG {
std::shared_ptr<IPickerAudioHaptic> PickerAudioHapticFactory::GetInstance(
    const std::string& /*uri*/, const std::string& /*effectId*/)
{
    return nullptr;
}
} // namespace NG

namespace Platform {

// EnvironmentProxyImpl::GetInstance/GetEnvironment now come from the iOS
// environment_proxy_impl.cpp compiled into the macOS build, backed by the
// NSWorkspace EnvironmentImpl in adapter/macos/capability/environment.

// The real macOS TextInputConnectionImpl (driving NSTextInputClient via
// MacTextInputBridge) lives in adapter/macos/entrance/mac_text_input.mm. The
// TextInputClientHandler ctor/dtor, singleton and UpdateEditingValue/PerformAction
// now come from the iOS text_input_client_handler.cpp compiled into the macOS
// entrance, so they are no longer stubbed here (would duplicate those symbols).

} // namespace Platform

} // namespace OHOS::Ace
