// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The numbers the shell's "Clear browsing data" page shows next to each
// checkbox.
//
//   getBrowsingDataCounts {requestId, timeRange}
//     -> "browsingDataCounts" {requestId, historyCount, cacheBytes, siteCount,
//                              passwordCount, formDataCount,
//                              siteSettingsCount}
//
// historyCount is what chrome://history lists for the range: each URL once
// per day. cacheBytes may be an upper bound (Chromium cannot always size the
// cache for a time range exactly). siteCount is the number of sites holding
// cookies or storage. passwordCount is the number of saved sign-ins, and it
// is only reported while the shell's password pages are unlocked by a
// password store that is actually available. formDataCount counts the
// autofill entries (addresses, cards, form history) in the range.
// siteSettingsCount is the number of distinct hosts whose site settings were
// changed in the range. Any number that could not be computed is -1.
//
// The counters are Chromium's own (//chrome/browser/browsing_data/counters
// and //components/browsing_data/core/counters), run without their prefs:
// those prefs belong to the WebUI dialog, and the shell passes the range with
// each query instead.

#include <map>
#include <memory>
#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/autofill/autofill_entity_data_manager_factory.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/browsing_data/counters/cache_counter.h"
#include "chrome/browser/browsing_data/counters/site_data_counter.h"
#include "chrome/browser/browsing_data/counters/site_settings_counter.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/password_manager/factories/account_password_store_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/sync/sync_service_factory.h"
#include "chrome/browser/ui/ohos/shell_services_ohos.h"
#include "chrome/browser/ui/ohos/shell_settings_ohos_internal.h"
#include "chrome/browser/webdata_services/web_data_service_factory.h"
#include "components/autofill/core/browser/webdata/autofill_webdata_service.h"
#include "components/browsing_data/core/browsing_data_utils.h"
#include "components/browsing_data/core/counters/autofill_counter.h"
#include "components/browsing_data/core/counters/browsing_data_counter.h"
#include "components/browsing_data/core/counters/passwords_counter.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "content/public/browser/host_zoom_map.h"

namespace chrome::ohos::settings_internal {

namespace {

using browsing_data::BrowsingDataCounter;

// What the shell reads as "unknown".
constexpr double kUnknownCount = -1;

// A counter whose backend fails (a cache backend error, for one) never
// reports; the shell still gets an answer, with -1 for what is missing.
constexpr base::TimeDelta kCountsTimeout = base::Seconds(10);

// One getBrowsingDataCounts in flight. Answers exactly once, then runs
// `on_done` from a fresh task so its owner can delete it -- a counter may
// still be on the stack when it reports.
class CountsQuery {
 public:
  CountsQuery(Profile* profile,
              const ShellCommandContext& context,
              int request_id,
              browsing_data::TimePeriod period,
              base::OnceClosure on_done)
      : profile_(profile),
        context_(context),
        request_id_(request_id),
        begin_(browsing_data::CalculateBeginDeleteTime(period)),
        end_(browsing_data::CalculateEndDeleteTime(period)),
        on_done_(std::move(on_done)) {}

  CountsQuery(const CountsQuery&) = delete;
  CountsQuery& operator=(const CountsQuery&) = delete;
  ~CountsQuery() = default;

  void Start() {
    timeout_.Start(FROM_HERE, kCountsTimeout, this, &CountsQuery::Report);
    StartHistoryCount();
    cache_counter_ = StartCounter(std::make_unique<CacheCounter>(profile_),
                                  &cache_bytes_);
    site_counter_ = StartCounter(std::make_unique<SiteDataCounter>(profile_),
                                 &site_count_);
    StartPasswordCount();
    StartFormDataCount();
    StartSiteSettingsCount();
  }

 private:
  void StartHistoryCount() {
    history::HistoryService* history = HistoryServiceFactory::GetForProfile(
        profile_, ServiceAccessType::EXPLICIT_ACCESS);
    if (!history) {
      history_count_ = kUnknownCount;
      return;
    }
    history->GetHistoryCount(
        begin_, end_, history::VisitQuery404sPolicy::kExclude404s,
        base::BindOnce(&CountsQuery::OnHistoryCount, base::Unretained(this)),
        &history_tracker_);
  }

  void OnHistoryCount(history::HistoryCountResult result) {
    history_count_ = result.success ? result.count : kUnknownCount;
    MaybeReport();
  }

  // Passwords, autofill and site settings only start when the services behind
  // them exist: a counter handed a null store dereferences it, and "could not
  // be computed" is already what the shell draws as unknown.
  void StartPasswordCount() {
    auto profile_store = ProfilePasswordStoreFactory::GetForProfile(
        profile_, ServiceAccessType::EXPLICIT_ACCESS);
    auto account_store = AccountPasswordStoreFactory::GetForProfile(
        profile_, ServiceAccessType::EXPLICIT_ACCESS);
    if (!profile_store && !account_store) {
      password_count_ = kUnknownCount;
      return;
    }
    passwords_counter_ = StartCounter(
        std::make_unique<browsing_data::PasswordsCounter>(
            profile_store, account_store, profile_->GetPrefs(),
            SyncServiceFactory::GetForProfile(profile_)),
        &password_count_);
  }

  void StartFormDataCount() {
    auto* personal_data =
        autofill::PersonalDataManagerFactory::GetForBrowserContext(profile_);
    auto web_data = WebDataServiceFactory::GetAutofillWebDataForProfile(
        profile_, ServiceAccessType::EXPLICIT_ACCESS);
    if (!personal_data || !web_data) {
      form_data_count_ = kUnknownCount;
      return;
    }
    form_data_counter_ = StartCounter(
        std::make_unique<browsing_data::AutofillCounter>(
            personal_data, web_data,
            autofill::AutofillEntityDataManagerFactory::GetForProfile(profile_),
            SyncServiceFactory::GetForProfile(profile_)),
        &form_data_count_);
  }

  // Site settings live in the content settings map, but Chromium's counter
  // also walks zoom levels, protocol handlers and the "never translate" list,
  // so it is the only thing that answers the same number the dialog shows.
  void StartSiteSettingsCount() {
    auto* settings_map =
        HostContentSettingsMapFactory::GetForProfile(profile_);
    auto* zoom_map =
        content::HostZoomMap::GetDefaultForBrowserContext(profile_);
    auto* handlers =
        ProtocolHandlerRegistryFactory::GetForBrowserContext(profile_);
    auto* prefs = profile_->GetPrefs();
    if (!settings_map || !zoom_map || !handlers || !prefs) {
      site_settings_count_ = kUnknownCount;
      return;
    }
    site_settings_counter_ = StartCounter(
        std::make_unique<SiteSettingsCounter>(settings_map, zoom_map, handlers,
                                              prefs),
        &site_settings_count_);
  }

  // The counter reports through a callback it owns, so binding `this`
  // unretained is safe: the counter dies with this query.
  std::unique_ptr<BrowsingDataCounter> StartCounter(
      std::unique_ptr<BrowsingDataCounter> counter,
      std::optional<double>* slot) {
    counter->InitWithoutPref(
        begin_, base::BindRepeating(&CountsQuery::OnCounterResult,
                                    base::Unretained(this),
                                    base::Unretained(slot)));
    counter->Restart();
    return counter;
  }

  void OnCounterResult(std::optional<double>* slot,
                       std::unique_ptr<BrowsingDataCounter::Result> result) {
    // Without a period pref the counters never show "calculating", but a
    // non-final result is harmless to skip.
    if (!result || !result->Finished()) {
      return;
    }
    *slot = static_cast<double>(
        static_cast<const BrowsingDataCounter::FinishedResult*>(result.get())
            ->Value());
    MaybeReport();
  }

  void MaybeReport() {
    if (history_count_ && cache_bytes_ && site_count_ && password_count_ &&
        form_data_count_ && site_settings_count_) {
      Report();
    }
  }

  void Report() {
    if (!on_done_) {
      return;  // Already answered; a counter restarted on a sync change.
    }
    timeout_.Stop();
    base::DictValue event;
    event.Set("event", "browsingDataCounts");
    event.Set("requestId", request_id_);
    event.Set("historyCount", history_count_.value_or(kUnknownCount));
    event.Set("cacheBytes", cache_bytes_.value_or(kUnknownCount));
    event.Set("siteCount", site_count_.value_or(kUnknownCount));
    event.Set("passwordCount", password_count_.value_or(kUnknownCount));
    event.Set("formDataCount", form_data_count_.value_or(kUnknownCount));
    event.Set("siteSettingsCount",
              site_settings_count_.value_or(kUnknownCount));
    ReplyToShell(context_, std::move(event));
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(on_done_));
  }

  const raw_ptr<Profile> profile_;
  const ShellCommandContext context_;
  const int request_id_;
  const base::Time begin_;
  const base::Time end_;
  base::OnceClosure on_done_;

  std::optional<double> history_count_;
  std::optional<double> cache_bytes_;
  std::optional<double> site_count_;
  std::optional<double> password_count_;
  std::optional<double> form_data_count_;
  std::optional<double> site_settings_count_;

  base::CancelableTaskTracker history_tracker_;
  std::unique_ptr<BrowsingDataCounter> cache_counter_;
  std::unique_ptr<BrowsingDataCounter> site_counter_;
  std::unique_ptr<BrowsingDataCounter> passwords_counter_;
  std::unique_ptr<BrowsingDataCounter> form_data_counter_;
  std::unique_ptr<BrowsingDataCounter> site_settings_counter_;
  base::OneShotTimer timeout_;
};

// The queries in flight for the windows of one profile. Keyed by the profile
// that asked, which is also what the reply marks as incognito or not: an
// incognito profile can go away before the regular one whose data is being
// counted, and its queries must go with it.
class CountsQueries {
 public:
  CountsQueries() = default;
  CountsQueries(const CountsQueries&) = delete;
  CountsQueries& operator=(const CountsQueries&) = delete;
  ~CountsQueries() = default;

  void Start(Profile* settings_profile,
             const ShellCommandContext& context,
             int request_id,
             browsing_data::TimePeriod period) {
    const int id = next_id_++;
    auto query = std::make_unique<CountsQuery>(
        settings_profile, context, request_id, period,
        base::BindOnce(&CountsQueries::Remove, weak_factory_.GetWeakPtr(),
                       id));
    CountsQuery* started = query.get();
    queries_.emplace(id, std::move(query));
    started->Start();
  }

 private:
  void Remove(int id) { queries_.erase(id); }

  int next_id_ = 0;
  std::map<int, std::unique_ptr<CountsQuery>> queries_;
  base::WeakPtrFactory<CountsQueries> weak_factory_{this};
};

PerProfile<CountsQueries>& QueriesPerProfile() {
  static base::NoDestructor<PerProfile<CountsQueries>> queries(
      base::BindRepeating(
          [](Profile*) { return std::make_unique<CountsQueries>(); }));
  return *queries;
}

void ReplyUnknownCounts(const ShellCommandContext& context, int request_id) {
  base::DictValue event;
  event.Set("event", "browsingDataCounts");
  event.Set("requestId", request_id);
  event.Set("historyCount", kUnknownCount);
  event.Set("cacheBytes", kUnknownCount);
  event.Set("siteCount", kUnknownCount);
  event.Set("passwordCount", kUnknownCount);
  event.Set("formDataCount", kUnknownCount);
  event.Set("siteSettingsCount", kUnknownCount);
  ReplyToShell(context, std::move(event));
}

}  // namespace

void GetBrowsingDataCounts(const ShellCommandContext& context,
                           const base::DictValue& command) {
  const int request_id = ReadRequestId(command);
  Profile* profile = SettingsProfile(context);
  const std::optional<browsing_data::TimePeriod> period =
      ReadTimePeriod(command);
  if (!profile || !period) {
    ReplyUnknownCounts(context, request_id);
    return;
  }
  QueriesPerProfile().Get(context.profile)->Start(profile, context,
                                                  request_id, *period);
}

}  // namespace chrome::ohos::settings_internal
