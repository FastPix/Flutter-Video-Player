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
                            licenseURL:(nullable NSURL *)licenseURL;
@end

@implementation FastPixFairPlayLoader {
    NSURL *_certificateURL;
    NSURL *_licenseURL;
}

- (instancetype)initWithCertificateURL:(NSURL *)certificateURL
                            licenseURL:(NSURL *)licenseURL {
    if ((self = [super init])) {
        _certificateURL = certificateURL;
        _licenseURL = licenseURL ?: [NSURL URLWithString:kEzDrmDefaultLicenseServer];
    }
    return self;
}

/// POST the SPC to the licence server and return the CKC.
///
/// Synchronous by necessity: `AVAssetResourceLoaderDelegate` expects the
/// loading request to be answered before this returns, which is why the engine
/// blocks here too.
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

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = spc;

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *contentKey = nil;

    NSURLSessionDataTask *task =
        [NSURLSession.sharedSession dataTaskWithRequest:request
                                      completionHandler:^(NSData *data,
                                                          NSURLResponse *response,
                                                          NSError *error) {
        if (error != nil) {
            FastPixDrmLog(@"licence request failed for %@: %@",
                          FastPixRedact(endpoint), error.localizedDescription);
        } else {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : -1;
            // A licence server reports rejection with an HTTP status, not a
            // transport error. Without this check an error body — JSON, HTML —
            // is handed to AVFoundation as though it were a content key, and
            // surfaces as an unexplained decode failure far from the cause.
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
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0) {
        [task cancel];
        FastPixDrmLog(@"licence request timed out after 30s for %@.",
                      FastPixRedact(endpoint));
        return nil;
    }
    return contentKey;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {

    NSURL *assetURI = loadingRequest.request.URL;
    // Anything that is not a key request is not ours to answer; returning NO
    // lets AVFoundation handle it as it would with no delegate at all.
    if (assetURI == nil || ![assetURI.scheme isEqualToString:@"skd"]) {
        return NO;
    }

    NSString *uriString = assetURI.absoluteString;
    BOOL usesEzDrm = FastPixUsesEzDrmFormat(_licenseURL);

    // EZDRM identifies the asset by the trailing 36 characters of the URI, the
    // length of a UUID. A shorter URI leaves this empty, exactly as the engine
    // does — substituting the whole URI would change the licence URL of a
    // working EZDRM integration.
    NSString *assetId = uriString.length >= 36
        ? [uriString substringFromIndex:uriString.length - 36]
        : @"";

    NSData *certificate = [NSData dataWithContentsOfURL:_certificateURL];
    if (certificate == nil) {
        FastPixDrmLog(@"certificate fetch failed from %@.", FastPixRedact(_certificateURL));
        [loadingRequest finishLoadingWithError:
            [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorClientCertificateRejected
                            userInfo:nil]];
        return YES;
    }

    // EZDRM keys the licence on the whole `skd://` URI. Other servers, FastPix
    // included, key it on the content id alone — the URI's host. Sending the
    // wrong one produces an SPC the server cannot match, and it is refused.
    NSString *contentId = usesEzDrm ? uriString : (assetURI.host ?: uriString);
    NSData *contentIdData = [contentId dataUsingEncoding:NSUTF8StringEncoding];
    if (contentIdData == nil) {
        FastPixDrmLog(@"content id could not be encoded.");
        [loadingRequest finishLoadingWithError:nil];
        return YES;
    }

    FastPixDrmLog(@"key request: contentId=%@ ezdrm=%@ certBytes=%lu",
                  contentId, usesEzDrm ? @"YES" : @"NO", (unsigned long)certificate.length);

    NSError *spcError = nil;
    NSData *spc = [loadingRequest streamingContentKeyRequestDataForApp:certificate
                                                     contentIdentifier:contentIdData
                                                               options:nil
                                                                 error:&spcError];
    if (spc == nil) {
        FastPixDrmLog(@"SPC generation failed: %@", spcError.localizedDescription);
        [loadingRequest finishLoadingWithError:spcError];
        return YES;
    }

    NSData *contentKey = [self contentKeyForSPC:spc assetId:assetId];
    if (contentKey.length == 0) {
        [loadingRequest finishLoadingWithError:
            [NSError errorWithDomain:NSURLErrorDomain
                                code:NSURLErrorBadServerResponse
                            userInfo:nil]];
        return YES;
    }

    FastPixDrmLog(@"licence OK, %lu bytes.", (unsigned long)contentKey.length);
    [loadingRequest.dataRequest respondWithData:contentKey];
    [loadingRequest finishLoading];
    return YES;
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

static BOOL _fpFairPlayInstalled = NO;
static NSURL *_fpCertificateURL = nil;
static NSURL *_fpLicenseURL = nil;

@implementation FastPixFairPlayPatch

+ (BOOL)isInstalled {
    return _fpFairPlayInstalled;
}

+ (void)setCertificateUrl:(NSString *)certificateUrl
               licenseUrl:(NSString *)licenseUrl {
    @synchronized (self) {
        if (certificateUrl.length == 0 || (id)certificateUrl == NSNull.null) {
            _fpCertificateURL = nil;
            _fpLicenseURL = nil;
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
        NSURL *certificateURL = nil;
        NSURL *licenseURL = nil;
        @synchronized (FastPixFairPlayPatch.class) {
            certificateURL = _fpCertificateURL;
            licenseURL = _fpLicenseURL;
        }

        if (certificateURL != nil) {
            FastPixFairPlayLoader *replacement =
                [[FastPixFairPlayLoader alloc] initWithCertificateURL:certificateURL
                                                          licenseURL:licenseURL];

            // The loader holds its delegate weakly; this is what keeps ours
            // alive for as long as the loader itself.
            objc_setAssociatedObject(self, kFastPixRetainedLoaderKey, replacement,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            FastPixDrmLog(@"handling FairPlay for this asset (licence %@).",
                          FastPixRedact(licenseURL));

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
