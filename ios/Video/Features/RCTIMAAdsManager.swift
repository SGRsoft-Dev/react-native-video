#if USE_GOOGLE_IMA
    import Foundation
    import GoogleInteractiveMediaAds

    class RCTIMAAdsManager: NSObject, IMAAdsLoaderDelegate, IMAAdsManagerDelegate, IMALinkOpenerDelegate {
        private weak var _video: RCTVideo?
        private var _isPictureInPictureActive: () -> Bool

        /* Entry point for the SDK. Used to make ad requests. */
        private var adsLoader: IMAAdsLoader!
        /* Main point of interaction with the SDK. Created by the SDK as the result of an ad request. */
        private var adsManager: IMAAdsManager!
        /* View that hosts the IMA-rendered ad UI (incl. tvOS skip button). Kept so tvOS can
           redirect focus into it during ad playback. */
        private var adContainerView: UIView?
        /* Display container created per ad request. Exposes `focusEnvironment` — the IMA-provided
           focus target for the current ad break (skip/More buttons). Used for tvOS focus routing. */
        private var adDisplayContainer: IMAAdDisplayContainer?

        init(video: RCTVideo!, isPictureInPictureActive: @escaping () -> Bool) {
            _video = video
            _isPictureInPictureActive = isPictureInPictureActive

            super.init()
        }

        func setUpAdsLoader() {
            guard let _video else { return }
            let settings = IMASettings()
            if let adLanguage = _video.getAdLanguage() {
                settings.language = adLanguage
            }
            adsLoader = IMAAdsLoader(settings: settings)
            adsLoader.delegate = self
        }

        func requestAds() {
            guard let _video else { return }
            // fixes RCTVideo --> RCTIMAAdsManager --> IMAAdsLoader --> IMAAdDisplayContainer --> RCTVideo memory leak.
            let adContainerView = UIView(frame: _video.bounds)
            adContainerView.backgroundColor = .clear
            _video.addSubview(adContainerView)
            // Keep a reference so tvOS can move focus into the IMA ad UI (skip button).
            self.adContainerView = adContainerView

            // Create ad display container for ad rendering.
            let adDisplayContainer = IMAAdDisplayContainer(adContainer: adContainerView, viewController: _video.reactViewController())
            // Keep it so tvOS can route focus to IMA's own ad-break focus environment (skip/More).
            self.adDisplayContainer = adDisplayContainer

            let adTagUrl = _video.getAdTagUrl()
            let contentPlayhead = _video.getContentPlayhead()

            if adTagUrl != nil && contentPlayhead != nil {
                // Create an ad request with our ad tag, display container, and optional user context.
                let request = IMAAdsRequest(
                    adTagUrl: adTagUrl!,
                    adDisplayContainer: adDisplayContainer,
                    contentPlayhead: contentPlayhead,
                    userContext: nil
                )

                adsLoader.requestAds(with: request)
            }
        }

        func releaseAds() {
            adContainerView?.removeFromSuperview()
            adContainerView = nil
            adDisplayContainer = nil
            guard let adsManager else { return }
            // Destroy AdsManager may be delayed for a few milliseconds
            // But what we want is it stopped producing sound immediately
            // Issue found on tvOS 17, or iOS if view detach & STARTED event happen at the same moment
            adsManager.volume = 0
            adsManager.pause()
            adsManager.destroy()
        }

        // View hosting the IMA ad UI — used by tvOS to redirect focus to the skip button.
        func getAdContainerView() -> UIView? {
            return adContainerView
        }

        // IMA-provided focus target for the current ad break (skip/More buttons). Preferred over
        // the raw container view so tvOS focus lands on IMA's own interactive ad UI. nil when no ad.
        func getAdFocusEnvironment() -> UIFocusEnvironment? {
            return adDisplayContainer?.focusEnvironment
        }

        // MARK: - Getters

        func getAdsLoader() -> IMAAdsLoader? {
            return adsLoader
        }

        func getAdsManager() -> IMAAdsManager? {
            return adsManager
        }

        // MARK: - IMAAdsLoaderDelegate

        func adsLoader(_: IMAAdsLoader, adsLoadedWith adsLoadedData: IMAAdsLoadedData) {
            guard let _video else { return }
            // Grab the instance of the IMAAdsManager and set yourself as the delegate.
            adsManager = adsLoadedData.adsManager
            adsManager?.delegate = self

            // Create ads rendering settings and tell the SDK to use the in-app browser.
            let adsRenderingSettings = IMAAdsRenderingSettings()
            adsRenderingSettings.linkOpenerDelegate = self
            adsRenderingSettings.linkOpenerPresentingController = _video.reactViewController()
            // NOTE: uiElements를 [COUNTDOWN]으로 제한하면 tvOS에서 스킵 버튼 UI까지 사라진다.
            // 따라서 attribution 제한은 하지 않고, 'Why This Ad' 버튼만 뷰 트리에서 직접 숨긴다.

            adsManager.initialize(with: adsRenderingSettings)
        }

        func adsLoader(_: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
            if adErrorData.adError.message != nil {
                print("Error loading ads: " + adErrorData.adError.message!)
            }

            _video?.setPaused(false)
        }

        // MARK: - IMAAdsManagerDelegate

        func adsManager(_ adsManager: IMAAdsManager, didReceive event: IMAAdEvent) {
            guard let _video else { return }
            // Mute ad if the main player is muted
            if _video.isMuted() {
                adsManager.volume = 0
            }
            // Play each ad once it has been loaded
            if event.type == IMAAdEventType.LOADED {
                if _isPictureInPictureActive() {
                    return
                }
                adsManager.start()
            }

            #if os(tvOS)
                // Move focus into the IMA ad UI so the remote can operate the skip button.
                if event.type == IMAAdEventType.STARTED || event.type == IMAAdEventType.RESUME {
                    _video.updateAdFocus()
                }
                // AdChoices/'About this ad' icon tapped → IMA pauses the ad and shows a fallback
                // (QR) modal. When that modal closes, IMA does NOT auto-resume on tvOS and focus is
                // lost, leaving the ad frozen with a dead remote. Resume the ad (countdown/skip
                // continues) and route focus back into the ad UI.
                if event.type == IMAAdEventType.ICON_FALLBACK_IMAGE_CLOSED {
                    adsManager.resume()
                    _video.updateAdFocus()
                }
            #endif

            if _video.onReceiveAdEvent != nil {
                let type = convertEventToString(event: event.type)

                if event.adData != nil {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "data": event.adData ?? [String](),
                        "target": _video.reactTag!,
                    ])
                } else {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "target": _video.reactTag!,
                    ])
                }
            }
        }

        func adsManager(_: IMAAdsManager, didReceive error: IMAAdError) {
            if error.message != nil {
                print("AdsManager error: " + error.message!)
            }

            guard let _video else { return }

            if _video.onReceiveAdEvent != nil {
                _video.onReceiveAdEvent?([
                    "event": "ERROR",
                    "data": [
                        "message": error.message ?? "",
                        "code": error.code,
                        "type": error.type,
                    ],
                    "target": _video.reactTag!,
                ])
            }

            // Fall back to playing content
            _video.setPaused(false)
        }

        func adsManagerDidRequestContentPause(_: IMAAdsManager) {
            // Pause the content for the SDK to play ads.
            _video?.setPaused(true)
            _video?.setAdPlaying(true)
        }

        func adsManagerDidRequestContentResume(_: IMAAdsManager) {
            // Resume the content since the SDK is done playing ads (at least for now).
            _video?.setAdPlaying(false)
            _video?.setPaused(false)
        }

        // MARK: - IMALinkOpenerDelegate

        func linkOpenerDidClose(inAppLink _: NSObject) {
            // tvOS '광고 정보'(클릭연결/AdChoices) 모달이 닫힌 직후: 광고를 재개해 카운트다운이
            // 다시 흐르게 하고, 포커스를 광고 컨테이너로 되돌려 리모컨으로 스킵이 가능하도록 한다.
            // (포커스를 복귀시키지 않으면 모달이 닫힌 뒤 포커스가 사라져 멈춤/뒤로가기 불가가 됨)
            adsManager?.resume()
            #if os(tvOS)
                _video?.updateAdFocus()
            #endif
        }

        // MARK: - Helpers

        func convertEventToString(event: IMAAdEventType!) -> String {
            var result = "UNKNOWN"

            switch event {
            case .AD_BREAK_READY:
                result = "AD_BREAK_READY"
            case .AD_BREAK_ENDED:
                result = "AD_BREAK_ENDED"
            case .AD_BREAK_STARTED:
                result = "AD_BREAK_STARTED"
            case .AD_PERIOD_ENDED:
                result = "AD_PERIOD_ENDED"
            case .AD_PERIOD_STARTED:
                result = "AD_PERIOD_STARTED"
            case .ALL_ADS_COMPLETED:
                result = "ALL_ADS_COMPLETED"
            case .CLICKED:
                result = "CLICK"
            case .COMPLETE:
                result = "COMPLETED"
            case .CUEPOINTS_CHANGED:
                result = "CUEPOINTS_CHANGED"
            case .FIRST_QUARTILE:
                result = "FIRST_QUARTILE"
            case .ICON_TAPPED:
                result = "ICON_TAPPED"
            case .ICON_FALLBACK_IMAGE_CLOSED:
                result = "ICON_FALLBACK_IMAGE_CLOSED"
            case .LOADED:
                result = "LOADED"
            case .LOG:
                result = "LOG"
            case .MIDPOINT:
                result = "MIDPOINT"
            case .PAUSE:
                result = "PAUSED"
            case .RESUME:
                result = "RESUMED"
            case .SKIPPED:
                result = "SKIPPED"
            case .STARTED:
                result = "STARTED"
            case .STREAM_LOADED:
                result = "STREAM_LOADED"
            case .TAPPED:
                result = "TAPPED"
            case .THIRD_QUARTILE:
                result = "THIRD_QUARTILE"
            default:
                result = "UNKNOWN"
            }

            return result
        }
    }
#endif
