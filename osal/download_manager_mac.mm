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

// M4: native-macOS DownloadManager. The OHOS DownloadManagerImpl uses NetStack::HttpClient
// (libcurl), which is not built for the arkui-x mac target, so GetInstance() was stubbed to
// nullptr -> URL images / network downloads silently failed. Implement the small surface the
// image loader actually calls (Download + *WithPreload) on top of NSURLSession.

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

#include "base/network/download_manager.h"

namespace OHOS::Ace {
namespace {
// Blocking GET via NSURLSession. Returns true and fills `out` on 2xx with a body.
bool FetchUrlSync(const std::string& url, std::string& out, std::string& err)
{
    @autoreleasepool {
        NSString* urlStr = [NSString stringWithUTF8String:url.c_str()];
        NSURL* nsurl = urlStr != nil ? [NSURL URLWithString:urlStr] : nil;
        if (nsurl == nil) {
            err = "invalid url";
            return false;
        }
        __block NSData* body = nil;
        __block NSError* nserr = nil;
        __block NSInteger status = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:nsurl
            completionHandler:^(NSData* data, NSURLResponse* response, NSError* e) {
                body = data;
                nserr = e;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    status = ((NSHTTPURLResponse*)response).statusCode;
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        const int64_t kTimeoutSec = 30;
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, kTimeoutSec * NSEC_PER_SEC)) != 0) {
            [task cancel];
            err = "download timeout";
            return false;
        }
        if (nserr != nil) {
            err = nserr.localizedDescription != nil ? nserr.localizedDescription.UTF8String : "download error";
            return false;
        }
        if (status >= 400 || body == nil || body.length == 0) {
            err = "http status " + std::to_string(static_cast<long>(status));
            return false;
        }
        out.assign(static_cast<const char*>(body.bytes), body.length);
        return true;
    }
}

class MacDownloadManager final : public DownloadManager {
public:
    bool Download(const std::string& url, std::vector<uint8_t>& dataOut) override
    {
        std::string data;
        std::string err;
        if (!FetchUrlSync(url, data, err)) {
            return false;
        }
        dataOut.assign(data.begin(), data.end());
        return true;
    }

    bool Download(const std::string& url, const std::shared_ptr<DownloadResult>& result) override
    {
        std::string data;
        std::string err;
        const bool ok = FetchUrlSync(url, data, err);
        if (result != nullptr) {
            result->dataOut = std::move(data);
            result->errorMsg = err;
            result->downloadSuccess = ok;
        }
        return ok;
    }

    bool DownloadSyncWithPreload(
        DownloadCallback&& downloadCallback, const std::string& url, int32_t instanceId) override
    {
        std::string data;
        std::string err;
        if (FetchUrlSync(url, data, err)) {
            if (downloadCallback.successCallback) {
                downloadCallback.successCallback(std::move(data), false, instanceId);
            }
            return true;
        }
        if (downloadCallback.failCallback) {
            downloadCallback.failCallback(err, ImageErrorInfo(), false, instanceId);
        }
        return false;
    }

    bool DownloadAsyncWithPreload(
        DownloadCallback&& downloadCallback, const std::string& url, int32_t instanceId) override
    {
        auto callback = std::make_shared<DownloadCallback>(std::move(downloadCallback));
        const std::string capturedUrl = url;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            std::string data;
            std::string err;
            if (FetchUrlSync(capturedUrl, data, err)) {
                if (callback->successCallback) {
                    callback->successCallback(std::move(data), true, instanceId);
                }
            } else if (callback->failCallback) {
                callback->failCallback(err, ImageErrorInfo(), true, instanceId);
            }
        });
        return true;
    }

    // The OHOS base declares these virtuals but their definitions live in the (mac-unbuilt)
    // DownloadManagerImpl, so every virtual must be overridden here or the vtable would reference
    // undefined base symbols. Route task-style calls to the *WithPreload path; stub the rest.
    bool DownloadAsync(DownloadCallback&& downloadCallback, const std::string& url, int32_t instanceId,
        int32_t /* nodeId */) override
    {
        return DownloadAsyncWithPreload(std::move(downloadCallback), url, instanceId);
    }

    bool DownloadSync(DownloadCallback&& downloadCallback, const std::string& url, int32_t instanceId,
        int32_t /* nodeId */) override
    {
        return DownloadSyncWithPreload(std::move(downloadCallback), url, instanceId);
    }

    bool RemoveDownloadTask(const std::string& /* url */, int32_t /* nodeId */, bool /* isCancel */) override
    {
        return true;
    }

    bool RemoveDownloadTaskWithPreload(const std::string& /* url */, bool /* isCancel */) override
    {
        return true;
    }

    bool IsContains(const std::string& /* url */) override
    {
        return false;
    }

    bool fetchCachedResult(const std::string& /* url */, std::string& /* result */) override
    {
        return false;
    }

    void* WrapDownloadInfoToNapiValue(void* /* env */, const ImageErrorInfo& /* errorInfo */) override
    {
        return nullptr;
    }
};
} // namespace

DownloadManager* DownloadManager::GetInstance()
{
    static MacDownloadManager instance;
    return &instance;
}

} // namespace OHOS::Ace
