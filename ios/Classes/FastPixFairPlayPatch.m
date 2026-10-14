#import "FastPixFairPlayPatch.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

/// # Why this file exists
///
/// `better_player_plus` implements FairPlay for EZDRM specifically, and bakes
/// three of EZDRM's conventions into `BetterPlayerEzDrmAssetsLoaderDelegate`:
///
/// 1. the asset id and a `?customdata=` query are appended to *every* licence
///    URL — which corrupts a URL that already carries its own query string,
///    and FastPix signs its requests with `?token=`;
/// 2. the content id sent in the SPC is the whole `skd://` URI, where FastPix
///    keys the licence on the content id alone — that URI's host component;
/// 3. a non-2xx response body is handed to AVFoundation as though it were a
///    content key, so an authorisation failure surfaces as an opaque decode
///    error far from its cause.
///
/// Against FastPix all three are wrong, and protected playback cannot start.
///
/// # Why a substituted delegate rather than a patched one
///
/// The obvious approach — exchange the engine delegate's own method — needs to
/// read its `certificateURL` and `licenseURL`. Both are Swift `URL` *value*
/// types and are not `@objc`, so from Objective-C there is no accessor, no
/// KVC, and no usable ivar: `object_getIvar` yields an object pointer, which a
/// Swift struct is not.
///
/// So the delegate is replaced instead of patched. `-[AVAssetResourceLoader
/// setDelegate:queue:]` is intercepted, and when the engine installs its EZDRM
/// delegate, ours goes in its place — built from URLs Dart supplies, since
/// Dart constructs them for the engine anyway.
///
/// # Why the configuration comes from Dart
///
/// An earlier version took the URLs from `FastPixPlaybackAdoption`'s swizzle of
/// `setDataSourceURL:`, which receives them as arguments. That coupled FairPlay
/// to a hook that resolves better_player's class **by name** and legitimately
/// misses when the pod has not loaded yet — and when it missed, this patch
/// silently did nothing and the engine's EZDRM delegate produced an HTTP 500.
///
/// Two features that have nothing to do with each other should not fail
/// together, so the dependency is gone: nothing here consults the adoption
/// hook, and this file touches no other file's behaviour.
///
/// # Why this cannot disturb anything else
///
/// The interception substitutes **only** when both hold:
///
/// * a FairPlay configuration has been supplied for this playback; and
/// * the delegate being installed is the engine's EZDRM delegate class.
///
/// Every other `setDelegate:queue:` in the process — including
/// `FastPixCachingAssetHook`'s, which serves `fastpixcache://` — passes
/// straight through untouched, and non-DRM playback never reaches any of it.
///
/// If interception fails to install, behaviour is exactly the engine's own:
/// FairPlay fails against FastPix, which is what it does today without this
/// patch at all. No path here turns working playback into broken playback.
///
/// # What it costs
///
/// A dependency on the engine's delegate class *name*. A rename is reported
/// loudly at the first protected play rather than failing silently. This file
/// is deletable: if the fix lands upstream, remove it and raise the engine
/// version floor.

#pragma mark - Diagnostics

/// Distinct from the plain `[FastPixDRM]` tag used by the hand-edited pub-cache
/// copy, so a device log says unambiguously which code is running: this patch,
/// or a stale local patch that was never removed.
static NSString *const kFastPixDrmLogTag = @"[FastPixDRM/swizzle]";

static void FastPixDrmLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", kFastPixDrmLogTag, message);
}

#pragma mark - Counters

/// How many licence and certificate requests this process has made, and how
/// many per content id.
///
/// Preloading multiplies licence acquisition: a warm window of three protected
/// titles fetches three licences for videos nobody has asked for, and an
/// eviction throws that work away. Playback looks identical either way, so the
/// count is the only evidence. Kept here because this is the one place on iOS
/// where the request is genuinely ours — everything upstream of it can only
/// report intent.
///
/// Guarded by a lock: `shouldWaitForLoadingOfRequestedResource` is called on
/// AVFoundation's own queue, and more than one item can be loading at once.
static NSUInteger _fpLicenceRequestCount = 0;
static NSUInteger _fpCertificateRequestCount = 0;
static NSMutableDictionary<NSString *, NSNumber *> *_fpLicenceCountsByContentId = nil;
static NSLock *_fpCounterLock = nil;

static void FastPixDrmCounterInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _fpCounterLock = [NSLock new];
        _fpLicenceCountsByContentId = [NSMutableDictionary dictionary];
    });
}

/// Record a licence request for [contentId] and return its ordinal.
static NSUInteger FastPixCountLicenceRequest(NSString *contentId) {
    FastPixDrmCounterInit();
    [_fpCounterLock lock];
    _fpLicenceRequestCount += 1;
    NSUInteger total = _fpLicenceRequestCount;
    NSUInteger forId = _fpLicenceCountsByContentId[contentId].unsignedIntegerValue + 1;
    _fpLicenceCountsByContentId[contentId] = @(forId);
    [_fpCounterLock unlock];
    FastPixDrmLog(@"licence request #%lu (contentId=%@ #%lu for this id)",
                  (unsigned long)total, contentId, (unsigned long)forId);
    return total;
}

/// Record a certificate fetch and return its ordinal.
///
/// Counted separately because it is a *second* round trip on the tap path and
/// is not cached by this patch: every key request fetches it again.
static NSUInteger FastPixCountCertificateRequest(void) {
    FastPixDrmCounterInit();
    [_fpCounterLock lock];
    _fpCertificateRequestCount += 1;
    NSUInteger total = _fpCertificateRequestCount;
    [_fpCounterLock unlock];
    return total;
}

/// A URL reduced to scheme, host and path.
///
/// FastPix signs licence and certificate URLs with a `token` query parameter
/// that grants access to the content. Device logs are readable by other tooling
/// and are captured verbatim in bug reports, so no full URL is ever printed.
static NSString *FastPixRedact(NSURL *url) {
    if (url == nil) return @"(none)";
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url
                                       resolvingAgainstBaseURL:NO];
    if (parts == nil) return @"(unparseable)";
    parts.query = nil;
    parts.fragment = nil;
    return parts.string ?: @"(unprintable)";
}

/// Whether a licence server follows EZDRM's URL and content-id conventions.
///
/// When it does, the engine's original behaviour is reproduced exactly, so an
/// EZDRM integration is unaffected by this patch.
static BOOL FastPixUsesEzDrmFormat(NSURL *licenseURL) {
    NSString *host = licenseURL.host ?: @"";
    return [host isEqualToString:@"ezdrm.com"] || [host hasSuffix:@".ezdrm.com"];
}

/// EZDRM's public licence endpoint, used when none is configured — the engine's
/// own default, so an EZDRM integration behaves identically.
static NSString *const kEzDrmDefaultLicenseServer = @"https://fps.ezdrm.com/api/licenses/";

#pragma mark - Replacement resource-loader delegate

@interface FastPixFairPlayLoader : NSObject <AVAssetResourceLoaderDelegate>
- (instancetype)initWithCertificateURL:(NSURL *)certificateURL
                            licenseURL:(nullable NSURL *)licenseURL
                            playbackId:(nullable NSString *)playbackId;
@end

@implementation FastPixFairPlayLoader {
    NSURL *_certificateURL;
    NSURL *_licenseURL;
    NSString *_playbackId;
}

- (instancetype)initWithCertificateURL:(NSURL *)certificateURL
                            licenseURL:(NSURL *)licenseURL
                            playbackId:(NSString *)playbackId {
    if ((self = [super init])) {
        _certificateURL = certificateURL;
        _licenseURL = licenseURL ?: [NSURL URLWithString:kEzDrmDefaultLicenseServer];
        _playbackId = playbackId;
    }
    return self;
}

/// How many times one licence acquisition may be attempted.
///
/// A licence server that answers 500 once and 200 a moment later is a fact of
/// this deployment, not a hypothetical: two 500s were observed in a row on
/// 2026-09-22 while the certificate fetch on the same asset succeeded, and the
/// title played on the third try. Without a retry here the *only* retry is
/// AVFoundation's, which re-issues the key request roughly every 20 seconds and
/// re-fetches the certificate each time, which a viewer sees as tens of seconds
/// of black before a protected title starts.
static const NSUInteger kFastPixLicenceMaxAttempts = 3;

/// Waits between attempts. One entry per retry, so this array is one shorter
/// than [kFastPixLicenceMaxAttempts].
///
/// Short on purpose. This is a transient-error backoff on the tap path, not a
/// congestion control: a server that needs more than a second and a half to
/// stop throwing is not going to be waited out inside a resource-loader call.
static const NSTimeInterval kFastPixLicenceBackoff[] = {0.4, 1.2};

/// The ceiling on *all* attempts together, including their backoffs.
///
/// Unchanged from the single-attempt version, and that is the point: the
/// loader queue this blocks is serial (`BetterPlayer.swift:198`), so every key
/// request in the process waits behind this one. Retrying must not extend how
/// long that queue can be held — it divides the existing budget rather than
/// multiplying it.
static const NSTimeInterval kFastPixLicenceTotalBudget = 30.0;

/// The longest any single attempt may take, so a first attempt that hangs
/// cannot consume the whole budget and leave nothing for a retry.
static const NSTimeInterval kFastPixLicenceAttemptTimeout = 10.0;

/// Whether an outcome is worth trying again.
///
/// 5xx and a transport failure are; a 4xx is not. An expired token, a licence
/// issued for another playback id and a malformed SPC all answer 4xx, and
/// retrying those spends the budget to be refused three times — while the
/// viewer waits.
static BOOL FastPixLicenceIsRetryable(NSInteger status, BOOL transportFailed) {
    return transportFailed || status >= 500 || status <= 0;
}

/// POST the SPC to the licence server and return the CKC.
///
/// Blocking, and that is now fine: it runs on [FastPixFairPlayLoader
/// licenceQueue], never on the engine's loader queue.
///
/// It used to run inline in the delegate callback under the comment
/// "synchronous by necessity: `AVAssetResourceLoaderDelegate` expects the
/// loading request to be answered before this returns". **That premise was
/// false.** Returning `YES` from the delegate is precisely the contract for
/// answering later; the request may be finished at any point afterwards. The
/// mistaken reading is what put a 30s budget, three attempts and their backoff
/// on a `DISPATCH_QUEUE_SERIAL` shared by every resource-loading request the
/// asset makes. See the delegate method for the full account.
- (NSData *)contentKeyForSPC:(NSData *)spc assetId:(NSString *)assetId {
    BOOL usesEzDrm = FastPixUsesEzDrmFormat(_licenseURL);

    // EZDRM carries the asset id and passthrough parameters in the URL itself.
    // Every other server — FastPix included — is addressed exactly as
    // configured; appending to it corrupts the signing query and the server
    // rejects the request.
    NSURL *endpoint = usesEzDrm
        ? [NSURL URLWithString:[NSString stringWithFormat:@"%@%@?customdata=%@",
                                _licenseURL.absoluteString, assetId, assetId]]
        : _licenseURL;
    if (endpoint == nil) {
        FastPixDrmLog(@"licence URL could not be built.");
        return nil;
    }

    // The FastPix licence path ends in the playback ID, which is the id worth
    // counting by — `assetId` is EZDRM's trailing-36-characters convention and
    // is not a FastPix identifier.
    NSString *countedId = endpoint.path.lastPathComponent.length
        ? endpoint.path.lastPathComponent
        : (assetId.length ? assetId : (endpoint.host ?: @"?"));
    FastPixCountLicenceRequest(countedId);

    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime deadline = startedAt + kFastPixLicenceTotalBudget;

    NSData *contentKey = nil;
    NSInteger lastStatus = 0;
    NSUInteger attempt = 0;

    while (attempt < kFastPixLicenceMaxAttempts) {
        NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) {
            FastPixDrmLog(@"licence budget of %.0fs exhausted after %lu attempt(s).",
                          kFastPixLicenceTotalBudget, (unsigned long)attempt);
            break;
        }

        attempt += 1;
        BOOL transportFailed = NO;
        NSInteger status = 0;
        CFAbsoluteTime attemptStartedAt = CFAbsoluteTimeGetCurrent();
        contentKey = [self postSPC:spc
                                to:endpoint
                           timeout:MIN(remaining, kFastPixLicenceAttemptTimeout)
                            status:&status
                   transportFailed:&transportFailed];
        lastStatus = status;

        FastPixDrmLog(@"licence attempt %lu/%lu: %@ in %.0fms",
                      (unsigned long)attempt,
                      (unsigned long)kFastPixLicenceMaxAttempts,
                      contentKey.length ? @"OK"
                          : (transportFailed ? @"transport failure"
                                             : [NSString stringWithFormat:@"HTTP %ld",
                                                (long)status]),
                      (CFAbsoluteTimeGetCurrent() - attemptStartedAt) * 1000.0);

        if (contentKey.length > 0) break;
        if (!FastPixLicenceIsRetryable(status, transportFailed)) {
            // A refusal, not a wobble. Answering now is kinder than spending
            // the budget to be refused twice more.
            break;
        }
        if (attempt >= kFastPixLicenceMaxAttempts) break;

        NSTimeInterval backoff = kFastPixLicenceBackoff[attempt - 1];
        if (CFAbsoluteTimeGetCurrent() + backoff >= deadline) break;
        [NSThread sleepForTimeInterval:backoff];
    }

    double elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0;
    if (contentKey.length > 0 && attempt > 1) {
        // Worth its own line: a licence that needed retries is the difference
        // between a four-second start and a fifty-second one, and nothing else
        // in the system records it.
        FastPixDrmLog(@"licence recovered after %lu attempts in %.0fms.",
                      (unsigned long)attempt, elapsedMs);
    }
    [self reportAcquisition:countedId
                         ok:contentKey.length > 0
                     status:lastStatus
                   attempts:attempt
                  elapsedMs:elapsedMs
                      bytes:contentKey.length];
    return contentKey;
}

/// One attempt. Answers the CKC, or nil with [statusOut] and [transportOut]
/// describing why not.
- (NSData *)postSPC:(NSData *)spc
                 to:(NSURL *)endpoint
            timeout:(NSTimeInterval)timeout
             status:(NSInteger *)statusOut
    transportFailed:(BOOL *)transportOut {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = spc;
    request.timeoutInterval = timeout;

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *contentKey = nil;
    __block NSInteger status = 0;
    __block BOOL transportFailed = NO;

    NSURLSessionDataTask *task =
        [NSURLSession.sharedSession dataTaskWithRequest:request
                                      completionHandler:^(NSData *data,
                                                          NSURLResponse *response,
                                                          NSError *error) {
        if (error != nil) {
            transportFailed = YES;
            FastPixDrmLog(@"licence request failed for %@: %@",
                          FastPixRedact(endpoint), error.localizedDescription);
        } else {
            status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : -1;
            // A licence server reports rejection with an HTTP status, not a
            // transport error. Without this check an error body — JSON, HTML —
            // is handed to AVFoundation as though it were a content key, and
            // surfaces as an unexplained decode error far from the cause.
            if (status < 200 || status > 299) {
                NSString *body = data.length
                    ? [[NSString alloc] initWithData:[data subdataWithRange:
                          NSMakeRange(0, MIN((NSUInteger)300, data.length))]
                                            encoding:NSUTF8StringEncoding]
                    : nil;
                FastPixDrmLog(@"licence server returned %ld for %@. body=%@",
                              (long)status, FastPixRedact(endpoint), body ?: @"<none>");
            } else {
                contentKey = data;
            }
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];

    // Bounded, so a hung licence server cannot wedge the loader queue.
    if (dispatch_semaphore_wait(done,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        [task cancel];
        FastPixDrmLog(@"licence request timed out after %.0fs for %@.",
                      timeout, FastPixRedact(endpoint));
        transportFailed = YES;
        contentKey = nil;
    }

    if (statusOut != NULL) *statusOut = status;
    if (transportOut != NULL) *transportOut = transportFailed;
    return contentKey;
}

/// Hand the outcome to whoever is listening, so a licence acquisition is
/// visible where the developer already looks.
///
/// Dart counts what this SDK *intends* — an arming, a configuration, a reuse —
/// and cannot see what the network actually did, because the request is made
/// here. `FastPixDrmLog` says as much in its own doc comment. This closes that
/// gap: the count in `flutter run` becomes the count of licences really
/// fetched, with the time they took.
- (void)reportAcquisition:(NSString *)playbackId
                       ok:(BOOL)ok
                   status:(NSInteger)status
                 attempts:(NSUInteger)attempts
                elapsedMs:(double)elapsedMs
                    bytes:(NSUInteger)bytes {
    void (^callback)(NSDictionary<NSString *, id> *) =
        FastPixFairPlayPatch.acquisitionCallback;
    if (callback == nil) return;
    callback(@{
        @"playbackId": playbackId ?: @"",
        @"ok": @(ok),
        @"statusCode": @(status),
        @"attempts": @(attempts),
        @"elapsedMs": @(elapsedMs),
        @"bytes": @(bytes),
    });
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {

    NSURL *assetURI = loadingRequest.request.URL;
    // Anything that is not a key request is not ours to answer; returning NO
    // lets AVFoundation handle it as it would with no delegate at all.
    if (assetURI == nil || ![assetURI.scheme isEqualToString:@"skd"]) {
        return NO;
    }

    // Answered on a queue of our own, and `YES` returned immediately.
    //
    // Returning `YES` is the delegate contract for "I will answer this
    // later" — it does not mean the answer must already be in hand — and the
    // queue this is called on is the engine's, created
    // `DISPATCH_QUEUE_SERIAL` (`BetterPlayer.m:221`). Fetching the certificate and the licence inline,
    // as this used to, therefore blocked *every* later resource-loading
    // request behind it: a certificate fetch, a licence POST, up to three
    // attempts and their backoff, a 30s budget.
    //
    // Playback survives that, because AVFoundation simply waits — a title
    // whose licence server threw two 500s was measured at 22062ms to first
    // frame, slow but playing — but nothing else the asset loads can proceed
    // in the meantime.
    //
    // The FastPix native iOS SDK answers the same `skd://` requests through
    // the same delegate API and does it asynchronously — `FastPixDRMDelegate`
    // in `FastPixAvPlayerItem.swift` returns `true` and finishes the request
    // from a `Task`, holding no lock at all. This does the same.
    dispatch_async([FastPixFairPlayLoader licenceQueue], ^{
        [self fulfilKeyRequest:loadingRequest assetURI:assetURI];
    });
    return YES;
}

/// The queue every licence exchange runs on.
///
/// Concurrent, so two protected sources — a playing one and a preload warming
/// its neighbour — do not serialise behind each other. Never the engine's
/// loader queue, which is the bug above.
+ (dispatch_queue_t)licenceQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.fastpix.fairplay.licence",
                                      DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

/// Fetch the certificate and the licence, then answer [loadingRequest].
///
/// Runs off the engine's loader queue. Every `return` here leaves the request
/// already answered — finished with data or with an error — because a request
/// that is neither is one AVFoundation waits on forever.
- (void)fulfilKeyRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                assetURI:(NSURL *)assetURI {
    // The viewer moved on — a source change, a seek past the segment, a
    // disposed player. Answering a cancelled request is at best wasted work.
    if (loadingRequest.isCancelled) return;

    NSString *uriString = assetURI.absoluteString;
    BOOL usesEzDrm = FastPixUsesEzDrmFormat(_licenseURL);

    // EZDRM identifies the asset by the trailing 36 characters of the URI, the
    // length of a UUID. A shorter URI leaves this empty, exactly as the engine
    // does — substituting the whole URI would change the licence URL of a
    // working EZDRM integration.
    NSString *assetId = uriString.length >= 36
        ? [uriString substringFromIndex:uriString.length - 36]
        : @"";

    NSUInteger certRequest = FastPixCountCertificateRequest();
    NSData *certificate = [NSData dataWithContentsOfURL:_certificateURL];
    FastPixDrmLog(@"certificate request #%lu from %@ (%lu bytes)",
                  (unsigned long)certRequest, FastPixRedact(_certificateURL),
                  (unsigned long)certificate.length);
    if (certificate == nil) {
        FastPixDrmLog(@"certificate fetch failed from %@.", FastPixRedact(_certificateURL));
        [loadingRequest finishLoadingWithError:
            [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorClientCertificateRejected
                            userInfo:nil]];
        return;
    }

    // EZDRM keys the licence on the whole `skd://` URI. Other servers, FastPix
    // included, key it on the content id alone — the URI's host. Sending the
    // wrong one produces an SPC the server cannot match, and it is refused.
    NSString *contentId = usesEzDrm ? uriString : (assetURI.host ?: uriString);
    NSData *contentIdData = [contentId dataUsingEncoding:NSUTF8StringEncoding];
    if (contentIdData == nil) {
        FastPixDrmLog(@"content id could not be encoded.");
        [loadingRequest finishLoadingWithError:nil];
        return;
    }

    // Both identifiers, because they are what a cross-wired configuration
    // disagrees about: the licence URL names one video and the content id
    // another. The server answers 200 either way, so the log line is the only
    // place the pairing is visible.
    FastPixDrmLog(@"key request: playbackId=%@ contentId=%@ ezdrm=%@ certBytes=%lu",
                  _playbackId ?: @"(unmatched)", contentId,
                  usesEzDrm ? @"YES" : @"NO", (unsigned long)certificate.length);

    NSError *spcError = nil;
    NSData *spc = [loadingRequest streamingContentKeyRequestDataForApp:certificate
                                                     contentIdentifier:contentIdData
                                                               options:nil
                                                                 error:&spcError];
    if (spc == nil) {
        FastPixDrmLog(@"SPC generation failed: %@", spcError.localizedDescription);
        [loadingRequest finishLoadingWithError:spcError];
        return;
    }

    NSData *contentKey = [self contentKeyForSPC:spc assetId:assetId];
    if (contentKey.length == 0) {
        [loadingRequest finishLoadingWithError:
            [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorBadServerResponse
                            userInfo:nil]];
        return;
    }

    FastPixDrmLog(@"licence OK, %lu bytes.", (unsigned long)contentKey.length);

    // Declare what the response *is* before handing it over.
    //
    // Playback tolerates the omission — AVFoundation infers a streaming key
    // from the `skd://` scheme — but `AVStreamingKeyDeliveryContentKeyType` is
    // the value Apple's own FPS sample sets here, so it is declared rather
    // than left to inference.
    loadingRequest.contentInformationRequest.contentType =
        AVStreamingKeyDeliveryContentKeyType;
    // Re-checked rather than assumed: the licence exchange above can take
    // seconds, and a source change or a disposed player in that window
    // cancels the request. Responding to a cancelled one throws.
    if (loadingRequest.isCancelled) return;
    [loadingRequest.dataRequest respondWithData:contentKey];
    [loadingRequest finishLoading];
}

/// The player abandoned a request we are still working on.
///
/// Nothing to unwind — the exchange checks [AVAssetResourceLoadingRequest
/// isCancelled] before it answers — but a cancelled key request and a hung one
/// look identical in a device log otherwise, and that distinction is most of
/// what makes a DRM start diagnosable.
- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (![loadingRequest.request.URL.scheme isEqualToString:@"skd"]) return;
    FastPixDrmLog(@"key request cancelled by the player before it was answered.");
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self resourceLoader:resourceLoader
        shouldWaitForLoadingOfRequestedResource:renewalRequest];
}

@end

#pragma mark - Interception

/// Key under which a substituted delegate is retained on its loader.
///
/// `AVAssetResourceLoader` holds its delegate **weakly**, so without this the
/// replacement deallocates immediately and every key request goes unanswered —
/// which looks exactly like a licence server failure.
static const void *kFastPixRetainedLoaderKey = &kFastPixRetainedLoaderKey;

/// Key under which an asset's own URL is remembered on its resource loader.
///
/// `AVAssetResourceLoader` exposes no back-pointer to the asset it belongs to,
/// so the link is recorded at the one moment both are in hand — asset
/// construction, which `FastPixCachingAssetHook` already intercepts.
static const void *kFastPixLoaderAssetURLKey = &kFastPixLoaderAssetURLKey;

static BOOL _fpFairPlayInstalled = NO;

/// The host's acquisition listener, or nil when nobody is watching.
static void (^_fpAcquisitionCallback)(NSDictionary<NSString *, id> *) = nil;

/// The most recently supplied pair, used when an asset cannot be matched to a
/// registered one. This is the whole of what the patch held before per-video
/// registration existed, and is kept as the fallback so a miss behaves the way
/// the patch always did rather than failing.
static NSURL *_fpCertificateURL = nil;
static NSURL *_fpLicenseURL = nil;

/// Registered configurations, keyed by playback id.
///
/// Bounded: a session that plays thousands of videos would otherwise grow this
/// without limit. Dropping the oldest costs a fallback to the pair above, not a
/// failure.
static NSMutableDictionary<NSString *, NSArray *> *_fpConfigsByPlaybackId = nil;
static NSMutableArray<NSString *> *_fpConfigOrder = nil;
static const NSUInteger kFastPixMaxRegisteredConfigs = 64;

/// The playback id a FastPix stream URL carries: its filename without the
/// `.m3u8` or `.mpd` extension. Nil for any other shape, which falls back.
static NSString *FastPixPlaybackIdFromURL(NSURL *url) {
    if (url == nil) return nil;
    NSString *identifier = url.URLByDeletingPathExtension.lastPathComponent;
    return identifier.length > 0 ? identifier : nil;
}

@implementation FastPixFairPlayPatch

+ (BOOL)isInstalled {
    return _fpFairPlayInstalled;
}

+ (void (^)(NSDictionary<NSString *, id> *))acquisitionCallback {
    return _fpAcquisitionCallback;
}

+ (void)setAcquisitionCallback:(void (^)(NSDictionary<NSString *, id> *))callback {
    _fpAcquisitionCallback = [callback copy];
}

+ (void)registerCertificateUrl:(NSString *)certificateUrl
                    licenseUrl:(NSString *)licenseUrl
                 forPlaybackId:(NSString *)playbackId {
    if (certificateUrl.length == 0 || playbackId.length == 0) return;

    NSURL *certificate = [NSURL URLWithString:certificateUrl];
    if (certificate == nil) return;
    NSURL *licence = licenseUrl.length > 0 ? [NSURL URLWithString:licenseUrl] : nil;

    @synchronized (self) {
        if (_fpConfigsByPlaybackId == nil) {
            _fpConfigsByPlaybackId = [NSMutableDictionary dictionary];
            _fpConfigOrder = [NSMutableArray array];
        }
        if (_fpConfigsByPlaybackId[playbackId] == nil) {
            [_fpConfigOrder addObject:playbackId];
            while (_fpConfigOrder.count > kFastPixMaxRegisteredConfigs) {
                [_fpConfigsByPlaybackId removeObjectForKey:_fpConfigOrder.firstObject];
                [_fpConfigOrder removeObjectAtIndex:0];
            }
        }
        _fpConfigsByPlaybackId[playbackId] =
            @[certificate, licence ?: (id)NSNull.null];
    }
    FastPixDrmLog(@"registered %@: cert=%@ licence=%@", playbackId,
                  FastPixRedact(certificate), FastPixRedact(licence));
}

+ (void)noteAsset:(AVURLAsset *)asset url:(NSURL *)url {
    if (asset == nil || url == nil) return;

    // The loader, not the asset, and only when it exists. This runs *inside*
    // `initWithURL:options:`, and AVFoundation builds its own assets on
    // internal queues — `com.apple.avplayeritem.ivars` among them — where the
    // object is not finished constructing and has no resource loader yet.
    // `objc_setAssociatedObject` dereferences its object, so a nil one is not
    // a no-op: it is a crash on the player's own queue.
    //
    // Skipping those costs nothing. They are not the asset playback loads a
    // licence for, and an unrecorded asset falls back to the last configured
    // pair exactly as it did before any of this existed.
    AVAssetResourceLoader *loader = asset.resourceLoader;
    if (loader == nil) return;

    objc_setAssociatedObject(loader, kFastPixLoaderAssetURLKey, url,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)setCertificateUrl:(NSString *)certificateUrl
               licenseUrl:(NSString *)licenseUrl {
    @synchronized (self) {
        if (certificateUrl.length == 0 || (id)certificateUrl == NSNull.null) {
            _fpCertificateURL = nil;
            _fpLicenseURL = nil;
            [_fpConfigsByPlaybackId removeAllObjects];
            [_fpConfigOrder removeAllObjects];
            return;
        }
        _fpCertificateURL = [NSURL URLWithString:certificateUrl];
        _fpLicenseURL = (licenseUrl.length > 0 && (id)licenseUrl != NSNull.null)
            ? [NSURL URLWithString:licenseUrl]
            : nil;
        FastPixDrmLog(@"configured: cert=%@ licence=%@",
                      FastPixRedact(_fpCertificateURL), FastPixRedact(_fpLicenseURL));
    }
}

+ (void)install {
    if (_fpFairPlayInstalled) return;

    @synchronized (self) {
        if (_fpFairPlayInstalled) return;

        // AVFoundation, not the engine — so this resolves at the first attempt
        // and needs none of the pod-loading retry that finding `BetterPlayer`
        // does. That independence is the point: see the header comment.
        Class target = AVAssetResourceLoader.class;
        SEL originalSel = @selector(setDelegate:queue:);
        SEL replacementSel = @selector(fp_setDelegate:queue:);

        Method original = class_getInstanceMethod(target, originalSel);
        Method replacement = class_getInstanceMethod(self, replacementSel);
        if (original == NULL || replacement == NULL) {
            FastPixDrmLog(@"NOT INSTALLED: AVAssetResourceLoader.setDelegate:queue: not "
                          @"found. FairPlay will use the engine's EZDRM-only path and "
                          @"fail against a FastPix licence server.");
            return;
        }

        class_addMethod(target, replacementSel,
                        method_getImplementation(replacement),
                        method_getTypeEncoding(replacement));
        Method installed = class_getInstanceMethod(target, replacementSel);
        method_exchangeImplementations(original, installed);

        _fpFairPlayInstalled = YES;
        FastPixDrmLog(@"installed — non-EZDRM licence servers supported.");
    }
}

/// Replacement for `-[AVAssetResourceLoader setDelegate:queue:]`.
///
/// Lives on `FastPixFairPlayPatch` only so it can be copied onto
/// `AVAssetResourceLoader`; by the time it runs, `self` **is** the loader.
- (void)fp_setDelegate:(id<AVAssetResourceLoaderDelegate>)delegate
                 queue:(dispatch_queue_t)queue {

    NSString *delegateClass = delegate ? NSStringFromClass([delegate class]) : nil;
    BOOL isEngineDrmDelegate =
        [delegateClass containsString:@"BetterPlayerEzDrmAssetsLoaderDelegate"];

    if (isEngineDrmDelegate) {
        // Which video this loader belongs to, taken from the URL its asset was
        // built with. Without it there is only the process-wide pair, which
        // belongs to whichever video was configured last — and a player warmed
        // in the background is built while a *different* video is playing.
        NSURL *assetURL = objc_getAssociatedObject(self, kFastPixLoaderAssetURLKey);
        NSString *playbackId = FastPixPlaybackIdFromURL(assetURL);

        NSURL *certificateURL = nil;
        NSURL *licenseURL = nil;
        BOOL matched = NO;
        @synchronized (FastPixFairPlayPatch.class) {
            NSArray *registered = playbackId ? _fpConfigsByPlaybackId[playbackId] : nil;
            if (registered != nil) {
                certificateURL = registered.firstObject;
                id licence = registered.lastObject;
                licenseURL = (licence == NSNull.null) ? nil : licence;
                matched = YES;
            } else {
                certificateURL = _fpCertificateURL;
                licenseURL = _fpLicenseURL;
            }
        }

        if (certificateURL != nil) {
            FastPixFairPlayLoader *replacement =
                [[FastPixFairPlayLoader alloc] initWithCertificateURL:certificateURL
                                                          licenseURL:licenseURL
                                                          playbackId:playbackId];

            // The loader holds its delegate weakly; this is what keeps ours
            // alive for as long as the loader itself.
            objc_setAssociatedObject(self, kFastPixRetainedLoaderKey, replacement,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // Said either way, because the two cases differ in exactly the
            // property that matters: a matched loader carries its own video's
            // licence, an unmatched one carries the last video configured.
            FastPixDrmLog(@"handling FairPlay for %@ (licence %@, %@).",
                          playbackId ?: @"an unidentified asset",
                          FastPixRedact(licenseURL),
                          matched ? @"registered for this video"
                                  : @"NOT registered — using the last configured pair");

            // After the exchange this selector is the original implementation,
            // so this is a call through rather than recursion.
            [self fp_setDelegate:replacement queue:queue];
            return;
        }

        // The engine is setting up FairPlay and we have nothing to build a
        // delegate from. Said out loud, because the alternative is the engine's
        // EZDRM-only path failing later with an opaque licence error.
        FastPixDrmLog(@"engine DRM delegate seen but no configuration was supplied — "
                      @"falling through to the engine's EZDRM path, which fails "
                      @"against a FastPix licence server.");
    }

    [self fp_setDelegate:delegate queue:queue];
}

@end
